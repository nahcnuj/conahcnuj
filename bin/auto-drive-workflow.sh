#!/usr/bin/env bash
# bin/auto-drive-workflow.sh - run the weekly auto-drive self-improvement loop.
#
# Single-step entry point for .github/workflows/weekly-self-improvement.yml.
# Given an "Issue auto-drive" (issue-driver.yml) run history, it:
#
#   1. collects the job logs of the last --lookback-days of completed runs
#      through `gh` (Actions API),
#   2. turns them into a markdown report with auto-drive-report.sh and posts
#      that report on a standing tracking issue,
#   3. and only when the report carries actionable findings (actionable>0 on the
#      report's meta line) and --drive is enabled, keeps ONE open
#      "auto-drive findings" issue up to date (creating it if none) and
#      dispatches the driver on it via workflow_dispatch.
#
# The robot loop is never self-triggering: the findings issue is authored by
# github-actions[bot], so the issues-opened trigger skips it (only the explicit
# workflow_dispatch starts the driver), and every driver run still ends at the
# owner's review.
#
# Everything writes through `gh`, which is the test seam: offline driver tests
# put a mock `gh` earlier on PATH. No secrets are needed (least-privilege
# GITHUB_TOKEN: actions: write + issues: write).
#
# Usage:
#   auto-drive-workflow.sh [--repo OWNER/REPO] [--runs-url-prefix PREFIX]
#                          [--lookback-days N] [--drive true|false]
#                          [--ref BRANCH]
#                          [--project-owner OWNER] [--project-number N]
#                          [--project-id ID]
#
#   --repo OWNER/REPO     default: $GITHUB_REPOSITORY (required otherwise)
#   --runs-url-prefix P   link run-<id>.log files to P/<id>
#   --lookback-days N     default 7 (>= 1)
#   --drive true|false    default true; false publishes the report but never
#                         dispatches the driver
#   --ref BRANCH          workflow_dispatch ref (default $GITHUB_REF_NAME)
#   --project-owner OWNER owner of GitHub Project (default repo owner)
#   --project-number N    project number to add issues to
#   --project-id ID       project ID to add issues to
#
# Report -> stdout, progress -> stderr. Exit 0 on success; > 0 on any failure
# so the Actions job fails loudly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_SCRIPT="${SCRIPT_DIR}/auto-drive-report.sh"
MAX_RUNS=40
TRACKING_TITLE="auto-drive weekly self-improvement log"
FINDINGS_PREFIX="auto-drive findings"

usage() {
  cat <<'EOF'
Usage: auto-drive-workflow.sh [--repo OWNER/REPO] [--runs-url-prefix PREFIX]
                              [--lookback-days N] [--drive true|false]
                              [--ref BRANCH]

Weekly self-improvement loop: collect the "Issue auto-drive" run logs through
`gh`, analyze them (auto-drive-report.sh, stdout), publish the report on a
tracking issue, and dispatch the driver on one findings issue when the report
has actionable findings. No secrets required. See the script header for the
loop-hygiene rules.
EOF
}

repo=""
runs_url_prefix=""
lookback_days="7"
drive="true"
dispatch_ref=""
project_owner=""
project_number=""
project_id=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="${2:-}"; shift 2 ;;
    --runs-url-prefix) runs_url_prefix="${2:-}"; shift 2 ;;
    --lookback-days) lookback_days="${2:-}"; shift 2 ;;
    --drive) drive="${2:-}"; shift 2 ;;
    --ref) dispatch_ref="${2:-}"; shift 2 ;;
    --project-owner) project_owner="${2:-}"; shift 2 ;;
    --project-number) project_number="${2:-}"; shift 2 ;;
    --project-id) project_id="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

if [[ -z "${repo}" ]]; then
  repo="${GITHUB_REPOSITORY:-}"
fi
if [[ -z "${repo}" ]]; then
  echo "No repo given; set --repo OWNER/REPO or GITHUB_REPOSITORY." >&2
  exit 1
