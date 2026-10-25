#!/usr/bin/env bash
# conahcnuj "cross-repository caller's own run must not be a constraint" test.
#
# Reproduces issue #497: a cross-repository caller (e.g. makamujo's
# "Auto-drive" workflow) invokes the reusable issue-driver workflow. The job's
# check then belongs to the caller workflow, so its name is "Auto-drive", not
# "Issue auto-drive". The name filter in CONAHCNUJ_OWN_WORKFLOWS alone missed
# it, poll_conditions counted the driver's own IN_PROGRESS check, and the run
# waited for itself until the time budget was gone.
#
# The driver now skips the check whose workflow run id is GITHUB_RUN_ID, so the
# same scenario must reach the review hand-off instead of timing out.
#
# Drives bin/conahcnuj.sh <PR> against a mocked GitHub API tape; GITHUB_RUN_ID
# is set to the id the own check run reports. No secrets, no network.
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

# The own check is named after the caller workflow ("Auto-drive") and carries
# the run id of the driver run doing the polling. Real CI is a different run.
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"title":"Fix something","body":"stub","labels":[],"pull_request":{}}
{"data":{"repository":{"pullRequest":{"number":15,"state":"OPEN","title":"Fix something","body":"Closes #10","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"CHANGES_REQUESTED","headRefName":"feature/fix-10","baseRefName":"main","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","closingIssuesReferences":{"nodes":[{"number":10}]}}}}}
{"number": 10, "title": "Fix something", "body": "# 背景\nPR を引き継いで再開できるようにする。", "labels": [{"name": "enhancement"}], "state": "open"}
{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{}
{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[{"state":"CHANGES_REQUESTED","body":"Please rename this function","author":{"login":"reviewer"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","state":"OPEN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"PENDING","contexts":{"nodes":[{"__typename":"CheckRun","name":"Auto-drive issue / Attempt to resolve issue","status":"IN_PROGRESS","conclusion":null,"checkSuite":{"workflowRun":{"databaseId":987654321,"workflow":{"name":"Auto-drive"}}}},{"__typename":"CheckRun","name":"Lint shell scripts (ubuntu-latest)","status":"IN_PROGRESS","conclusion":null,"checkSuite":{"workflowRun":{"databaseId":111111111,"workflow":{"name":"CI"}}}}],"pageInfo":{"hasNextPage":false}}}}}]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","state":"OPEN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE","contexts":{"nodes":[{"__typename":"CheckRun","name":"Auto-drive issue / Attempt to resolve issue","status":"COMPLETED","conclusion":"CANCELLED","checkSuite":{"workflowRun":{"databaseId":987654321,"workflow":{"name":"Auto-drive"}}}},{"__typename":"CheckRun","name":"enable / enable","status":"COMPLETED","conclusion":"FAILURE","checkSuite":{"workflowRun":{"databaseId":222222222,"workflow":{"name":"Owner-approved auto-merge"}}}},{"__typename":"CheckRun","name":"Lint shell scripts (ubuntu-latest)","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"databaseId":111111111,"workflow":{"name":"CI"}}}}],"pageInfo":{"hasNextPage":false}}}}}]}}}}}
{}
{"data":{"repository":{"pullRequest":{"reviewDecision":"APPROVED","reviews":{"nodes":[{"state":"APPROVED","body":"LGTM","author":{"login":"nahcnuj"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
EOF

export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export MOCK_OPENCODE_MODELS="opencode/first"
export CONAHCNUJ_REPO="nahcnuj/conahcnuj"
# What GitHub Actions exports to the reusable workflow: the caller's run id.
export GITHUB_RUN_ID=987654321

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

grep -q "Review requested on PR #15 (reviewer: nahcnuj): https://github.com/nahcnuj/conahcnuj/pull/15" "${LOG}" || { echo "FAIL: the PR was not handed back to the owner as reviewer"; exit 1; }
grep -q "Ready to merge" "${LOG}" || { echo "FAIL: the driver did not keep polling to the approval"; exit 1; }

# The caller's own check (pending, then cancelled) never became a constraint,
# while real CI that is still running was waited for.
grep -q "PR #15 constraints: checks=SUCCESS" "${LOG}" || { echo "FAIL: the cross-repo own run was not excluded from the constraints"; exit 1; }
grep -q "PR #15 constraints: checks=PENDING" "${LOG}" || { echo "FAIL: a pending real CI check was not waited for"; exit 1; }
grep -q "constraints failing; fixing with a new implementation round" "${LOG}" && { echo "FAIL: the driver tried to fix its own run"; exit 1; }
grep -q "time budget" "${LOG}" && { echo "FAIL: the driver exhausted its budget waiting for itself"; exit 1; }

ONELINE="$(git -C "${WORK}" log --oneline)"
grep -q "mock commit from opencode/first" <<<"${ONELINE}" || { echo "FAIL: the agent's .commit-msg was not used for the commit"; exit 1; }

echo "conahcnuj cross-repo own-check exclusion passed"
