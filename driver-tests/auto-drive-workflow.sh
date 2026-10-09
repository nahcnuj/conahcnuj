#!/usr/bin/env bash
# auto-drive-workflow.sh (bin) offline test using a mock `gh` on PATH.
#
# Pins the weekly self-improvement loop's contract without network: run-log
# collection, report publication on the tracking issue, and the findings issue
# (labelled `self-improvement`) that lets issue-driver.yml pick it up by itself.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
WF="${REPO}/bin/auto-drive-workflow.sh"

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT
mkdir -p "${ROOT}/bin" "${ROOT}/mock-logs" "${ROOT}/state"
export MOCK_STATE="${ROOT}/state"
export MOCK_RUN_LOGS_DIR="${ROOT}/mock-logs"

cat > "${ROOT}/bin/gh" <<'MOCK'
#!/usr/bin/env bash
# Offline mock of the gh commands auto-drive-workflow.sh uses. State lives in
# $MOCK_STATE (issues = "number|title|label" per line, next = issue counter,
# events = one action per line), run-logs live in $MOCK_RUN_LOGS_DIR as
# run-<id>.log.
set -euo pipefail

cmd="$1"
shift
state="${MOCK_STATE:?}"
logs="${MOCK_RUN_LOGS_DIR:?}"

# Flag a posted body that is not valid UTF-8, i.e. a character torn in half by
# the splitter. iconv is not on every platform, so the check is skipped where
# it is missing (same pattern as the jq-optional driver test).
record_utf8() {
  command -v iconv >/dev/null 2>&1 || return 0
  iconv -f UTF-8 -t UTF-8 "$1" >/dev/null 2>&1 \
    || printf 'invalid-utf8|%s\n' "$(basename "$1")" >> "${state}/bodies"
}

case "${cmd}" in
  api)
    # gh api [--paginate] URL --jq FILTER  (only the run listing is used)
    if [[ -f "${state}/run-ids" ]]; then
      cat "${state}/run-ids"
    fi
    ;;
  run)
    # gh run view <id> --repo R --log
    id=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo|--log) ;;
        view) ;;
        *) [[ "$1" =~ ^[0-9]+$ ]] && id="$1" ;;
      esac
      shift
    done
    if [[ -f "${logs}/run-${id}.log" ]]; then
      cat "${logs}/run-${id}.log"
      exit 0
    fi
    echo "mock: no log for run ${id}" >&2
    exit 1
    ;;
  issue)
    action="$1"
    shift
    case "${action}" in
      list)
        # gh issue list --repo R --state open --limit N --json number,title --jq FILTER
        filter=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --jq) shift; filter="$1" ;;
          esac
          shift
        done
        if [[ "${filter}" == *'select(.title == "auto-drive weekly self-improvement log")'* ]]; then
          awk -F'|' '$2 == "auto-drive weekly self-improvement log" {print $1}' "${state}/issues" 2>/dev/null | head -n 1 || true
        elif [[ "${filter}" == *'startswith("auto-drive findings")'* ]]; then
          awk -F'|' '$2 ~ /^auto-drive findings/ {print $1}' "${state}/issues" 2>/dev/null | head -n 1 || true
        else
          echo "mock: unhandled issue list filter: ${filter}" >&2
          exit 1
        fi
        ;;
      create)
        # gh issue create --repo R --title T [--label L] --body-file F  (prints the URL)
        title=""
        label=""
        body_file=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --title) shift; title="$1" ;;
            --label) shift; label="$1" ;;
            --body-file) shift; body_file="${1:-}" ;;
          esac
          shift
        done
        n="$(cat "${state}/next" 2>/dev/null || echo 1000)"
        echo $((n + 1)) > "${state}/next"
        printf '%s|%s|%s\n' "${n}" "${title}" "${label}" >> "${state}/issues"
        printf 'issue create %s label=%s\n' "${title}" "${label}" >> "${state}/events"
        if [[ -n "${body_file}" && -f "${body_file}" ]]; then
          printf 'create|%s|%s|%s\n' "${title}" "$(basename "${body_file}")" "$(wc -c < "${body_file}" | tr -d ' ')" >> "${state}/bodies"
          record_utf8 "${body_file}"
        fi
        echo "https://github.com/owner/repo/issues/${n}"
        ;;
      comment)
        # gh issue comment <num> --repo R --body-file F
        num=""
        body_file=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --repo) shift ;;
            --body-file) shift; body_file="${1:-}" ;;
            *) num="$1" ;;
          esac
          shift
        done
        printf 'issue comment %s\n' "${num}" >> "${state}/events"
        if [[ -n "${body_file}" && -f "${body_file}" ]]; then
          printf 'comment|%s|%s|%s\n' "${num}" "$(basename "${body_file}")" "$(wc -c < "${body_file}" | tr -d ' ')" >> "${state}/bodies"
          record_utf8 "${body_file}"
        fi
        ;;
    esac
    ;;
  label)
    # gh label create <name> --repo R ... --force
    action="$1"
    shift
    if [[ "${action}" == "create" ]]; then
      printf 'label create %s\n' "$1" >> "${state}/events"
    fi
    ;;
  workflow)
    # gh workflow run issue-driver.yml --repo R --ref B -f number=N
    n=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --repo|--ref) shift ;;
        number=*) n="${1#number=}" ;;
      esac
      shift
    done
    printf 'dispatch number=%s\n' "${n}" >> "${state}/events"
    echo "created workflow run"
    ;;
  project)
    # gh project list|create|item-add  (state/projects = "number|title" per line)
    action="$1"
    shift
    case "${action}" in
      list)
        # gh project list --owner O --limit N --format json --jq FILTER
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --owner|--limit|--format|--jq) shift ;;
          esac
          shift
        done
        if [[ -f "${state}/projects" ]]; then
          awk -F'|' '{print $1}' "${state}/projects" | head -n 1
        fi
        ;;
      create)
        # gh project create --owner O --title T --format json --jq FILTER
        title=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --owner) shift ;;
            --title) shift; title="$1" ;;
            --format) shift ;;
            --jq) shift ;;
          esac
          shift
        done
        n="$(cat "${state}/next-project" 2>/dev/null || echo 7)"
        printf '%s|%s\n' "${n}" "${title}" >> "${state}/projects"
        printf 'project create %s\n' "${title}" >> "${state}/events"
        echo "${n}"
        ;;
      item-add)
        # gh project item-add N --owner O --url URL
        number=""
        url=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --owner) shift ;;
            --url) shift; url="$1" ;;
            *) [[ "$1" =~ ^[0-9]+$ ]] && number="$1" ;;
          esac
          shift
        done
        printf 'project item-add %s %s\n' "${number}" "${url}" >> "${state}/events"
        ;;
      *)
        echo "mock: unhandled project subcommand: ${action}" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "mock: unhandled gh command: ${cmd} $*" >&2
    exit 1
    ;;
