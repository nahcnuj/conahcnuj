#!/usr/bin/env bash
# conahcnuj "request changes while the driver's own run is pending" test (offline).
#
# Reproduces issue #115: a reviewer requests changes on a PR, which
# re-triggers "Issue auto-drive", and that run's own check is attached
# to the PR head commit while it is still running. poll_conditions used
# to count it as a pending constraint, so the driver waited for itself
# forever and never reached the review phase - the requested changes were
# never addressed.
#
# Drives bin/conahcnuj.sh <PR> against a mocked GitHub API tape whose
# statusCheckRollup enumerates the check contexts:
#
#   PR #15 state read -> head branch checked out -> constraints pass
#   (own run IN_PROGRESS is excluded) -> review requested ->
#   CHANGES_REQUESTED detected -> addressed and committed -> constraints
#   re-verified (own run CANCELLED is excluded too) -> replied -> polled
#   again (real CI still running keeps the driver waiting) -> APPROVED +
#   constraints -> "ready to merge" -> exit 0
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

# Mocked response tape, in call order. The conditions payloads carry a
# statusCheckRollup.contexts list so the driver's own workflow run can be
# told apart from real CI.
#   fetch_issue (auto-detect: PR input), fetch_pr_state, fetch_issue
#   (stub body -> real issue body), update_pr (body sync), continuation
#   comment, conditions (own run IN_PROGRESS), request_review,
#   fetch_reviews (CHANGES_REQUESTED), conditions (own run CANCELLED),
#   request_review, post_comment, fetch_reviews (fingerprint refresh after
#   the reply), conditions (real CI running), conditions (CI green),
#   fetch_reviews (APPROVED), conditions.
# The tape and log live OUTSIDE the repo (the driver's test-mode commit
# path runs `git add -A`).
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"title":"Fix something","body":"stub","labels":[],"pull_request":{}}
{"data":{"repository":{"pullRequest":{"number":15,"state":"OPEN","title":"Fix something","body":"Closes #10","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"CHANGES_REQUESTED","headRefName":"feature/fix-10","baseRefName":"main","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","closingIssuesReferences":{"nodes":[{"number":10}]}}}}}
{"number": 10, "title": "Fix something", "body": "# 背景\nPR を引き継いで再開できるようにする。", "labels": [{"name": "enhancement"}], "state": "open"}
{}
{"id":889}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"PENDING","contexts":{"nodes":[{"__typename":"CheckRun","name":"Attempt to resolve issue","status":"IN_PROGRESS","conclusion":null,"checkSuite":{"workflowRun":{"workflow":{"name":"Issue auto-drive"}}}},{"__typename":"CheckRun","name":"Lint shell scripts (ubuntu-latest)","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}}],"pageInfo":{"hasNextPage":false}}}}}]}}}}}
{}
{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[{"state":"CHANGES_REQUESTED","body":"Please rename this function","author":{"login":"reviewer"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE","contexts":{"nodes":[{"__typename":"CheckRun","name":"Attempt to resolve issue","status":"COMPLETED","conclusion":"CANCELLED","checkSuite":{"workflowRun":{"workflow":{"name":"Issue auto-drive"}}}},{"__typename":"CheckRun","name":"Lint shell scripts (ubuntu-latest)","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}}],"pageInfo":{"hasNextPage":false}}}}}]}}}}}
{}
{"id":888}
{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[{"state":"CHANGES_REQUESTED","body":"Please rename this function","author":{"login":"reviewer"}}]},"comments":{"nodes":[{"body":"Addressed the review feedback:\n\nreviewDecision: CHANGES_REQUESTED","author":{"login":"conahcnuj[bot]"}}]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"PENDING","contexts":{"nodes":[{"__typename":"CheckRun","name":"Attempt to resolve issue","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"Issue auto-drive"}}}},{"__typename":"CheckRun","name":"Lint shell scripts (ubuntu-latest)","status":"IN_PROGRESS","conclusion":null,"checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}}],"pageInfo":{"hasNextPage":false}}}}}]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS","contexts":{"nodes":[{"__typename":"CheckRun","name":"Attempt to resolve issue","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"Issue auto-drive"}}}},{"__typename":"CheckRun","name":"Lint shell scripts (ubuntu-latest)","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}}],"pageInfo":{"hasNextPage":false}}}}}]}}}}}
{"data":{"repository":{"pullRequest":{"reviewDecision":"APPROVED","reviews":{"nodes":[{"state":"APPROVED","body":"LGTM","author":{"login":"reviewer"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS","contexts":{"nodes":[{"__typename":"CheckRun","name":"Attempt to resolve issue","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"Issue auto-drive"}}}},{"__typename":"CheckRun","name":"Lint shell scripts (ubuntu-latest)","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}}],"pageInfo":{"hasNextPage":false}}}}}]}}}}}
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

grep -q "Ready to merge" "${LOG}" || { echo "FAIL: no ready-to-merge line"; exit 1; }
grep -q "New review feedback detected" "${LOG}" || { echo "FAIL: the requested changes were not acted on"; exit 1; }
grep -q "Replied on PR #15 after addressing review feedback" "${LOG}" || { echo "FAIL: feedback reply was not posted"; exit 1; }

# The driver's own run (pending, then cancelled) never became a
# constraint: the poll reported SUCCESS instead of waiting for itself.
grep -q "PR #15 constraints: checks=SUCCESS" "${LOG}" || { echo "FAIL: own run was not excluded from the constraints"; exit 1; }
# Real CI that is still running is still waited for.
grep -q "PR #15 constraints: checks=PENDING" "${LOG}" || { echo "FAIL: a pending real CI check was not waited for"; exit 1; }
# And the driver must not have gone into the "fix the constraints" loop.
grep -q "constraints failing; fixing with a new implementation round" "${LOG}" && { echo "FAIL: the driver tried to fix its own run"; exit 1; }
grep -q "PR could not be created" "${LOG}" && { echo "FAIL: PR creation was retried"; exit 1; }

[[ "$(git -C "${WORK}" branch --show-current)" == "feature/fix-10" ]] || { echo "FAIL: wrong current branch"; exit 1; }
ONELINE="$(git -C "${WORK}" log --oneline)"
grep -q "mock commit from opencode/first" <<<"${ONELINE}" || { echo "FAIL: the agent's .commit-msg was not used for the commit"; exit 1; }

echo "conahcnuj own-check exclusion passed"
