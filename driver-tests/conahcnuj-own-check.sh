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
# The same deadlock has a second leg: the "Owner-approved auto-merge" job
# merges only after every other check on the approved head is green, this
# driver's run included, so its check stays pending for as long as the
# driver waits - and once the job gives up it fails, which the driver then
# tried to fix with yet another implementation round. Neither check belongs
# to a workflow this driver can unblock by changing code, so neither is a
# constraint (see CONAHCNUJ_OWN_WORKFLOWS in lib/gh-api.sh).
#
# Drives bin/conahcnuj.sh <PR> against a mocked GitHub API tape whose
# statusCheckRollup enumerates the check contexts:
#
#   PR #15 state read -> head branch checked out -> collected context
#   (no open threads, no README/AGENTS in the fixture) -> constraints pass
#   (own run IN_PROGRESS and the pending auto-merge check are both
#   excluded) -> CHANGES_REQUESTED detected -> the agent addresses it and
#   commits -> review re-requested from the owner -> constraints re-verified
#   (a pending real CI check still waits, then the own run CANCELLED and the
#   failed auto-merge check are excluded too) -> "review requested" -> exit 0
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
#   (stub body -> real issue body), fetch_reviews (collection: nothing open),
#   update_pr (body sync), continuation comment, fetch_reviews
#   (CHANGES_REQUESTED -> feedback round), request_review, conditions (own run
#   SUCCESS + real CI running -> PENDING), conditions (own run CANCELLED +
#   auto-merge FAILED + real CI SUCCESS -> SUCCESS). Reviews are read before the
#   constraints poll (#219); the feedback round posts no comment of its own: the
#   agent answers the reviewer in the thread.
# The tape and log live OUTSIDE the repo (the driver's test-mode commit
# path runs `git add -A`).
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"title":"Fix something","body":"stub","labels":[],"pull_request":{}}
{"data":{"repository":{"pullRequest":{"number":15,"state":"OPEN","title":"Fix something","body":"Closes #10","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"CHANGES_REQUESTED","headRefName":"feature/fix-10","baseRefName":"main","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","closingIssuesReferences":{"nodes":[{"number":10}]}}}}}
{"number": 10, "title": "Fix something", "body": "# 背景\nPR を引き継いで再開できるようにする。", "labels": [{"name": "enhancement"}], "state": "open"}
{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{}
{"id":889}
{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[{"state":"CHANGES_REQUESTED","body":"Please rename this function","author":{"login":"reviewer"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","state":"OPEN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"PENDING","contexts":{"nodes":[{"__typename":"CheckRun","name":"Attempt to resolve issue","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"Issue auto-drive"}}}},{"__typename":"CheckRun","name":"Lint shell scripts (ubuntu-latest)","status":"IN_PROGRESS","conclusion":null,"checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}}],"pageInfo":{"hasNextPage":false}}}}}]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","state":"OPEN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE","contexts":{"nodes":[{"__typename":"CheckRun","name":"Attempt to resolve issue","status":"COMPLETED","conclusion":"CANCELLED","checkSuite":{"workflowRun":{"workflow":{"name":"Issue auto-drive"}}}},{"__typename":"CheckRun","name":"enable / enable","status":"COMPLETED","conclusion":"FAILURE","checkSuite":{"workflowRun":{"workflow":{"name":"Owner-approved auto-merge"}}}},{"__typename":"CheckRun","name":"Lint shell scripts (ubuntu-latest)","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}}],"pageInfo":{"hasNextPage":false}}}}}]}}}}}
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

grep -q "Review requested on PR #15 (reviewer: nahcnuj): https://github.com/nahcnuj/conahcnuj/pull/15" "${LOG}" || { echo "FAIL: the PR was not handed back to the owner as reviewer"; exit 1; }
# The driver stops at the review request: waiting for the approval is the
# reviewer's part, and the merge job's.
grep -q "Ready to merge" "${LOG}" && { echo "FAIL: the driver waited for an approval that never came"; exit 1; }
grep -q "New review feedback detected" "${LOG}" || { echo "FAIL: the requested changes were not acted on"; exit 1; }
# The driver posts no reply of its own: the agent answers the reviewer in the
# thread (see conahcnuj-resume.sh for the reply-target assertions).
grep -q "Addressed the review feedback" "${LOG}" && { echo "FAIL: the driver still posts its own review-feedback comment"; exit 1; }

# The driver's own run (pending, then cancelled) and the auto-merge job's
# check (pending, then failed) never became a constraint: the poll reported
# SUCCESS instead of waiting for the runs only this driver can finish.
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