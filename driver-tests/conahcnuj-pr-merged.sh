#!/usr/bin/env bash
# conahcnuj "the PR was merged while the driver waited" test (offline).
#
# The auto-merge job merges the PR once CI is green and no longer waits for the
# driver's own check run (they used to wait for each other and deadlock,
# issue #115), so the PR can be merged out from under poll_conditions. A merged
# PR is never MERGEABLE again, so the driver has to recognise it and stop
# instead of polling until its time budget runs out and it files a bug report.
#
#   PR #15 state read -> head branch checked out -> collected context
#   (nothing open) -> PR body sync -> continuation comment -> conditions
#   (PR already merged) -> stop, exit 0
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
#   fetch_issue (auto-detect: PR input), fetch_pr_state, fetch_reviews
#   (collection: nothing open), update_pr (body sync), continuation comment,
#   fetch_reviews (nothing actionable), conditions (PR merged). Reviews are read
#   before the constraints poll (#219), so the review phase sees no feedback and
#   falls through to the poll that recognises the merge.
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"title":"Fix something","body":"","labels":[],"pull_request":{}}
{"data":{"repository":{"pullRequest":{"number":15,"state":"OPEN","title":"Fix something","body":"# 背景\nPR が merge されたあとにもドライバがループしないこと。","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","reviewDecision":"APPROVED","headRefName":"feature/fix-10","baseRefName":"main","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","closingIssuesReferences":{"nodes":[{"number":10}]}}}}}}
{"data":{"repository":{"pullRequest":{"reviewDecision":"APPROVED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{}
{"id":889}
{"data":{"repository":{"pullRequest":{"reviewDecision":null,"reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN","state":"MERGED","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
EOF

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

grep -q "PR #15 is merged while waiting; nothing left to do" "${LOG}" || { echo "FAIL: the merged PR was not recognised"; exit 1; }
# A merged PR is nothing left to drive: no model round, no review request, and
# above all no bug report about a run that did exactly what it should.
grep -q "Implementing with available models" "${LOG}" && { echo "FAIL: the driver implemented something on a merged PR"; exit 1; }
grep -q "constraints failing; fixing" "${LOG}" && { echo "FAIL: the driver tried to fix the constraints of a merged PR"; exit 1; }
grep -q "Driver exited abnormally" "${LOG}" && { echo "FAIL: a bug report was filed for a merged PR"; exit 1; }
grep -q "constraints: checks=" "${LOG}" || { echo "FAIL: the constraints were never polled"; exit 1; }

echo "conahcnuj merged-PR handling passed"