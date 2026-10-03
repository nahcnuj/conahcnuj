#!/usr/bin/env bash
# Offline test for the "Merge and dispatch" step of
# .github/workflows/owner-approved-auto-merge.yml. The step body is a bash
# script embedded in YAML, so this test extracts that exact script from the
# workflow and runs it against a mock gh: no network, no secrets, no real run.
#
# Issue #119: this workflow runs once per owner approval, so failed (or
# concurrency-cancelled) runs of *itself* stay attached to the approved head
# SHA. Reading them as "a check did not pass" makes every approval after the
# first one fail, so they have to be excluded from the merge gate.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
WORKFLOW="${ROOT}/.github/workflows/owner-approved-auto-merge.yml"

# The fixtures use the run ids and head SHA of the real failure in issue #119.
HEAD_SHA="ced8d0399f96b8586297294df19f6480aa44557a"
OWN_RUN_ID="37132438272"
PREV_RUN_ID="37132381727"
CI_CHECK="Lint shell scripts (ubuntu-latest)"

fail() {
  local file="${1}" msg="${2}"
  echo "FAIL: ${msg}" >&2
  for file in "${1}" "${1}.stdout" "${1}.stderr" "${1}.calls"; do
    [[ ! -f "${file}" ]] && continue
    echo "--- ${file##*.} ---" >&2
    tail -n 30 "${file}" >&2
  done
  exit 1
}

# assert_contains <file> <needle> <message>; the step log files are named
# <run base>.stdout / .stderr / .calls and failures are reported per run base.
assert_contains() {
  grep -qF -- "${2}" "${1}" || fail "${3}" "${1%.*}"
}

# The step script is pulled out of the YAML instead of being duplicated here,
# so this test always exercises what actually ships.
extract_step_script() {
  local out="${1}"
  awk '
    /^[[:space:]]*- name: Merge and dispatch[[:space:]]*$/ { step = 1; next }
    step && /^[[:space:]]*run: \|[[:space:]]*$/ { body = 1; next }
    body {
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      match($0, /^[[:space:]]*/)
      if (indent == 0) { indent = RLENGTH }
      if (RLENGTH < indent) { exit }
      print substr($0, indent + 1)
    }
  ' "${WORKFLOW}" > "${out}"
}

# Mock gh: answers only the endpoints the step calls, from fixtures passed
# through the environment, and records every invocation.
write_mock_gh() {
  local dir="${1}"
  mkdir -p "${dir}"
  cat > "${dir}/gh" <<'MOCK'
#!/usr/bin/env bash
set -uo pipefail

printf 'gh %s\n' "$*" >> "${MOCK_CALL_LOG}"

if [ "${1:-}" = "pr" ]; then
  case "${2:-}" in
    merge)
      printf '%s\n' "${MOCK_MERGE_OUTPUT:-merged}"
      exit "${MOCK_MERGE_EXIT:-0}"
      ;;
    view)
      printf '%s\n' "${MOCK_PR_VIEW_OUTPUT:-{}}"
      exit 0
      ;;
  esac
  exit 0
fi

if [ "${1:-}" = "api" ]; then
  case "${2:-}" in
    */pulls/*) cat "${MOCK_PR_JSON}" ;;
    */actions/runs/*/jobs*)
      cat "${MOCK_JOBS_JSON}"
      exit "${MOCK_JOBS_EXIT:-0}"
      ;;
    */check-runs*)
      # Serve the per-poll sequence: seq/1.json, seq/2.json, ... and keep
      # repeating the last entry once the sequence is exhausted.
      n="$(cat "${MOCK_COUNTER}")"
      n=$((n + 1))
      printf '%s' "${n}" > "${MOCK_COUNTER}"
      while [ ! -f "${MOCK_SEQ_DIR}/${n}.json" ]; do
        [ "${n}" -gt 1 ] || break
        n=$((n - 1))
      done
      cat "${MOCK_SEQ_DIR}/${n}.json"
      ;;
    */status) cat "${MOCK_STATUS_JSON}" ;;
    *) printf '%s\n' '{}' ;;
  esac
  exit 0
fi

exit 0
MOCK
  chmod +x "${dir}/gh"
}

