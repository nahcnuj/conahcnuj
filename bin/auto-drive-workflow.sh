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
#   3. and when the report carries actionable findings (actionable>0 on the
#      report's meta line), keeps the standing "auto-drive findings" issue up
#      to date and labels it `self-improvement`.
#
# The label is the loop's single marker: it is what the rest of the loop keys
# off, so the process stays autonomous without any per-run manual input.
#
#   - issue-driver.yml lets a bot-authored issue through only when it carries
#     the label, and the findings issue is created with the App installation
#     token on purpose: events raised through the workflow's GITHUB_TOKEN never
#     start workflows, so a GITHUB_TOKEN issue could not reach the driver on its
#     own. A labelled App issue starts it on `issues: opened`.
#   - the tracking and findings issues are added to a GitHub Project explicitly
#     (gh project item-add) with the App installation token, so the board shows
#     the work items without relying on the owner enabling the Project's
#     built-in "auto-add" by hand. The Projects API is outside the workflow's
#     GITHUB_TOKEN; it runs with the App token, which carries the repository
#     "Projects" permission the owner granted. When the Project cannot be
#     resolved the loop falls back to the built-in "auto-add" workflow on
#     `label:self-improvement`, so a Project the owner configured by hand keeps
#     working.
#   - the Project is addressed by PROJECT_NUMBER, or looked up by
#     PROJECT_TITLE (default "auto-drive self-improvement") and created when it
#     is missing, so no per-run manual input is needed.
#
# At most one findings issue is open: a new week's findings are appended to the
# existing issue and the driver is dispatched once as a retry, while a freshly
# created issue starts the driver by itself.
#
# Everything writes through `gh`, which is the test seam: offline driver tests
# put a mock `gh` earlier on PATH. No secrets are needed beyond the App token
# the workflow stages for the findings issue (GITHUB_TOKEN covers the rest).
#
# Usage:
#   auto-drive-workflow.sh [--repo OWNER/REPO] [--runs-url-prefix PREFIX]
#                          [--lookback-days N] [--ref BRANCH]
#                          [--project-owner OWNER] [--project-number N]
#                          [--project-title TITLE]
#
#   --repo OWNER/REPO     default: $GITHUB_REPOSITORY (required otherwise)
#   --runs-url-prefix P   link run-<id>.log files to P/<id>
#   --lookback-days N     default 7 (>= 1)
#   --ref BRANCH          retry dispatch ref (default $GITHUB_REF_NAME)
#   --project-owner OWNER default: repo owner (or $PROJECT_OWNER)
#   --project-number N    Project number to add items to (or $PROJECT_NUMBER)
#   --project-title TITLE Project to find/create when no number (or $PROJECT_TITLE)
#
# Environment: GH_APP_TOKEN is the App installation token used for the Projects
# API (the App holds the repository "Projects" permission the owner granted);
# GITHUB_TOKEN / the App token cover the rest as gh_app documents.
#
# Report -> stdout, progress -> stderr. Exit 0 on success; > 0 on any failure
# so the Actions job fails loudly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_SCRIPT="${SCRIPT_DIR}/auto-drive-report.sh"
MAX_RUNS=40
TRACKING_TITLE="auto-drive weekly self-improvement log"
FINDINGS_PREFIX="auto-drive findings"
SELF_IMPROVEMENT_LABEL="self-improvement"
LABEL_COLOR="5319e7"
LABEL_DESCRIPTION="weekly auto-drive self-improvement finding"
PROJECT_TITLE_DEFAULT="auto-drive self-improvement"

usage() {
  cat <<'EOF'
Usage: auto-drive-workflow.sh [--repo OWNER/REPO] [--runs-url-prefix PREFIX]
                              [--lookback-days N] [--ref BRANCH]
                              [--project-owner OWNER] [--project-number N]
                              [--project-title TITLE]

Weekly self-improvement loop: collect the "Issue auto-drive" run logs through
`gh`, analyze them (auto-drive-report.sh, stdout), publish the report on a
tracking issue, and keep the standing "auto-drive findings" issue up to date
with the `self-improvement` label when the report has actionable findings. The
label lets issue-driver.yml pick the issue up by itself; the issues are also
added to a GitHub Project (PROJECT_NUMBER, or a Project found/created by
PROJECT_TITLE) so the board carries the work items. See the script header for
the loop-hygiene rules.
EOF
}

repo=""
runs_url_prefix=""
lookback_days="7"
dispatch_ref=""
project_owner="${PROJECT_OWNER:-}"
project_number="${PROJECT_NUMBER:-}"
project_title="${PROJECT_TITLE:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) repo="${2:-}"; shift 2 ;;
    --runs-url-prefix) runs_url_prefix="${2:-}"; shift 2 ;;
    --lookback-days) lookback_days="${2:-}"; shift 2 ;;
    --ref) dispatch_ref="${2:-}"; shift 2 ;;
    --project-owner) project_owner="${2:-}"; shift 2 ;;
    --project-number) project_number="${2:-}"; shift 2 ;;
    --project-title) project_title="${2:-}"; shift 2 ;;
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
[[ -z "${project_number}" || "${project_number}" =~ ^[0-9]+$ ]] || { echo "Invalid project-number: ${project_number}" >&2; exit 1; }

