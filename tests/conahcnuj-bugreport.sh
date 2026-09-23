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

echo "conahcnuj abnormal-exit bug report passed"