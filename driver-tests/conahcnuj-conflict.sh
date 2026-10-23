#!/usr/bin/env bash
# conahcnuj mergeable=CONFLICTING test (offline).
#
# The driver owns the non-reviewer constraints: a PR whose branch conflicts with
# its base branch is not handed to the reviewer until the conflict is resolved.
# Previously a conflict fell through to the same generic "fix whatever breaks
# them" text as a CI failure, so models patched around it (or wrote "resolve
# conflicts" commits) while the branch stayed unmergeable (#355).
#
# This drives bin/conahcnuj.sh <PR> against a mocked tape whose first
# conditions response is CONFLICTING/DIRTY and whose next one is
# MERGEABLE/CLEAN after the implementation round. It asserts that the agent is
# told the branch conflicts with its base branch, that it is told to merge the
# base branch and resolve it, and that the run then hands the PR to the owner
# and reaches the approval.
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
git -C "${WORK}" branch -M main

# A local bare origin with the feature branch and an advanced main. WORK's
# remote-tracking origin/main is deliberately left stale: the base moved on in
# another clone after the branch was cut, exactly the situation that made a
# model merge an old base and leave the real conflict in place. The driver must
# refresh origin/main before it hands the conflict to the agent.
git init -q --bare --initial-branch=main "${ROOT}/origin.git"
git -C "${WORK}" remote add origin "${ROOT}/origin.git"
git -C "${WORK}" push -q -u origin main
git -C "${WORK}" checkout -q -b feature/fix-10
printf 'implementation\n' >> "${WORK}/file.txt"
git -C "${WORK}" add -A
git -C "${WORK}" commit -qm "implementation"
git -C "${WORK}" push -q -u origin feature/fix-10
git clone -q "${ROOT}/origin.git" "${ROOT}/other"
git -C "${ROOT}/other" checkout -q -B main origin/main
git -C "${ROOT}/other" config user.email "test@example.com"
git -C "${ROOT}/other" config user.name "test"
git -C "${ROOT}/other" config commit.gpgsign false
printf 'main advance\n' >> "${ROOT}/other/file.txt"
git -C "${ROOT}/other" add -A
git -C "${ROOT}/other" commit -qm "advance main"
git -C "${ROOT}/other" push -q origin main

# Mocked response tape, in call order:
#   fetch_issue (auto-detect: PR input), fetch_pr_state, fetch_reviews
#   (collection: nothing open), update_pr (body sync), post_comment (the
#   continuation comment), fetch_reviews (REVIEW_REQUIRED, no feedback),
#   conditions (CONFLICTING/DIRTY -> the conflict fix round), fetch_reviews
#   (still REVIEW_REQUIRED), conditions (MERGEABLE/CLEAN -> passes),
#   request_review, fetch_reviews (APPROVED -> the run ends on the approval).
# The tape and log live OUTSIDE the repo (the driver's test-mode commit path
# runs `git add -A`).
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"title":"Fix something","body":"A written description","labels":[],"pull_request":{}}
{"data":{"repository":{"pullRequest":{"number":15,"state":"OPEN","title":"Fix something","body":"A written description","isDraft":false,"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","reviewDecision":"REVIEW_REQUIRED","headRefName":"feature/fix-10","baseRefName":"main","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","closingIssuesReferences":{"nodes":[{"number":10}]}}}}}
{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{}
{"id":889}
{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","state":"OPEN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","state":"OPEN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{}
{"data":{"repository":{"pullRequest":{"reviewDecision":"APPROVED","reviews":{"nodes":[{"state":"APPROVED","body":"LGTM","author":{"login":"nahcnuj"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","state":"OPEN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
EOF

export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export MOCK_OPENCODE_MODELS="opencode/first"
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

grep -q "is a pull request; resuming it in place" "${LOG}" || { echo "FAIL: PR input was not auto-detected"; exit 1; }

# The conflict is recognized as such, not collapsed into a CI failure.
grep -q "has a merge conflict with its base branch" "${LOG}" || { echo "FAIL: the driver did not report the merge conflict"; exit 1; }
grep -q "constraints failing (conflict)" "${LOG}" || { echo "FAIL: the fix round was not told this is a conflict"; exit 1; }

# The stale origin/main ref is refreshed before the agent merges it: merging the
# snapshot from checkout time would leave the newer base commit out and keep the
# branch unmergeable.
grep -q "Fetched the latest base branch 'main'" "${LOG}" || { echo "FAIL: the driver did not refresh the stale base branch"; exit 1; }

# The agent is told to take the base branch and resolve it, naming both.
grep -q "merge conflicts with its base branch 'main'" "${LOG}" || { echo "FAIL: the prompt does not name the conflicting base branch"; exit 1; }
grep -q "git merge origin/main" "${LOG}" || { echo "FAIL: the prompt does not tell the agent to merge the base branch"; exit 1; }
grep -q "remove all conflict markers" "${LOG}" || { echo "FAIL: the prompt does not ask for the conflicts to be resolved"; exit 1; }

# A conflict must get the conflict wording, not the generic CI wording.
grep -q "Fix whatever breaks them" "${LOG}" && { echo "FAIL: the conflict round used the generic CI instruction"; exit 1; }

# The run still drives to the owner's approval after the conflict is fixed.
grep -q "Review requested on PR #15 (reviewer: nahcnuj)" "${LOG}" || { echo "FAIL: the PR was not handed to the owner"; exit 1; }
grep -q "Ready to merge" "${LOG}" || { echo "FAIL: no ready-to-merge line"; exit 1; }

ONELINE="$(git -C "${WORK}" log --oneline)"
grep -q "mock commit from opencode/first" <<<"${ONELINE}" || { echo "FAIL: the conflict-fix commit is missing"; exit 1; }

echo "conahcnuj mergeable=CONFLICTING passed"