# check_run <name> <status> <conclusion> <run-id> -> one check run document
check_run() {
  jq -n --arg name "${1}" --arg status "${2}" --arg conclusion "${3}" --arg run "${4}" '
    {check_runs: [{
       name: $name,
       status: $status,
       conclusion: (if $conclusion == "" then null else $conclusion end),
       details_url: "https://github.com/nahcnuj/conahcnuj/actions/runs/\($run)/job/1",
       html_url: "https://github.com/nahcnuj/conahcnuj/actions/runs/\($run)/job/1"
     }]}'
}

# check_payload <check_run document>... -> a check-runs API response on stdout
check_payload() {
  printf '%s\n' "$@" | jq -s '{total_count: (map(.check_runs) | add | length), check_runs: (map(.check_runs) | add)}'
}

# write_seq <dir> <first index> <fixture>... -> per-poll check-runs fixtures
write_seq() {
  local dir="${1}" n="${2}"
  shift 2
  mkdir -p "${dir}"
  for f in "$@"; do
    n=$((n + 1))
    cp "${f}" "${dir}/${n}.json"
  done
}

# run_step <out> <seq-dir> [KEY=VALUE ...] -> exit status of the step script.
# Trailing KEY=VALUE pairs replace the defaults below (e.g. MOCK_MERGE_EXIT=1).
run_step() {
  local out="${1}" seq="${2}"
  shift 2
  local -a defaults=(
    "PATH=${MOCK_BIN}:${PATH}"
    "GH_TOKEN=test-token"
    "REPOSITORY=nahcnuj/conahcnuj"
    "PR_NUMBER=117"
    "HEAD_SHA=${HEAD_SHA}"
    "MERGE_METHOD=merge"
    "POST_MERGE_DISPATCH="
    "GITHUB_RUN_ID=${OWN_RUN_ID}"
    "CHECK_INTERVAL=0"
    "CHECK_TIMEOUT=5"
    "MOCK_CALL_LOG=${out}.calls"
    "MOCK_COUNTER=${out}.counter"
    "MOCK_SEQ_DIR=${seq}"
    "MOCK_PR_JSON=${PR_JSON}"
    "MOCK_JOBS_JSON=${JOBS_JSON}"
    "MOCK_JOBS_EXIT=0"
    "MOCK_STATUS_JSON=${STATUS_JSON}"
    "MOCK_MERGE_EXIT=0"
    "MOCK_MERGE_OUTPUT=merged"
    "MOCK_PR_VIEW_OUTPUT={}"
  )
  local -a step_env=()
  local kv k o keep
  for kv in "${defaults[@]}"; do
    k="${kv%%=*}"
    keep=1
    for o in "$@"; do
      if [[ "${o%%=*}" == "${k}" ]]; then
        keep=0
        break
      fi
    done
    if [[ "${keep}" == "1" ]]; then
      step_env+=("${kv}")
    fi
  done
  step_env+=("$@")

  printf '%s' "0" > "${out}.counter"
  : > "${out}.calls"
  local rc=0
  env "${step_env[@]}" bash "${SCRIPT}" > "${out}.stdout" 2> "${out}.stderr" || rc=$?
  printf '%s' "${rc}" > "${out}.rc"
}

