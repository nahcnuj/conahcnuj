#!/usr/bin/env bash
# conahcnuj resume-from-PR flow test (offline).
#
# Drives bin/conahcnuj.sh N (N auto-detected as a pull request) against a
# mocked GitHub API tape and a mocked opencode inside a throwaway git
# repository. Exercises the resume path:
#
#   PR #15 state read -> head branch checked out -> collected context
#   (open review threads + README/AGENTS of the checkout) -> constraints pass
#   -> CHANGES_REQUESTED feedback detected -> the agent addresses it (and
#   answers the thread itself) and commits -> owner assigned as reviewer again
#   -> constraints re-verified -> "review requested" -> exit 0
#
# A resumed run handles one feedback round and hands the PR back to the
# reviewer; the approval itself is the human's part. The collected context
# is what the first prompt carries so the model does not have to look the
# open threads (or the repository's own docs) up itself.
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
# Orientation files: collected into the prompt of every fresh round.
printf '# Guide\nResume fixture README\n' > "${WORK}/README.md"
printf 'Resume fixture rule\n' > "${WORK}/AGENTS.md"
git -C "${WORK}" add -A
git -C "${WORK}" commit -qm init

# Mocked response tape, in call order:
#   fetch_issue (auto-detect: PR input), fetch_pr_state, fetch_issue (stub
#   body -> real issue body), fetch_reviews (collection: one open thread, one
#   resolved), update_pr (body sync on the reuse path), post_comment (the PR
#   continuation comment), conditions, fetch_reviews (CHANGES_REQUESTED with an
#   open thread), request_review, conditions. The feedback round posts no comment
#   of its own: the agent answers the reviewer in the thread.
# The tape and log live OUTSIDE the repo (the driver's test-mode commit
# path runs `git add -A`).
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"title":"Fix something","body":"stub","labels":[],"pull_request":{}}
{"data":{"repository":{"pullRequest":{"number":15,"state":"OPEN","title":"Fix something","body":"Closes #10","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"CHANGES_REQUESTED","headRefName":"feature/fix-10","baseRefName":"main","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","closingIssuesReferences":{"nodes":[{"number":10}]}}}}}
{"number": 10, "title": "Fix something", "body": "# 背景\nPR を引き継いで再開できるようにする。", "labels": [{"name": "enhancement"}], "state": "open"}
{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":101,"body":"Please document the collected context","author":{"login":"reviewer"}}]}},{"isResolved":true,"comments":{"nodes":[{"databaseId":102,"body":"Already settled thread","author":{"login":"reviewer"}}]}}]}}}}}
{}
{"id":889}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[{"state":"CHANGES_REQUESTED","body":"Please rename this function","author":{"login":"reviewer"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":12345,"body":"What is Input?","author":{"login":"reviewer"}}]}}]}}}}}
{}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
EOF

export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export MOCK_OPENCODE_MODELS="opencode/first"
export CONAHCNUJ_REPO="nahcnuj/conahcnuj"

# A wrapping agent session (the conahcnuj opencode plugin) exports these for
# the real driver runs; the mock trailer check below must not see them.
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

grep -q "PR #15" "${LOG}" || { echo "FAIL: PR #15 was not processed"; exit 1; }
grep -q "is a pull request; resuming it in place" "${LOG}" || { echo "FAIL: PR input was not auto-detected"; exit 1; }
grep -q "Review requested on PR #15 (reviewer: nahcnuj): https://github.com/nahcnuj/conahcnuj/pull/15" "${LOG}" || { echo "FAIL: the driver did not hand the PR back to the owner as reviewer"; exit 1; }
grep -q "Assigned nahcnuj as reviewer on PR #15" "${LOG}" || { echo "FAIL: review was not re-requested from the owner after the fix"; exit 1; }
grep -q "Ready to merge" "${LOG}" && { echo "FAIL: the driver waited for an approval that never came"; exit 1; }
grep -q "New review feedback detected" "${LOG}" || { echo "FAIL: review feedback was not acted on"; exit 1; }
# The driver no longer posts a reply of its own: the agent answers the reviewer
# in the thread, so the prompt must name the thread's comment id and the reply
# endpoint for the agent to use.
grep -q "Addressed the review feedback" "${LOG}" && { echo "FAIL: the driver still posts its own review-feedback comment"; exit 1; }
grep -q "comment 12345 by reviewer" "${LOG}" || { echo "FAIL: the feedback prompt does not name the thread comment to answer"; exit 1; }
grep -q "POST https://api.github.com/repos/nahcnuj/conahcnuj/pulls/15/comments/<comment_id>/replies" "${LOG}" || { echo "FAIL: the feedback prompt does not tell the agent the reply endpoint"; exit 1; }

# The prompt carries the collected context: the PR's open thread and the
# checkout's orientation files, but never the resolved thread.
grep -q "Collected context:" "${LOG}" || { echo "FAIL: the prompt has no collected context block"; exit 1; }
grep -q "Please document the collected context" "${LOG}" || { echo "FAIL: the open review thread was not collected"; exit 1; }
grep -q "Already settled thread" "${LOG}" && { echo "FAIL: a resolved review thread was collected"; exit 1; }
grep -q "Resume fixture README" "${LOG}" || { echo "FAIL: README.md was not collected"; exit 1; }
grep -q "Resume fixture rule" "${LOG}" || { echo "FAIL: AGENTS.md was not collected"; exit 1; }
grep -q "Collected context up front: unresolved review threads of PR #15, README.md, AGENTS.md" "${LOG}" || { echo "FAIL: the run log does not say what was collected"; exit 1; }

[[ "$(git -C "${WORK}" branch --show-current)" == "feature/fix-10" ]] || { echo "FAIL: wrong current branch"; exit 1; }
# Capture first, then grep via here-string: `git log | grep -q` under
# `set -o pipefail` is flaky (grep -q exits on the first match, git gets
# SIGPIPE, and pipefail reports a false failure).
ONELINE="$(git -C "${WORK}" log --oneline)"
grep -q "mock commit from opencode/first" <<<"${ONELINE}" || { echo "FAIL: the agent's .commit-msg was not used for the commit"; exit 1; }
FULL_LOG="$(git -C "${WORK}" log --format=%B)"
grep -q "Co-Authored-By: opencode (first)" <<<"${FULL_LOG}" || { echo "FAIL: model trailer missing"; exit 1; }
# The fixed driver-side message must not reappear.
grep -q "conahcnuj:.*address review feedback" <<<"${ONELINE}" && { echo "FAIL: driver still used a fixed commit message"; exit 1; }

echo "conahcnuj resume flow passed"