esac
MOCK
chmod +x "${ROOT}/bin/gh"
export PATH="${ROOT}/bin:${PATH}"

touch "${ROOT}/state/events" "${ROOT}/state/issues" "${ROOT}/state/bodies"
echo 1000 > "${ROOT}/state/next"

run_workflow() {
  bash "${WF}" --repo nahcnuj/conahcnuj \
    --runs-url-prefix https://example.com/runs \
    --lookback-days 7 --ref main \
    > "${ROOT}/report.md" 2> "${ROOT}/progress.txt"
}

cat > "${ROOT}/mock-logs/run-101.log" <<'EOF'
opencode: trying model opencode/alpha
Model opencode/alpha completed the work.
Created PR #126 (feature/x -> main).
Review requested on PR #126 (reviewer: nahcnuj): https://github.com/nahcnuj/conahcnuj/pull/126
EOF

# --- clean week: added to a fresh tracking issue, driver untouched ----------
printf '101\n' > "${ROOT}/state/run-ids"
run_workflow
grep -q '<!-- auto-drive-report runs=1 findings=0 actionable=0 -->' "${ROOT}/report.md" \
  || { echo "FAIL: clean report meta"; exit 1; }
grep -q '^issue create auto-drive weekly self-improvement log' "${ROOT}/state/events" \
  || { echo "FAIL: missing tracking issue creation"; exit 1; }
grep -q '^issue comment' "${ROOT}/state/events" && { echo "FAIL: clean week must not comment"; exit 1; }
grep -q '^label create' "${ROOT}/state/events" && { echo "FAIL: clean week must not label"; exit 1; }
grep -q '^dispatch' "${ROOT}/state/events" && { echo "FAIL: clean week must not dispatch"; exit 1; }

# --- existing tracking issue: report goes in as a comment --------------------
true > "${ROOT}/state/events"
printf '2|auto-drive weekly self-improvement log|\n' > "${ROOT}/state/issues"
run_workflow
grep -q '^issue comment 2$' "${ROOT}/state/events" \
  || { echo "FAIL: report must be commented on the existing tracking issue"; exit 1; }
