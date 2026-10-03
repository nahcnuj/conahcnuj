#!/usr/bin/env bash
# conahcnuj abnormal-exit bug-report test (offline).
#
# When the driver cannot resolve the issue it must not die silently: an
# abnormal exit (here: every model produces no changes, so implementation fails)
# triggers the EXIT trap, which files a bug report in the repository's
# discussion category. The mocked API tape ends with the created thread's
# response. Asserts that the original exit code is preserved, the failure is
# logged, and the bug report discussion was created.
#
# No secrets, no network.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
DRIVER="${REPO}/bin/conahcnuj.sh"

ROOT="$(mktemp -d)"
WORK="${ROOT}/repo"
trap 'rm -rf "${ROOT}"' EXIT
mkdir -p "${WORK}"

git -C "${WORK}" init -q
git -C "${WORK}" config user.email "test@example.com"
git -C "${WORK}" config user.name "test"
git -C "${WORK}" config commit.gpgsign false
printf 'base\n' > "${WORK}/file.txt"
git -C "${WORK}" add -A
git -C "${WORK}" commit -qm init

# Mocked response tape, in call order:
#   fetch_issue, get_repo, find_pr_by_head_any (empty), discussion category
#   (for the thread lookup), category threads (empty -> no thread to append
#   to), discussion category (again: creation resolves it too), then
#   createDiscussion (9).
# The mocked opencode is a no-op for every model, so implement produces no
# changes, start_issue exits 1, and the EXIT trap files the bug report (four
# extra API calls: category lookup, thread lookup, category lookup, thread
# creation).
MOCK_CATEGORIES='{"data":{"repository":{"id":"R_kgDOXmplR3p","discussionCategories":{"nodes":[{"id":"DIC_kwDOBBBBBB","name":"Bug report","slug":"bug-report"}]}}}}'
TAPE="${ROOT}/tape.txt"
{
  printf '%s\n' '{"number": 14, "title": "test issue that cannot be implemented", "body": "dummy body", "labels": [], "state": "open"}'
  printf '%s\n' '{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}}'
  printf '%s\n' '{"data":{"repository":{"pullRequests":{"nodes":[]}}}}'
  printf '%s\n' "${MOCK_CATEGORIES}"
  printf '%s\n' '{"data":{"repository":{"discussions":{"nodes":[]}}}}'
  printf '%s\n' "${MOCK_CATEGORIES}"
  printf '%s\n' '{"data":{"createDiscussion":{"discussion":{"number":9,"url":"https://github.com/nahcnuj/conahcnuj/discussions/9"}}}}'
} > "${TAPE}"

export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export MOCK_OPENCODE_MODELS="opencode/first"
export MOCK_OPENCODE_NOOP="opencode/first"
export CONAHCNUJ_REPO="nahcnuj/conahcnuj"

LOG="${ROOT}/run.log"
RC=0
(
  cd "${WORK}"
  CONAHCNUJ_MAX_SECONDS=120 bash "${DRIVER}" 14 < "${TAPE}"
) > "${LOG}" 2>&1 || RC=$?

echo "----- conahcnuj bugreport run log -----"
cat "${LOG}"
echo "----------------------------------------"

[[ ${RC} -ne 0 ]] || { echo "FAIL: driver exited 0 (expected an abnormal exit)"; exit 1; }
[[ ${RC} -eq 1 ]] || { echo "FAIL: driver exit code ${RC} (expected 1)"; exit 1; }

grep -q "could not implement issue #14" "${LOG}" || { echo "FAIL: implementation failure was not logged"; exit 1; }
grep -q "filing a bug report in nahcnuj/conahcnuj discussions (category: Bug report)" "${LOG}" || { echo "FAIL: no bug report filing message"; exit 1; }
grep -q "Bug report discussion #9 created" "${LOG}" || { echo "FAIL: bug report discussion #9 was not created"; exit 1; }
grep -q "https://github.com/nahcnuj/conahcnuj/discussions/9" "${LOG}" || { echo "FAIL: bug report URL is missing"; exit 1; }
# Bug reports must never become issues: an issue would re-trigger the driver's
# own workflow.
grep -qE "Bug report issue|issues/[0-9]+" "${LOG}" && { echo "FAIL: the bug report was filed as an issue"; exit 1; }

# Set once for the whole file: the unit blocks below source the driver, which
# would otherwise run main() on source.
export CONAHCNUJ_IMPORT=1

# --- unit: the bug report body carries a detailed error log -----------------
# Source the driver (CONAHCNUJ_IMPORT=1, so main() is not run) and stub the
# discussion helpers to capture the body it would send. Assert the report
# includes the tail of the run log and no longer repeats the self-evident
# repository name (reviewer: the report is filed in that very repository).
(
  unset CONAHCNUJ_REPO
  # Source the driver so its functions (plus our stub) run in one shell.
  # shellcheck source=bin/conahcnuj.sh
  source "${DRIVER}"
  gh_api_find_discussion_by_title() { :; }
  gh_api_create_discussion() {
    printf '%s\n' "${4}" > "${ROOT}/captured-title.txt"
    printf '%s\n' "${5}" > "${ROOT}/captured-body.txt"
    printf '99|https://github.com/nahcnuj/conahcnuj/discussions/99\n'
  }
  RUN_LOG_FILE="$(mktemp)"
  printf '%s\n' \
    "Issue #14: test issue that cannot be implemented" \
    "opencode: trying model opencode/first" \
    "ERROR: could not implement issue #14 with any available model." \
    > "${RUN_LOG_FILE}"
  BUG_REPORT_INPUT="14"
  BUG_REPORTED="0"
  report_bug_on_exit "1"
)