command -v gh >/dev/null 2>&1 || { echo "gh CLI is required" >&2; exit 1; }
[[ -x "${REPORT_SCRIPT}" || -f "${REPORT_SCRIPT}" ]] || { echo "missing ${REPORT_SCRIPT}" >&2; exit 1; }

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

# Issue and label mutations that must raise an `issues` event run as the App:
# events raised through the workflow's GITHUB_TOKEN never start workflows, so a
# findings issue created with it would not reach issue-driver.yml on its own.
# The workflow stages the App key and exports GH_APP_TOKEN (get-token.sh);
# offline tests leave it unset, exercising the GITHUB_TOKEN path.
gh_app() {
  if [[ -n "${GH_APP_TOKEN:-}" ]]; then
    GH_TOKEN="${GH_APP_TOKEN}" gh "$@"
  else
    gh "$@"
  fi
}

# The Projects API is outside the workflow's GITHUB_TOKEN, so the loop reaches
# it with the App installation token (GH_APP_TOKEN), which carries the
# repository "Projects" permission the owner granted. Only run when the loop can
# reach the Project: the workflow always has the App token, while an offline run
# needs an explicit PROJECT_NUMBER / PROJECT_TITLE.
project_configured() {
  [[ -n "${GH_APP_TOKEN:-}" || -n "${project_number}" || -n "${project_title}" ]]
}

gh_project() {
  if [[ -n "${GH_APP_TOKEN:-}" ]]; then
    GH_TOKEN="${GH_APP_TOKEN}" gh "$@"
  else
    gh "$@"
  fi
}