grep -q '^issue create' "${ROOT}/state/events" && { echo "FAIL: tracking issue must not be re-created"; exit 1; }

# --- mixed week: findings issue created, labelled, not dispatched ------------
true > "${ROOT}/state/events"
true > "${ROOT}/state/issues"
echo 1100 > "${ROOT}/state/next"
cat > "${ROOT}/state/run-ids" <<'EOF'
202
203
EOF
cat > "${ROOT}/mock-logs/run-202.log" <<'EOF'
opencode: trying model opencode/alpha
Model opencode/alpha failed before completing the work: environment error (x)
ERROR: every model round died on an environment error (provider unreachable or credentials rejected)
Driver exited abnormally (code 1); filing a bug report issue in nahcnuj/conahcnuj.
Bug report issue #130 created: https://github.com/nahcnuj/conahcnuj/issues/130
EOF
cat > "${ROOT}/mock-logs/run-203.log" <<'EOF'
opencode: trying model opencode/alpha
Model opencode/alpha produced no complete work; handing off to the next model.
ERROR: no available model completed the work (tried: opencode/alpha; handoffs: none).
Driver exited abnormally (code 1); filing a bug report issue in nahcnuj/conahcnuj.
Bug report issue #131 created: https://github.com/nahcnuj/conahcnuj/issues/131
EOF
run_workflow
grep -q '<!-- auto-drive-report runs=2 findings=3 actionable=1 -->' "${ROOT}/report.md" \
  || { echo "FAIL: mixed report meta"; sed -n "1,4p" "${ROOT}/report.md"; exit 1; }
grep -q '^label create self-improvement$' "${ROOT}/state/events" \
  || { echo "FAIL: the self-improvement label must be ensured"; exit 1; }
grep -q '^issue create auto-drive findings.* label=self-improvement$' "${ROOT}/state/events" \
  || { echo "FAIL: findings issue must be created with the self-improvement label"; cat "${ROOT}/state/events"; exit 1; }
grep -q '^dispatch' "${ROOT}/state/events" \
  && { echo "FAIL: a freshly created labelled issue must not be dispatched (issues: opened starts it)"; exit 1; }

# --- a findings issue already exists: comment and dispatch a retry -----------
true > "${ROOT}/state/events"
printf '5|auto-drive findings: old|self-improvement\n' > "${ROOT}/state/issues"
run_workflow
grep -q '^issue comment 5$' "${ROOT}/state/events" \
  || { echo "FAIL: existing findings issue must get a comment"; exit 1; }
grep -q '^dispatch number=5$' "${ROOT}/state/events" \
  || { echo "FAIL: the existing findings issue must be retried"; exit 1; }
grep -q '^issue create auto-drive findings' "${ROOT}/state/events" \
  && { echo "FAIL: a second findings issue must not appear"; exit 1; }

# --- a Project is configured: issues land on it, the Project is created -------
# GITHUB_TOKEN cannot reach Projects v2, so the loop uses PROJECT_TOKEN (a
# classic PAT) and finds the Project by title, creating it when missing. Both
# the tracking issue and a fresh findings issue must become project items.
true > "${ROOT}/state/events"
true > "${ROOT}/state/issues"
rm -f "${ROOT}/state/projects"
echo 1500 > "${ROOT}/state/next"
printf '401\n' > "${ROOT}/state/run-ids"
cat > "${ROOT}/mock-logs/run-401.log" <<'EOF'
opencode: trying model opencode/alpha
Model opencode/alpha failed before completing the work: environment error (x)
ERROR: no available model completed the work (tried: opencode/alpha; handoffs: none).
Driver exited abnormally (code 1); filing a bug report issue in nahcnuj/conahcnuj.
Bug report issue #140 created: https://github.com/nahcnuj/conahcnuj/issues/140
EOF
export PROJECT_TOKEN=test-token
run_workflow
grep -q '^project create ' "${ROOT}/state/events" \
  || { echo "FAIL: the Project must be created when missing"; cat "${ROOT}/state/events"; exit 1; }
[[ "$(grep -c '^project item-add ' "${ROOT}/state/events" || true)" == "2" ]] \
  || { echo "FAIL: the tracking and findings issues must both be added to the Project"; cat "${ROOT}/state/events"; exit 1; }