merged() {
  grep -q "gh pr merge" "${1}.calls"
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is required to run the workflow step offline"
  exit 0
fi

SCRIPT="${TMP}/step.sh"
extract_step_script "${SCRIPT}"
grep -q 'outstanding_checks' "${SCRIPT}" ||
  fail "${TMP}/extract" "could not extract the 'Merge and dispatch' script from ${WORKFLOW}"

MOCK_BIN="${TMP}/bin"
write_mock_gh "${MOCK_BIN}"

PR_JSON="${TMP}/pr.json"
JOBS_JSON="${TMP}/jobs.json"
STATUS_JSON="${TMP}/status.json"
jq -n --arg sha "${HEAD_SHA}" '{head: {sha: $sha}, mergeable: "MERGEABLE", merge_state: "unstable", draft: false, merged: false}' > "${PR_JSON}"
jq -n '{jobs: [{name: "enable / enable", status: "in_progress", conclusion: null}]}' > "${JOBS_JSON}"
jq -n '{state: "pending", statuses: []}' > "${STATUS_JSON}"

own_pending="$(check_run "enable / enable" "in_progress" "" "${OWN_RUN_ID}")"
own_failed="$(check_run "enable / enable" "completed" "failure" "${PREV_RUN_ID}")"
own_cancelled="$(check_run "enable / enable" "completed" "cancelled" "${PREV_RUN_ID}")"
ci_ok="$(check_run "${CI_CHECK}" "completed" "success" "37131658989")"
ci_pending="$(check_run "${CI_CHECK}" "in_progress" "" "37131658989")"
ci_failed="$(check_run "${CI_CHECK}" "completed" "failure" "37131658989")"

# --- issue #119: an earlier run of this workflow must not block the merge ---
test_ignores_earlier_run_failure() {
  local out="${TMP}/case-own-failure" seq="${TMP}/seq-own-failure"
  check_payload "${ci_ok}" "${own_failed}" > "${TMP}/own-failure.json"
  write_seq "${seq}" 0 "${TMP}/own-failure.json"
  run_step "${out}" "${seq}"
  [[ "$(cat "${out}.rc")" == "0" ]] || fail "${out}" "own run failure blocked the merge"
  assert_contains "${out}.stdout" "all checks passed" "reports all checks passed"
  merged "${out}" || fail "${out}" "gh pr merge was not called"
  assert_contains "${out}.calls" "--match-head-commit ${HEAD_SHA}" "merges the approved commit only"
}

test_ignores_cancelled_run() {
  local out="${TMP}/case-own-cancelled" seq="${TMP}/seq-own-cancelled"
  check_payload "${ci_ok}" "${own_cancelled}" > "${TMP}/own-cancelled.json"
  write_seq "${seq}" 0 "${TMP}/own-cancelled.json"
  run_step "${out}" "${seq}"
  [[ "$(cat "${out}.rc")" == "0" ]] || fail "${out}" "cancelled own run blocked the merge"
  merged "${out}" || fail "${out}" "gh pr merge was not called"
}

# Without the job list the step falls back to the run id, which still keeps the
# current run's own pending check out of the way (no self-deadlock).
test_own_pending_is_never_waited_for() {
  local out="${TMP}/case-own-pending" seq="${TMP}/seq-own-pending"
  check_payload "${own_pending}" "${ci_pending}" > "${TMP}/own-pending.json"
  check_payload "${own_pending}" "${ci_ok}" > "${TMP}/own-done.json"
  write_seq "${seq}" 0 "${TMP}/own-pending.json" "${TMP}/own-done.json"
  run_step "${out}" "${seq}" MOCK_JOBS_EXIT=1
  [[ "$(cat "${out}.rc")" == "0" ]] || fail "${out}" "own pending check deadlocked the step"
  assert_contains "${out}.stdout" "waiting for 1 check(s)" "waits for the CI check only"
  merged "${out}" || fail "${out}" "gh pr merge was not called"
}

# --- foreign checks still gate the merge ---
test_failed_ci_check_blocks() {
  local out="${TMP}/case-ci-failure" seq="${TMP}/seq-ci-failure" line
  line="$(printf 'failed\tcheck\t%s\tfailure' "${CI_CHECK}")"
  check_payload "${ci_failed}" "${own_pending}" > "${TMP}/ci-failure.json"
  write_seq "${seq}" 0 "${TMP}/ci-failure.json"
  run_step "${out}" "${seq}"
  [[ "$(cat "${out}.rc")" == "1" ]] || fail "${out}" "a failing CI check must fail the step"
  assert_contains "${out}.stderr" "${line}" "reports the failing check"
  assert_contains "${out}.stderr" "checks did not pass" "reports why it stopped"
  ! merged "${out}" || fail "${out}" "gh pr merge must not run with a failing check"
}

test_pending_ci_check_is_waited_for() {
  local out="${TMP}/case-ci-pending" seq="${TMP}/seq-ci-pending" line
  line="$(printf 'pending\tcheck\t%s\tin_progress' "${CI_CHECK}")"
  check_payload "${ci_pending}" "${own_pending}" > "${TMP}/ci-pending.json"
  check_payload "${ci_ok}" "${own_pending}" > "${TMP}/ci-done.json"
  write_seq "${seq}" 0 "${TMP}/ci-pending.json" "${TMP}/ci-done.json"
  run_step "${out}" "${seq}"
  [[ "$(cat "${out}.rc")" == "0" ]] || fail "${out}" "the step must merge once CI turns green"
  assert_contains "${out}.stdout" "${line}" "lists the pending check"
  assert_contains "${out}.stdout" "all checks passed" "reports all checks passed"
}

test_timeout_while_waiting() {
  local out="${TMP}/case-timeout" seq="${TMP}/seq-timeout"
  check_payload "${ci_pending}" "${own_pending}" > "${TMP}/ci-pending.json"
  write_seq "${seq}" 0 "${TMP}/ci-pending.json"
  run_step "${out}" "${seq}" CHECK_TIMEOUT=0
  [[ "$(cat "${out}.rc")" == "1" ]] || fail "${out}" "the step must give up after the timeout"
  assert_contains "${out}.stderr" "timed out after 0s" "reports the timeout"
  ! merged "${out}" || fail "${out}" "gh pr merge must not run on timeout"
}

# --- merge itself ---
test_skips_when_head_moved() {
  local out="${TMP}/case-head-moved" seq="${TMP}/seq-head-moved" moved="${TMP}/pr-moved.json"
  jq -n --arg sha "0000000000000000000000000000000000000000" '{head: {sha: $sha}}' > "${moved}"
  check_payload "${ci_ok}" > "${TMP}/ci-done.json"
  write_seq "${seq}" 0 "${TMP}/ci-done.json"
  run_step "${out}" "${seq}" MOCK_PR_JSON="${moved}"
  [[ "$(cat "${out}.rc")" == "0" ]] || fail "${out}" "a moved head must not fail the step"
  assert_contains "${out}.stdout" "is not the current head" "reports the stale approval"
  ! merged "${out}" || fail "${out}" "gh pr merge must not run for a stale approval"
}

test_merge_failure_reports_pr_state() {
  local out="${TMP}/case-merge-failure" seq="${TMP}/seq-merge-failure"
  check_payload "${ci_ok}" > "${TMP}/ci-done.json"
  write_seq "${seq}" 0 "${TMP}/ci-done.json"
  run_step "${out}" "${seq}" MOCK_MERGE_EXIT=1 \
    MOCK_MERGE_OUTPUT="failed to merge: at least 1 required review is missing"
  [[ "$(cat "${out}.rc")" == "1" ]] || fail "${out}" "a merge failure must fail the step"
  assert_contains "${out}.stderr" "failed to merge" "keeps the gh error output"
  assert_contains "${out}.stderr" "merge failed for nahcnuj/conahcnuj#117" "names the PR"
  assert_contains "${out}.stderr" '"merge_state":"unstable"' "dumps the merge constraints"
  assert_contains "${out}.stderr" "is a required status check" "keeps the branch rules hint"
}

test_rejects_unknown_merge_method() {
  local out="${TMP}/case-merge-method" seq="${TMP}/seq-merge-method"
  check_payload "${ci_ok}" > "${TMP}/ci-done.json"
  write_seq "${seq}" 0 "${TMP}/ci-done.json"
  run_step "${out}" "${seq}" MERGE_METHOD=cherry-pick
  [[ "$(cat "${out}.rc")" == "1" ]] || fail "${out}" "an unknown merge method must fail the step"
  assert_contains "${out}.stderr" "unsupported merge method: cherry-pick" "reports the bad input"
  ! merged "${out}" || fail "${out}" "gh pr merge must not run with a bad method"
}

test_dispatches_after_merge() {
  local out="${TMP}/case-dispatch" seq="${TMP}/seq-dispatch"
  check_payload "${ci_ok}" > "${TMP}/ci-done.json"
  write_seq "${seq}" 0 "${TMP}/ci-done.json"
  run_step "${out}" "${seq}" POST_MERGE_DISPATCH=cd.yml
  [[ "$(cat "${out}.rc")" == "0" ]] || fail "${out}" "the dispatch step must not fail the workflow"
  assert_contains "${out}.calls" "gh workflow run cd.yml --repo nahcnuj/conahcnuj" "dispatches the deploy workflow"
}

test_ignores_earlier_run_failure
test_ignores_cancelled_run
test_own_pending_is_never_waited_for
test_failed_ci_check_blocks
test_pending_ci_check_is_waited_for
test_timeout_while_waiting
test_skips_when_head_moved
test_merge_failure_reports_pr_state
test_rejects_unknown_merge_method
test_dispatches_after_merge

echo "All auto-merge workflow tests passed"
