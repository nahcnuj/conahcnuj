#!/usr/bin/env bash
# conahcnuj abnormal-exit bug-report test (offline).
#
# When the driver cannot resolve the issue it must not die silently: an
# abnormal exit (here: every model produces no changes, so implementation fails)
# triggers the EXIT trap, which files a bug report issue. The report goes to the
# conahcnuj repository (here configured with CONAHCNUJ_BUG_REPO=nahcnuj/conahcnuj),
# NOT to the repository being worked on (CONAHCNUJ_REPO=nahcnuj/makamujo): the
# bug is about the driver, and the GitHub App token is only guaranteed to be
# able to write to its own repository. The mocked API tape ends with the created
# issue's response. Asserts that the original exit code is preserved, the
# failure is logged, and the bug report issue landed in conahcnuj while the
# body still names the item worked on in makamujo.
#
# No secrets, no network.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
DRIVER="${REPO}/bin/conahcnuj.sh"
# The driver's own checkout origin: the auto-detected report target when no
# CONAHCNUJ_BUG_REPO is configured (used by the second scenario below).
DRIVER_REPO="$(git -C "${REPO}" remote get-url origin 2>/dev/null | sed -E 's#.*github\.com[:/]##; s#\.git$##' || true)"

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

# --- Scenario 1: explicit CONAHCNUJ_BUG_REPO --------------------------------
# Work on nahcnuj/makamujo; the bug report must land in nahcnuj/conahcnuj.
export CONAHCNUJ_BUG_REPO="nahcnuj/conahcnuj"
export CONAHCNUJ_REPO="nahcnuj/makamujo"

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
grep -q "filing a bug report issue in nahcnuj/conahcnuj" "${LOG}" || { echo "FAIL: no bug report filing message for conahcnuj"; exit 1; }
grep -q "Bug report issue #25 created" "${LOG}" || { echo "FAIL: bug report issue #25 was not created"; exit 1; }
grep -q "https://github.com/nahcnuj/conahcnuj/issues/25" "${LOG}" || { echo "FAIL: bug report URL is missing"; exit 1; }
grep -q "filing a bug report issue in nahcnuj/makamujo" "${LOG}" && { echo "FAIL: the report went to the working repository instead of conahcnuj"; exit 1; }

# --- Scenario 2: auto-detected report target ---------------------------------
# Without CONAHCNUJ_BUG_REPO the driver falls back to its own checkout's
# origin remote. The working repo is still nahcnuj/makamujo, so this proves
# the two repositories are decoupled by default.
unset CONAHCNUJ_BUG_REPO
if [[ -n "${DRIVER_REPO}" ]]; then
  LOG2="${ROOT}/run2.log"
  RC2=0
  (
    cd "${WORK}"
    CONAHCNUJ_MAX_SECONDS=120 bash "${DRIVER}" 14 < "${TAPE}"
  ) > "${LOG2}" 2>&1 || RC2=$?
  [[ ${RC2} -eq 1 ]] || { echo "FAIL: scenario 2 driver exit code ${RC2} (expected 1)"; exit 1; }
  grep -q "filing a bug report issue in ${DRIVER_REPO}" "${LOG2}" || { echo "FAIL: report did not go to the driver's own repository (${DRIVER_REPO})"; exit 1; }
fi

# --- unit: the bug report body carries a detailed error log -----------------
# Source the driver (CONAHCNUJ_IMPORT=1, so main() is not run) and stub
# gh_api_create_issue to capture the body it would send. Assert the report
# includes the tail of the run log and names the item worked on in the WORKING
# repository (nahcnuj/makamujo) even though the issue is filed in conahcnuj.
(
  export CONAHCNUJ_IMPORT=1
  unset CONAHCNUJ_REPO CONAHCNUJ_BUG_REPO
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
  BUG_WORK_OWNER="nahcnuj"
  BUG_WORK_REPO="makamujo"
  BUG_REPORT_INPUT="14"
  BUG_REPORTED="0"
  report_bug_on_exit "1"
  # bug_report_repo: explicit value wins over everything else.
  out1="$(CONAHCNUJ_BUG_REPO="nahcnuj/conahcnuj" bug_report_repo)"
  [[ "${out1}" == "nahcnuj/conahcnuj" ]] || { echo "FAIL: explicit CONAHCNUJ_BUG_REPO was not honoured"; exit 1; }
  # ... and with nothing configured the driver's own origin remote is used.
  out2="$(bug_report_repo)"
  if [[ -n "${DRIVER_REPO}" ]]; then
    [[ "${out2}" == "${DRIVER_REPO}" ]] || { echo "FAIL: auto-detected report repo ${out2} (expected ${DRIVER_REPO})"; exit 1; }
  fi
  run_log_cleanup
)

grep -q "## Error log" "${ROOT}/captured-body.txt" || { echo "FAIL: bug report has no error log section"; exit 1; }
grep -q "ERROR: could not implement issue #14 with any available model." "${ROOT}/captured-body.txt" || { echo "FAIL: the error log does not carry the failing message"; exit 1; }
grep -q "Exit code: 1" "${ROOT}/captured-body.txt" || { echo "FAIL: exit code is missing from the report"; exit 1; }
grep -q "nahcnuj/makamujo#14" "${ROOT}/captured-body.txt" || { echo "FAIL: the report does not name the item worked on in makamujo"; exit 1; }
grep -q "Repository:" "${ROOT}/captured-body.txt" && { echo "FAIL: self-evident repository line is still in the report"; exit 1; }

echo "conahcnuj abnormal-exit bug report passed"
