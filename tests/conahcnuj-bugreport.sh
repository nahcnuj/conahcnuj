#!/usr/bin/env bash
# conahcnuj abnormal-exit bug-report test (offline).
#
# When the driver cannot resolve the issue it must not die silently: an
# abnormal exit (here: every model produces no changes, so implementation fails)
# triggers the EXIT trap, which files a bug report issue in the repository.
# The mocked API tape ends with the created issue's response. Asserts that the
# original exit code is preserved, the failure is logged, and the bug report
# issue was created.
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
#   fetch_issue, get_repo, find_pr_by_head_any (empty), discussion category,
#   discussions (empty), repo id, createDiscussion (25).
# The mocked opencode is a no-op for every model, so implement produces no
# changes, start_issue exits 1, and the EXIT trap files the bug report.
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"number": 14, "title": "test issue that cannot be implemented", "body": "dummy body", "labels": [], "state": "open"}
{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"discussionCategories":{"nodes":[{"id":"DIC_kwDO123","name":"Bug report"}]}}}}
{"data":{"repository":{"discussions":{"nodes":[]}}}}
{"data":{"repository":{"id":"R_kgDO123"}}}
{"data":{"createDiscussion":{"discussion":{"number":25,"url":"https://github.com/nahcnuj/conahcnuj/discussions/25"}}}}
EOF

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
grep -q "filing a bug report in nahcnuj/conahcnuj" "${LOG}" || { echo "FAIL: no bug report filing message"; exit 1; }
grep -q "Bug report discussion #25 created" "${LOG}" || { echo "FAIL: bug report issue #25 was not created"; exit 1; }
grep -q "https://github.com/nahcnuj/conahcnuj/discussions/25" "${LOG}" || { echo "FAIL: bug report URL is missing"; exit 1; }

# Set once for the whole file: the unit blocks below source the driver, which
# would otherwise run main() on source.
export CONAHCNUJ_IMPORT=1

# --- unit: the bug report body carries a detailed error log -----------------
# Source the driver (CONAHCNUJ_IMPORT=1, so main() is not run) and stub
# gh_api_create_issue to capture the body it would send. Assert the report
# includes the tail of the run log and no longer repeats the self-evident
# repository name (reviewer: the report is filed in that very repository).
(
  unset CONAHCNUJ_REPO
  # Source the driver so its functions (plus our stub) run in one shell.
  # shellcheck source=bin/conahcnuj.sh
  source "${DRIVER}"
  gh_api_create_issue() {
    printf '%s\n' "${4}" > "${ROOT}/captured-body.txt"
    printf '99\n'
  }
  # No Discussions in this repo -> the report falls back to an issue.
  gh_api_discussion_category_id() { return 1; }
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

# --- unit: the rendered model log reaches the run log -----------------------
# The run log only captures stderr, so the renderer writes there. Assert that a
# tool block from a real opencode_run call lands in RUN_LOG_FILE: without this
# the bug report would show driver progress but nothing the model did.
(
  # These exports are read only inside this subshell. SC2030.
  # shellcheck disable=SC2030
  export CONAHCNUJ_TEST_MODE=1
  # shellcheck disable=SC2030
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

# --- unit: a same-title discussion gets a comment, not a new thread ---------
# Grouping: reports with identical titles are the same failure mode, so the
# driver must append to the existing discussion instead of opening a new one.
(
  # shellcheck source=bin/conahcnuj.sh
  source "${DRIVER}"
  gh_api_create_issue() { echo '{"unexpected issue path"}' >&2; return 1; }
  gh_api_discussion_category_id() { printf 'DIC_kwDO456\n'; }
  gh_api_find_discussion_by_title() { printf 'D_1|25|https://github.com/nahcnuj/conahcnuj/discussions/25\n'; }
  gh_api_add_discussion_comment() {
    printf '%s\n' "${2}" > "${ROOT}/captured-comment.txt"
    printf 'DIC_1\n'
  }
  gh_api_create_discussion() { echo '{"unexpected create path"}' >&2; return 1; }
  RUN_LOG_FILE="$(mktemp)"
  printf '%s\n' "ERROR: boom" > "${RUN_LOG_FILE}"
  BUG_REPORT_INPUT="14"
  BUG_REPORTED="0"
  report_bug_on_exit "1" 2>"${ROOT}/grouping.log"
)
grep -q "updated (same failure mode)" "${ROOT}/grouping.log" || { echo "FAIL: no comment-on-existing path"; cat "${ROOT}/grouping.log"; exit 1; }
grep -q "ERROR: boom" "${ROOT}/captured-comment.txt" || { echo "FAIL: comment body missing the run log"; exit 1; }

echo "conahcnuj abnormal-exit bug report passed"
