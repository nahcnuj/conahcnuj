#!/usr/bin/env bash
# conahcnuj "an empty round retries the same model" test (offline).
#
# A round that ends normally but leaves the working tree untouched and writes no
# .commit-msg (e.g. the model gave up after a permission prompt was declined)
# says nothing a different model would fix. The driver must not move on to the
# next model for such a non-rate-limit reason: it retries the SAME model. Only
# when the run's time budget is exhausted does the run end (with a bug report
# like any other unimplemented issue).
#
#   issue read -> branch -> implement (no change, no message) -> retry the same
#   model (second model is never tried) -> time budget exhausted -> exit 1 ->
#   bug report
#
# The budget is 5s so the retry loop is exercised without a long wait.
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
{"number": 14, "title": "test issue that retries the same model", "body": "dummy body", "labels": [], "state": "open"}
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
  CONAHCNUJ_MAX_SECONDS=5 bash "${DRIVER}" 14 < "${TAPE}"
) > "${LOG}" 2>&1 || RC=$?

echo "----- conahcnuj no-work retry run log -----"
cat "${LOG}"
echo "-------------------------------------------"

[[ ${RC} -eq 1 ]] || { echo "FAIL: driver exit code ${RC} (expected 1)"; exit 1; }

grep -q "Model opencode/first produced no complete work; retrying with the same model." "${LOG}" || { echo "FAIL: the empty round was not retried with the same model"; exit 1; }
grep -q "produced no complete work; handing off" "${LOG}" && { echo "FAIL: an empty round still handed off to another model"; exit 1; }
# The same model was tried more than once, so it was retried rather than skipped.
[[ "$(grep -c "opencode: trying model opencode/first" "${LOG}")" -ge 2 ]] || { echo "FAIL: the same model was not retried"; exit 1; }
grep -q "opencode: trying model opencode/second" "${LOG}" && { echo "FAIL: the next model was tried after an empty round"; exit 1; }
grep -q "Model opencode/second" "${LOG}" && { echo "FAIL: the next model ran after an empty round"; exit 1; }
grep -q "time budget" "${LOG}" || { echo "FAIL: the run did not end on the time budget"; exit 1; }
grep -q "Bug report issue #25 created" "${LOG}" || { echo "FAIL: bug report issue #25 was not created"; exit 1; }

echo "conahcnuj no-work retry passed"
