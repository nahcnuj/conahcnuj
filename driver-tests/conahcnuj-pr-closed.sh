#!/usr/bin/env bash
# conahcnuj "the PR was closed without merge" test (offline).
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

TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'TAPEEOF'
{"title":"Fix something","body":"","labels":[],"pull_request":{}}
{"data":{"repository":{"pullRequest":{"number":15,"state":"CLOSED","title":"Fix something","body":"","isDraft":false,"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN","reviewDecision":null,"headRefName":"feature/fix-10","baseRefName":"main","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","closingIssuesReferences":{"nodes":[{"number":10}]}}}}}}
TAPEEOF

export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export MOCK_OPENCODE_MODELS="opencode/first"
export CONAHCNUJ_REPO="nahcnuj/conahcnuj"

LOG="${ROOT}/run.log"
RC=0
(
  cd "${WORK}"
  CONAHCNUJ_MAX_SECONDS=120 bash "${DRIVER}" 15 < "${TAPE}"
) > "${LOG}" 2>&1 || RC=$?

echo "----- conahcnuj run log -----"
cat "${LOG}"
echo "-----------------------------"

[[ ${RC} -eq 0 ]] || { echo "FAIL: driver exited ${RC} (expected 0)"; exit 1; }

grep -q "PR #15 is closed without merge. Nothing to do." "${LOG}" || { echo "FAIL: the closed PR was not recognised"; exit 1; }
grep -q "Driver exited abnormally" "${LOG}" && { echo "FAIL: a bug report was filed for a closed PR"; exit 1; }
grep -q "Bug report issue" "${LOG}" && { echo "FAIL: a bug report issue was created for a closed PR"; exit 1; }
grep -q "Implementing with available models" "${LOG}" && { echo "FAIL: the driver implemented something on a closed PR"; exit 1; }

echo "conahcnuj closed-PR handling passed"
