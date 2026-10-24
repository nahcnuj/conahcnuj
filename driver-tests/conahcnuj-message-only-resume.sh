#!/usr/bin/env bash
# conahcnuj "message-only round on an implemented branch" test (offline).
#
# A model can finish its turn having written nothing but a .commit-msg because
# there is nothing left to change: the branch already carries the implementation
# (a resumed PR, or a later round on an implemented branch). The message is then
# the whole deliverable, so the driver accepts the round and moves on instead of
# handing the finished work to the next model. Issue #273 is exactly this: a
# resumed PR whose model wrote only a .commit-msg was skipped as "no work", the
# session went to the next model, and a weaker one committed junk onto the
# branch (env.tmp / token.tmp).
#
#   PR #15 state read -> implemented head branch checked out -> collected
#   context -> constraints pending -> CHANGES_REQUESTED feedback detected ->
#   the agent answers with only a .commit-msg (nothing to change) -> accepted
#   as complete -> owner assigned as reviewer again -> owner approves -> exit 0
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
# The PR's baseRefName is "main"; name the default branch to match.
git -C "${WORK}" branch -M main
# The head branch already carries the implementation committed by an earlier
# run: the resumed run has nothing left to change.
git -C "${WORK}" checkout -q -b feature/fix-10
printf 'mock change from opencode/original\n' > "${WORK}/conahcnuj.mock"
git -C "${WORK}" add -A
git -C "${WORK}" commit -qm "mock commit from opencode/original"

# Mocked response tape, in call order:
#   fetch_issue (auto-detect: PR input), fetch_pr_state, fetch_issue (stub
#   body -> real issue body), fetch_reviews (collection: one open thread),
#   update_pr (body sync on the reuse path), post_comment (the PR continuation
#   comment), fetch_reviews (CHANGES_REQUESTED with an open thread),
#   conditions (the first read is incomplete, so it is polled again), the
#   second conditions read, request_review, then an APPROVED fetch_reviews that
#   ends the run. The approval is explicit: the test must end on a real
#   outcome, not on the time budget timing out (a timeout is not a success).
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"title":"Fix something","body":"stub","labels":[],"pull_request":{}}
{"data":{"repository":{"pullRequest":{"number":15,"state":"OPEN","title":"Fix something","body":"Closes #10","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"CHANGES_REQUESTED","headRefName":"feature/fix-10","baseRefName":"main","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","closingIssuesReferences":{"nodes":[{"number":10}]}}}}}
{"number": 10, "title": "Fix something", "body": "# 背景\nPR を引き継いで再開できるようにする。", "labels": [{"name": "enhancement"}], "state": "open"}
{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":101,"body":"Please document the collected context","author":{"login":"reviewer"}}]}}]}}}}}
{}
{"id":889}
{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[{"state":"CHANGES_REQUESTED","body":"Please rename this function","author":{"login":"reviewer"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":12345,"body":"What is Input?","author":{"login":"reviewer"}}]}}]}}}}}
{}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{}
{"data":{"repository":{"pullRequest":{"reviewDecision":"APPROVED","reviews":{"nodes":[{"state":"APPROVED","body":"LGTM","author":{"login":"nahcnuj"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
EOF

export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export MOCK_OPENCODE_MODELS="opencode/talker"
# The talker answers with only a .commit-msg; the branch is already implemented.
export MOCK_OPENCODE_MESSAGE_ONLY="opencode/talker"
export CONAHCNUJ_REPO="nahcnuj/conahcnuj"

unset CONAHCNUJ_COMMIT_MODEL CONAHCNUJ_MODEL_LABEL_FILE CONAHCNUJ_SESSION_MODEL \
  CONAHCNUJ_RUN_TIMEOUT_SECONDS OPENCODE_LAST_MODEL

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

grep -q "New review feedback detected" "${LOG}" || { echo "FAIL: review feedback was not acted on"; exit 1; }
# The message-only round is accepted as complete because the branch already
# carries the implementation.
grep -q "wrote .commit-msg and left the tree as it was; the branch already carries the implementation, so the round is complete" "${LOG}" || { echo "FAIL: the message-only round on an implemented branch was not accepted"; exit 1; }
# It must not be reported as no work, and the session must not go to another model.
grep -q "left the working tree unchanged and only wrote .commit-msg" "${LOG}" && { echo "FAIL: an implemented-branch message-only round was still skipped as no work"; exit 1; }
grep -q "Handing off session" "${LOG}" && { echo "FAIL: the session was handed to another model although the branch was already implemented"; exit 1; }
grep -q "produced no complete work" "${LOG}" && { echo "FAIL: the round was reported as an ordinary empty round"; exit 1; }

# The PR is still handed back to the reviewer, and the run ends on the
# owner's approval (not on the time budget expiring).
grep -q "Review requested on PR #15 (reviewer: nahcnuj): https://github.com/nahcnuj/conahcnuj/pull/15" "${LOG}" || { echo "FAIL: the PR was not handed back to the owner as reviewer"; exit 1; }
grep -q "Ready to merge: https://github.com/nahcnuj/conahcnuj/pull/15" "${LOG}" || { echo "FAIL: the run did not end on the owner's approval"; exit 1; }
grep -q "filing a bug report issue" "${LOG}" && { echo "FAIL: an accepted message-only round must not file a bug report"; exit 1; }

# The implemented branch is left as it was: init + implementation, no new
# commit from the talker, and the message is metadata that is cleaned up.
[[ "$(git -C "${WORK}" branch --show-current)" == "feature/fix-10" ]] || { echo "FAIL: wrong current branch"; exit 1; }
ONELINE="$(git -C "${WORK}" log --oneline)"
grep -q "mock commit from opencode/original" <<<"${ONELINE}" || { echo "FAIL: the implementation commit was lost"; exit 1; }
grep -q "mock commit from opencode/talker" <<<"${ONELINE}" && { echo "FAIL: a message-only round was committed"; exit 1; }
# init + implementation = 2 commits from the branch tip.
[[ "$(printf '%s\n' "${ONELINE}" | wc -l)" == "2" ]] || { echo "FAIL: expected init + implementation commits"; exit 1; }
[[ ! -e "${WORK}/.commit-msg" ]] || { echo "FAIL: the message-only .commit-msg was left behind"; exit 1; }

echo "conahcnuj message-only resume round passed"
