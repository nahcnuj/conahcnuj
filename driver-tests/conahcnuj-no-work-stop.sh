#!/usr/bin/env bash
# conahcnuj "no complete work stops the fall-through" test (offline).
#
# A round that ends normally but leaves the working tree untouched and writes no
# .commit-msg (e.g. the model gave up after a permission prompt was declined)
# says nothing a different model would fix: the same prompt will be declined
# again. The driver must stop the model fall-through there instead of burning
# the rest of the model list, and end with a bug report like any other
# unimplemented issue.
#
#   issue read -> branch -> implement (first: no change, no message) -> STOP
#   (second model is never tried) -> exit 1 -> bug report
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

# Mocked response tape: fetch_issue, get_repo, find_pr_by_head_any (empty),
# create_issue. The second model would complete the work if it were tried; the
# test proves it is not.
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"number": 14, "title": "test issue that stops after no work", "body": "dummy body", "labels": [], "state": "open"}
{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"number": 25}
EOF

export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export MOCK_OPENCODE_MODELS="opencode/first
opencode/second"
# The first model ends its round without changing the tree or writing a message.
export MOCK_OPENCODE_NOOP="opencode/first"
export CONAHCNUJ_REPO="nahcnuj/conahcnuj"

LOG="${ROOT}/run.log"
RC=0
(
  cd "${WORK}"
  CONAHCNUJ_MAX_SECONDS=120 bash "${DRIVER}" 14 < "${TAPE}"
) > "${LOG}" 2>&1 || RC=$?

echo "----- conahcnuj no-work-stop run log -----"
cat "${LOG}"
echo "------------------------------------------"

[[ ${RC} -eq 1 ]] || { echo "FAIL: driver exit code ${RC} (expected 1)"; exit 1; }

grep -q "Model opencode/first produced no complete work." "${LOG}" || { echo "FAIL: the empty round was not reported"; exit 1; }
grep -q "produced no complete work; handing off" "${LOG}" && { echo "FAIL: an empty round still claimed a handoff"; exit 1; }
grep -q "opencode: trying model opencode/second" "${LOG}" && { echo "FAIL: the next model was tried after an empty round"; exit 1; }
grep -q "Model opencode/second" "${LOG}" && { echo "FAIL: the next model ran after an empty round"; exit 1; }
grep -q "could not implement issue #14" "${LOG}" || { echo "FAIL: implementation failure was not logged"; exit 1; }
grep -q "Bug report issue #25 created" "${LOG}" || { echo "FAIL: bug report issue #25 was not created"; exit 1; }

echo "conahcnuj no-work stop passed"