fi
[[ "${repo}" =~ ^[^/]+/[^/]+$ ]] || { echo "Invalid repo: ${repo}" >&2; exit 1; }
[[ "${lookback_days}" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid lookback-days: ${lookback_days}" >&2; exit 1; }
[[ "${drive}" == "true" || "${drive}" == "false" ]] || { echo "Invalid drive: ${drive}" >&2; exit 1; }
[[ -z "${project_number}" || "${project_number}" =~ ^[0-9]+$ ]] || { echo "Invalid project-number: ${project_number}" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || { echo "gh CLI is required" >&2; exit 1; }
[[ -x "${REPORT_SCRIPT}" || -f "${REPORT_SCRIPT}" ]] || { echo "missing ${REPORT_SCRIPT}" >&2; exit 1; }

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
add_to_project() {
  local issue_url="$1"
  [[ -n "${issue_url}" ]] || return 0
  if [[ -n "${project_id}" ]]; then
    gh project item-add "${project_id}" --url "${issue_url}" >/dev/null 2>&1 || echo "warning: failed to add item to project ${project_id}" >&2
    return 0
  fi
  if [[ -n "${project_number}" ]]; then
    local owner="${project_owner}"
    if [[ -z "${owner}" ]]; then
      owner="${repo%%/*}"
    fi
    gh project item-add "${project_number}" --owner "${owner}" --url "${issue_url}" >/dev/null 2>&1 || echo "warning: failed to add item to project #${project_number}" >&2
    return 0
  fi
}


# --- 1. collect --------------------------------------------------------------
since="$(date -u -d "${lookback_days} days ago" +%Y-%m-%dT%H:%M:%SZ)"
echo "Collecting completed Issue auto-drive runs created >= ${since}" >&2

gh api --paginate \
  "repos/${repo}/actions/workflows/issue-driver.yml/runs?status=completed&sort=created&direction=desc&per_page=100" \
  --jq '.workflow_runs[] | select(.created_at >= "'"${since}"'") | .id' \
  > "${tmp_dir}/run-ids-all.txt"

head -n "${MAX_RUNS}" "${tmp_dir}/run-ids-all.txt" > "${tmp_dir}/run-ids.txt"

logs_dir="${tmp_dir}/logs"
mkdir -p "${logs_dir}"
count=0
while IFS= read -r id; do
  [[ -n "${id}" ]] || continue
  if gh run view "${id}" --repo "${repo}" --log > "${logs_dir}/run-${id}.log" 2>/dev/null \
    && [[ -s "${logs_dir}/run-${id}.log" ]]; then
    count=$((count + 1))
  else
    rm -f "${logs_dir}/run-${id}.log"
    echo "warning: no downloadable log for run ${id}" >&2
  fi
done < "${tmp_dir}/run-ids.txt"
echo "collected ${count} run log(s) from the last ${lookback_days} day(s)" >&2

# --- 2. analyze ---------------------------------------------------------------
report_file="${tmp_dir}/report.md"
report_args=()
[[ -n "${runs_url_prefix}" ]] && report_args+=(--runs-url-prefix "${runs_url_prefix}")
bash "${REPORT_SCRIPT}" "${report_args[@]+"${report_args[@]}"}" "${logs_dir}" > "${report_file}"
cat "${report_file}"

meta="$(sed -n 's/^<!-- auto-drive-report \(.*\) -->$/\1/p' "${report_file}" | head -n 1)"
actionable=""
for kv in ${meta}; do
  case "${kv}" in
    actionable=*) actionable="${kv#actionable=}" ;;
  esac
done
[[ "${actionable}" =~ ^[0-9]+$ ]] || { echo "could not read the report meta line: ${meta}" >&2; exit 1; }
echo "actionable findings: ${actionable}" >&2

# --- 3. publish on the tracking issue -----------------------------------------
stamp="$(date -u +%F)"
comment="${tmp_dir}/report-comment.md"
{ printf '### %s\n\n' "${stamp}"; cat "${report_file}"; } > "${comment}"

tracking="$(gh issue list --repo "${repo}" --state open --limit 200 \
  --json number,title \
  --jq '.[] | select(.title == "auto-drive weekly self-improvement log") | .number' \
  | head -n 1)"
if [[ -n "${tracking}" ]]; then
  gh issue comment "${tracking}" --repo "${repo}" --body-file "${comment}"
  echo "appended this week's report to tracking issue #${tracking}" >&2
else
  url="$(gh issue create --repo "${repo}" --title "${TRACKING_TITLE}" --body-file "${comment}")"
  add_to_project "${url}"
  echo "created the tracking issue: ${url}" >&2
fi

# --- 4. hand actionable findings to the driver --------------------------------
if [[ "${drive}" != "true" ]]; then
  echo "drive is false; not touching the driver." >&2
  exit 0
fi
if [[ "${actionable}" -eq 0 ]]; then
  echo "No actionable findings this period; nothing for the driver to take." >&2
  exit 0
fi

body="${tmp_dir}/findings-issue.md"
# shellcheck disable=SC2016 # body lines carry backticks on purpose
printf '%s\n' \
  '週次の auto-drive ログ解析（`bin/auto-drive-report.sh`）が検出した actionable' \
  'finding をまとめた issue です。本文のレポート（実行へのリンクとログ抜粋）が' \
  '材料で、対応（原因の調査と作業ツリーの変更・検証）はコーディングエージェント' \
  'の担当です。ブランチ名・コミット・push・PR の作成とレビュー依頼はドライバが' \
  '行います。`[informational]` の finding はコード変更不要（再実行や設定確認で' \
  '足りるもの）で、対処は含めなくて構いません。' \
  '' > "${body}"
cat "${report_file}" >> "${body}"

num="$(gh issue list --repo "${repo}" --state open --limit 200 \
  --json number,title \
  --jq '.[] | select(.title | startswith("auto-drive findings")) | .number' \
  | head -n 1)"
if [[ -n "${num}" ]]; then
  gh issue comment "${num}" --repo "${repo}" --body-file "${body}"
  echo "added this week's findings to issue #${num}" >&2
else
  url="$(gh issue create --repo "${repo}" --title "${FINDINGS_PREFIX}: ${stamp}" --body-file "${body}")"
  num="${url##*/}"
  [[ "${num}" =~ ^[0-9]+$ ]] || { echo "could not read the new issue number from ${url}" >&2; exit 1; }
  add_to_project "${url}"
  echo "created findings issue #${num}" >&2
fi

# The findings issue is bot-authored, so opening it never triggers
# issue-driver.yml; this explicit dispatch is the only entry point.
if [[ -n "${dispatch_ref}" ]]; then
  gh workflow run issue-driver.yml --repo "${repo}" --ref "${dispatch_ref}" -f number="${num}"
else
  gh workflow run issue-driver.yml --repo "${repo}" -f number="${num}"
fi
echo "dispatched Issue auto-drive (workflow_dispatch number=${num})" >&2