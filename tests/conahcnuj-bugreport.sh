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
#   fetch_issue, get_repo, find_pr_by_head_any (empty), create_issue (25).
# The mocked opencode is a no-op for every model, so implement produces no
# changes, start_issue exits 1, and the EXIT trap files the bug report (one
# extra API call reading the created issue's number).
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"number": 14, "title": "test issue that cannot be implemented", "body": "dummy body", "labels": [], "state": "open"}
{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"number": 25}
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
grep -q "filing a bug report issue in nahcnuj/conahcnuj" "${LOG}" || { echo "FAIL: no bug report filing message"; exit 1; }
grep -q "Bug report issue #25 created" "${LOG}" || { echo "FAIL: bug report issue #25 was not created"; exit 1; }
grep -q "https://github.com/nahcnuj/conahcnuj/issues/25" "${LOG}" || { echo "FAIL: bug report URL is missing"; exit 1; }

# --- unit: the bug report body carries a detailed error log -----------------
# Source the driver (CONAHCNUJ_IMPORT=1, so main() is not run) and stub
# gh_api_create_issue to capture the body it would send. Assert the report
# includes the tail of the run log and no longer repeats the self-evident
# repository name (reviewer: the report is filed in that very repository).
(
  export CONAHCNUJ_IMPORT=1
  unset CONAHCNUJ_REPO
  # Source the driver so its functions (plus our stub) run in one shell.
  # shellcheck source=bin/conahcnuj.sh
  source "${DRIVER}"
  gh_api_create_issue() {
    printf '%s\n' "${4}" > "${ROOT}/captured-body.txt"
    printf '99\n'
  }
  RUN_LOG_FILE="$(mktemp)"
  printf '%s\n' \
    "Issue #14: test issue that cannot be implemented" \
    "opencode: trying model opencode/first" \
    "ERROR: could not implement issue #14 with any available model." \
    > "${RUN_LOG_FILE}"
  BUG_REPORT_OWNER="nahcnuj"
  BUG_REPORT_REPO="conahcnuj"
  BUG_REPORT_INPUT="14"
  BUG_REPORTED="0"
  report_bug_on_exit "1"
)

grep -q "## Error log" "${ROOT}/captured-body.txt" || { echo "FAIL: bug report has no error log section"; exit 1; }
grep -q "ERROR: could not implement issue #14 with any available model." "${ROOT}/captured-body.txt" || { echo "FAIL: the error log does not carry the failing message"; exit 1; }
grep -q "Exit code: 1" "${ROOT}/captured-body.txt" || { echo "FAIL: exit code is missing from the report"; exit 1; }
grep -q "Repository:" "${ROOT}/captured-body.txt" && { echo "FAIL: self-evident repository line is still in the report"; exit 1; }

echo "conahcnuj abnormal-exit bug report passed"