grep -q "## Error log" "${ROOT}/captured-body.txt" || { echo "FAIL: bug report has no error log section"; exit 1; }
grep -q "ERROR: could not implement issue #14 with any available model." "${ROOT}/captured-body.txt" || { echo "FAIL: the error log does not carry the failing message"; exit 1; }
grep -q "Exit code: 1" "${ROOT}/captured-body.txt" || { echo "FAIL: exit code is missing from the report"; exit 1; }
grep -q "Repository:" "${ROOT}/captured-body.txt" && { echo "FAIL: self-evident repository line is still in the report"; exit 1; }

# --- unit: the thread title groups reports of the same kind -----------------
# The title is the only grouping key, so it must stay free of per-run details
# (the exit code in particular): the same failure reported twice, with two exit
# codes, has to produce the same title and therefore the same thread.
(
  unset CONAHCNUJ_REPO
  # shellcheck source=bin/conahcnuj.sh
  source "${DRIVER}"
  [[ "$(report_bug_title 14)" == "conahcnuj: failed to resolve #14" ]] || exit 1
  [[ "$(report_bug_title 14)" == "$(report_bug_title 14)" ]] || exit 1
  [[ "$(report_bug_title "")" == "conahcnuj: driver terminated abnormally" ]] || exit 1
  [[ "$(report_bug_title 14)" != *"exit"* ]] || exit 1
) || { echo "FAIL: the bug report title must not carry per-run details"; exit 1; }

# --- unit: a repeated failure is appended to the same thread ----------------
# A thread with the same title already exists, so the report must become a reply
# on it (no second thread on the same bug).
(
  unset CONAHCNUJ_REPO
  # shellcheck source=bin/conahcnuj.sh
  source "${DRIVER}"
  gh_api_find_discussion_by_title() {
    printf '77|D_kwDOCcCCCCC|https://github.com/nahcnuj/conahcnuj/discussions/77\n'
  }
  gh_api_reply_discussion() {
    printf '%s\n' "${3}" > "${ROOT}/captured-reply-id.txt"
    printf '%s\n' "${4}" > "${ROOT}/captured-reply-body.txt"
    printf 'DC_kwDOEeEEEEE\n'
  }
  gh_api_create_discussion() {
    printf 'CALLED\n' > "${ROOT}/created-second-thread.txt"
  }
  RUN_LOG_FILE="$(mktemp)"
  printf '%s\n' "ERROR: could not implement issue #14 with any available model." > "${RUN_LOG_FILE}"
  BUG_REPORT_INPUT="14"
  BUG_REPORTED="0"
  report_bug_on_exit "1"
)

[[ ! -f "${ROOT}/created-second-thread.txt" ]] || { echo "FAIL: a second thread was opened for the same failure"; exit 1; }
[[ "$(cat "${ROOT}/captured-reply-id.txt")" == "D_kwDOCcCCCCC" ]] || { echo "FAIL: the report was not appended to the existing thread"; exit 1; }
grep -q "again on this failure" "${ROOT}/captured-reply-body.txt" || { echo "FAIL: the appended report does not read like a repeat"; exit 1; }
grep -q "Exit code: 1" "${ROOT}/captured-reply-body.txt" || { echo "FAIL: the appended report has no exit code"; exit 1; }

# --- unit: the rendered model log reaches the run log -----------------------
# The run log only captures stderr, so the renderer writes there. Assert that a
# tool block from a real opencode_run call lands in RUN_LOG_FILE: without this
# the bug report would show driver progress but nothing the model did.
(
  export CONAHCNUJ_TEST_MODE=1
  export OPENCODE_TEST_MODE=0
  mkdir -p "${ROOT}/fakebin"
  # printf '%s' (not printf) so the \n inside the JSON string stays escaped and
  # the event arrives as the single line opencode actually writes.
  cat > "${ROOT}/fakebin/opencode" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"type":"tool_use","part":{"type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"make check"},"output":"ok\n","metadata":{"exit":0},"title":"make check"}}}'
EOF
  chmod +x "${ROOT}/fakebin/opencode"
  PATH="${ROOT}/fakebin:${PATH}"
  export PATH
  # shellcheck source=bin/conahcnuj.sh
  source "${DRIVER}"
  run_log_start
  # Only stdout is sent to /dev/null: stderr must keep flowing into the FIFO
  # run_log_start installed, or there is nothing to capture.
  opencode_run "Issue" "Body" "${WORK}" "opencode/first" >/dev/null || true
  run_log_finalize
  cp "${RUN_LOG_FILE}" "${ROOT}/runlog-copy.txt"
  run_log_cleanup
)

grep -q '✅ make check' "${ROOT}/runlog-copy.txt" || {
  echo "FAIL: the rendered tool block is missing from the run log" >&2
  cat "${ROOT}/runlog-copy.txt" >&2
  exit 1
}
grep -q '{"type":"tool_use"' "${ROOT}/runlog-copy.txt" && {
  echo "FAIL: the raw JSON stream leaked into the run log" >&2
  exit 1
}

echo "conahcnuj abnormal-exit bug report passed"