# Resolve the Project number to add items to: an explicit --project-number wins;
# otherwise find the Project by title and create it when it is missing. Prints
# the number, or nothing on failure (the caller warns and falls back to the
# Project's built-in auto-add).
resolve_project_number() {
  if [[ -n "${project_number}" ]]; then
    printf '%s\n' "${project_number}"
    return 0
  fi
  local owner="${project_owner:-${repo%%/*}}"
  local title="${project_title:-${PROJECT_TITLE_DEFAULT}}"
  title="${title//\"/}"
  local number
  number="$(gh_project project list --owner "${owner}" --limit 100 --format json \
    --jq ".projects[] | select(.title == \"${title}\") | .number" 2>/dev/null \
    | head -n 1 || true)"
  if [[ -z "${number}" ]]; then
    number="$(gh_project project create --owner "${owner}" --title "${title}" \
      --format json --jq '.number' 2>/dev/null || true)"
  fi
  [[ "${number}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${number}"
}

# GitHub rejects an issue/comment body longer than 65536 characters
# ("GraphQL: Body is too long ... (createIssue)"). A weekly report over enough
# runs (or long log excerpts) reaches that, and the old single-body post then
# failed with nothing published. Split instead of dropping: the report is the
# findings issue's material, so the tail is posted as continuation comments.
# The cap is in bytes - UTF-8 text is at least one byte per character, so a
# byte cap is a conservative character cap - and parts are cut at line
# boundaries, so no multibyte character is torn in half.
BODY_MAX_BYTES=60000

# Split file $1 into parts of at most $3 bytes under directory $2, printing the
# part paths in order. A single line longer than one part is sliced so the
# split always makes progress.
split_body_file() {
  local src="${1}" out_dir="${2}" limit="${3}"
  mkdir -p "${out_dir}"
  rm -f "${out_dir}"/part-*.md
  if [[ ! -s "${src}" ]]; then
    : > "${out_dir}/part-00001.md"
    printf '%s\n' "${out_dir}/part-00001.md"
    return 0
  fi
  LC_ALL=C awk -v limit="${limit}" -v dir="${out_dir}" '
    BEGIN {
      part = 1; size = 0; file = sprintf("%s/part-%05d.md", dir, part)
      # Byte values 0x80..0xBF are UTF-8 continuation bytes: when a line has to
      # be sliced, back the cut off them so no multibyte character is torn.
      for (i = 128; i < 192; i++) cont[sprintf("%c", i)] = 1
    }
    {
      line = $0
      linelen = length(line) + 1
      if (size > 0 && size + linelen > limit) {
        close(file)
        part++
        file = sprintf("%s/part-%05d.md", dir, part)
        size = 0
      }
      while (linelen > limit) {
        cut = limit - 1
        while (cut > 0 && (substr(line, cut + 1, 1) in cont)) cut--
        if (cut < 1) cut = 1
        print substr(line, 1, cut) >> file
        line = substr(line, cut + 1)
        linelen = length(line) + 1
        close(file)
        part++
        file = sprintf("%s/part-%05d.md", dir, part)
        size = 0
      }
      print line >> file
      size += linelen
    }
    END {
      close(file)
      for (i = 1; i <= part; i++) printf "%s/part-%05d.md\n", dir, i
    }
  ' "${src}"
}

# Comment the continuation parts of a split body on an issue, so a body too
# long for a single GitHub issue/comment still arrives in full.
# Args: number part...
comment_file_continuation() {
  local number="${1}"
  shift
  local part
  for part in "$@"; do
    gh issue comment "${number}" --repo "${repo}" --body-file "${part}"
  done
}

# Add an issue to the resolved Project. A failure only warns: the report and the
# findings issue are already published, and a Project hiccup must not lose them.
# Args: issue-url
add_to_project() {
  local issue_url="${1}"
  [[ -n "${issue_url}" && -n "${project_number_resolved}" ]] || return 0
  local owner="${project_owner:-${repo%%/*}}"
  gh_project project item-add "${project_number_resolved}" --owner "${owner}" \
    --url "${issue_url}" >/dev/null 2>&1 \
    || echo "warning: failed to add ${issue_url} to project #${project_number_resolved}" >&2
}

# Resolve the Project once. project_number_resolved stays empty when no Project
# is configured or it cannot be resolved; the loop then relies on the Project's
# built-in auto-add.
project_number_resolved=""
if project_configured; then
  if project_number_resolved="$(resolve_project_number)"; then
    echo "using GitHub Project #${project_number_resolved} (owner: ${project_owner:-${repo%%/*}})" >&2
  else
    project_number_resolved=""
    echo "warning: could not resolve the GitHub Project; relying on its built-in auto-add" >&2
  fi
fi

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
tracking_parts=()
while IFS= read -r part; do tracking_parts+=("${part}"); done \
  < <(split_body_file "${comment}" "${tmp_dir}/tracking-parts" "${BODY_MAX_BYTES}")
if [[ -n "${tracking}" ]]; then
  gh issue comment "${tracking}" --repo "${repo}" --body-file "${tracking_parts[0]}"
  comment_file_continuation "${tracking}" "${tracking_parts[@]:1}"
  add_to_project "https://github.com/${repo}/issues/${tracking}"
  echo "appended this week's report to tracking issue #${tracking}" >&2
else
  url="$(gh issue create --repo "${repo}" --title "${TRACKING_TITLE}" --body-file "${tracking_parts[0]}")"
  comment_file_continuation "${url##*/}" "${tracking_parts[@]:1}"
  add_to_project "${url}"
  echo "created the tracking issue: ${url}" >&2
fi

# --- 4. hand actionable findings to the driver --------------------------------
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

# The label is the marker both issue-driver.yml (bot-authored exception) and the
# Project's built-in auto-add key off, so make sure it exists before it is used.
gh_app label create "${SELF_IMPROVEMENT_LABEL}" --repo "${repo}" \
  --color "${LABEL_COLOR}" --description "${LABEL_DESCRIPTION}" --force >/dev/null

body_parts=()
while IFS= read -r part; do body_parts+=("${part}"); done \
  < <(split_body_file "${body}" "${tmp_dir}/findings-parts" "${BODY_MAX_BYTES}")

num="$(gh issue list --repo "${repo}" --state open --limit 200 \
  --json number,title \
  --jq '.[] | select(.title | startswith("auto-drive findings")) | .number' \
  | head -n 1)"
if [[ -n "${num}" ]]; then
  gh issue comment "${num}" --repo "${repo}" --body-file "${body_parts[0]}"
  comment_file_continuation "${num}" "${body_parts[@]:1}"
  add_to_project "https://github.com/${repo}/issues/${num}"
  echo "added this week's findings to issue #${num}" >&2
  # An existing issue raises no `issues: opened`, so dispatch the driver once
  # for this week's findings; a freshly created issue starts it by itself.
  if [[ -n "${dispatch_ref}" ]]; then
    gh workflow run issue-driver.yml --repo "${repo}" --ref "${dispatch_ref}" -f number="${num}"
  else
    gh workflow run issue-driver.yml --repo "${repo}" -f number="${num}"
  fi
  echo "dispatched Issue auto-drive (workflow_dispatch number=${num})" >&2
else
  url="$(gh_app issue create --repo "${repo}" --title "${FINDINGS_PREFIX}: ${stamp}" \
    --label "${SELF_IMPROVEMENT_LABEL}" --body-file "${body_parts[0]}")"
  num="${url##*/}"
  [[ "${num}" =~ ^[0-9]+$ ]] || { echo "could not read the new issue number from ${url}" >&2; exit 1; }
  comment_file_continuation "${num}" "${body_parts[@]:1}"
  add_to_project "${url}"
  # Created as the App with the self-improvement label: issue-driver.yml accepts
  # the bot-authored issue and starts on `issues: opened`, and the Project is
  # populated explicitly above (or by its built-in auto-add as a fallback). No
  # dispatch here, so the driver never runs twice for one opening.
  echo "created findings issue #${num}" >&2
fi