# Re-running with the issues already present must still add them to the board
# (item-add is idempotent) and must reuse, not re-create, the Project, so a
# Project configured after the issues appeared still gets them.
true > "${ROOT}/state/events"
run_workflow
grep -q '^project create ' "${ROOT}/state/events" \
  && { echo "FAIL: an existing Project must not be re-created"; cat "${ROOT}/state/events"; exit 1; }
grep -q '^issue comment' "${ROOT}/state/events" \
  || { echo "FAIL: the second run must comment on the existing issues"; cat "${ROOT}/state/events"; exit 1; }
[[ "$(grep -c '^project item-add ' "${ROOT}/state/events" || true)" == "2" ]] \
  || { echo "FAIL: the existing tracking and findings issues must also be added"; cat "${ROOT}/state/events"; exit 1; }
unset PROJECT_TOKEN

# --- no Project configured: the Projects API stays untouched -----------------
# Without PROJECT_TOKEN or PROJECT_NUMBER the loop must not call the Projects
# API at all (the mock would exit 1 on an unhandled `gh project`), leaving the
# Project's built-in auto-add as the only path.
true > "${ROOT}/state/events"
true > "${ROOT}/state/issues"
rm -f "${ROOT}/state/projects"
printf '402\n' > "${ROOT}/state/run-ids"
cat > "${ROOT}/mock-logs/run-402.log" <<'EOF'
opencode: trying model opencode/alpha
Model opencode/alpha failed before completing the work: environment error (x)
ERROR: no available model completed the work (tried: opencode/alpha; handoffs: none).
Driver exited abnormally (code 1); filing a bug report issue in nahcnuj/conahcnuj.
Bug report issue #141 created: https://github.com/nahcnuj/conahcnuj/issues/141
EOF
run_workflow
grep -q '^project ' "${ROOT}/state/events" \
  && { echo "FAIL: an unconfigured Project must not be touched"; cat "${ROOT}/state/events"; exit 1; }

# --- oversized report: split across bodies, never rejected -------------------
# A single very long ERROR line pushes the report past GitHub's 65536-character
# issue/comment body limit. Posting it in one call failed with "GraphQL: Body
# is too long ... (createIssue)" and lost the report. The workflow must split
# the report across an issue body and continuation comments, each under the
# limit, so the full report still reaches the findings issue. The line is
# multibyte on purpose: slicing it must cut between characters, never through
# one (the mock's record_utf8 flags a torn body where iconv exists).
true > "${ROOT}/state/events"
true > "${ROOT}/state/bodies"
true > "${ROOT}/state/issues"
echo 1300 > "${ROOT}/state/next"
printf '301\n' > "${ROOT}/state/run-ids"
awk 'BEGIN { printf "ERROR: "; for (i = 0; i < 25000; i++) printf "日本語"; printf "\n" }' \
  > "${ROOT}/mock-logs/run-301.log"
[[ "$(wc -c < "${ROOT}/mock-logs/run-301.log")" -gt 65536 ]] \
  || { echo "FAIL: the oversized fixture must exceed the body limit"; exit 1; }
run_workflow
grep -q '<!-- auto-drive-report runs=1 findings=1 actionable=1 -->' "${ROOT}/report.md" \
  || { echo "FAIL: the oversized run must still be analyzed"; exit 1; }
awk -F'|' '$1 == "comment" { found = 1 } END { exit !found }' "${ROOT}/state/bodies" \
  || { echo "FAIL: an oversized report must be continued in comments"; cat "${ROOT}/state/bodies"; exit 1; }
awk -F'|' '($4 + 0) > 65536 { print "FAIL: body over the limit: " $0; exit 1 }' "${ROOT}/state/bodies" \
  || exit 1
grep -q '^invalid-utf8|' "${ROOT}/state/bodies" \
  && { echo "FAIL: the splitter tore a multibyte character"; cat "${ROOT}/state/bodies"; exit 1; }
# Both the tracking report and the findings issue are split, not truncated.
[[ "$(awk -F'|' '$1 == "create"' "${ROOT}/state/bodies" | wc -l | tr -d ' ')" == "2" ]] \
  || { echo "FAIL: tracking and findings issues must both be created"; exit 1; }
echo "auto-drive-workflow oversized-body test passed"

# --- usage: repo is required -------------------------------------------------
rc=0
env -u GITHUB_REPOSITORY bash "${WF}" --lookback-days 7 >/dev/null 2>&1 || rc=$?
[[ ${rc} -eq 1 ]] || { echo "FAIL: missing repo must exit 1"; exit 1; }

echo "auto-drive-workflow test passed"
