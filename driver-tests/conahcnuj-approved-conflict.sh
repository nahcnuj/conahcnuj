#!/usr/bin/env bash
# conahcnuj approved-but-conflicting test (offline).
#
# An approval is not the same thing as "ready to merge": the base branch can
# advance after the owner approved, leaving the PR CONFLICTING/DIRTY. The
# driver used to exit "Ready to merge" as soon as it saw reviewDecision
# APPROVED, so an approved-but-conflicting PR was reported as done and never
# became mergeable. It must verify the non-reviewer constraints before declaring
# the PR ready and fix a conflict first.
#
# This drives bin/conahcnuj.sh <PR> against a mocked tape whose PR is already
# APPROVED but CONFLICTING/DIRTY (and whose conditions turn MERGEABLE/CLEAN
# after the fix round). It asserts that the driver does not exit on the
# approval alone, resolves the conflict, and only then reports ready to merge.
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

# A local bare origin with the feature branch and an advanced main, so the
# branch really conflicts and refresh_base_branch has something to fetch.
git init -q --bare --initial-branch=main "${ROOT}/origin.git"
git -C "${WORK}" remote add origin "${ROOT}/origin.git"
git -C "${WORK}" push -q -u origin main
git -C "${WORK}" checkout -q -b feature/fix-11
printf 'implementation\n' >> "${WORK}/file.txt"
git -C "${WORK}" add -A
git -C "${WORK}" commit -qm "implementation"
git -C "${WORK}" push -q -u origin feature/fix-11
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
#   fetch_issue (auto-detect: PR input), fetch_pr_state (CONFLICTING/DIRTY but
#   reviewDecision APPROVED), fetch_reviews (collection: nothing open),
#   update_pr (body sync), post_comment (the continuation comment),
#   fetch_reviews (APPROVED -> must NOT end the run), conditions
#   (CONFLICTING/DIRTY -> the conflict fix round), fetch_reviews (still
#   APPROVED), conditions (MERGEABLE/CLEAN -> passes), then "Ready to merge".
# The tape and log live OUTSIDE the repo (the driver's test-mode commit path
# runs `git add -A`).
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"title":"Fix something","body":"A written description","labels":[],"pull_request":{}}
{"data":{"repository":{"pullRequest":{"number":16,"state":"OPEN","title":"Fix something","body":"A written description","isDraft":false,"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","reviewDecision":"APPROVED","headRefName":"feature/fix-11","baseRefName":"main","headRefOid":"cccccccccccccccccccccccccccccccccccccccc","closingIssuesReferences":{"nodes":[{"number":11}]}}}}}
{"data":{"repository":{"pullRequest":{"reviewDecision":"APPROVED","reviews":{"nodes":[{"state":"APPROVED","body":"LGTM","author":{"login":"nahcnuj"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{}
{"id":890}
{"data":{"repository":{"pullRequest":{"reviewDecision":"APPROVED","reviews":{"nodes":[{"state":"APPROVED","body":"LGTM","author":{"login":"nahcnuj"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","state":"OPEN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
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
  CONAHCNUJ_MAX_SECONDS=120 bash "${DRIVER}" 16 < "${TAPE}"
) > "${LOG}" 2>&1 || RC=$?

echo "----- conahcnuj run log -----"
cat "${LOG}"
echo "-----------------------------"

[[ ${RC} -eq 0 ]] || { echo "FAIL: driver exited ${RC} (expected 0)"; exit 1; }

grep -q "is a pull request; resuming it in place" "${LOG}" || { echo "FAIL: PR input was not auto-detected"; exit 1; }

# The approval alone must not end the run while the branch conflicts.
grep -q "approved but constraints failing (conflict)" "${LOG}" || { echo "FAIL: the driver did not verify constraints after approval"; exit 1; }
grep -q "has a merge conflict with its base branch" "${LOG}" || { echo "FAIL: the driver did not report the merge conflict"; exit 1; }
grep -q "merge conflicts with its base branch 'main'" "${LOG}" || { echo "FAIL: the prompt does not name the conflicting base branch"; exit 1; }
grep -q "git merge origin/main" "${LOG}" || { echo "FAIL: the prompt does not tell the agent to merge the base branch"; exit 1; }

# The conflict is actually fixed (a commit is made), and only then is the run
# reported as ready to merge.
ONELINE="$(git -C "${WORK}" log --oneline)"
grep -q "mock commit from opencode/first" <<<"${ONELINE}" || { echo "FAIL: the conflict-fix commit is missing"; exit 1; }
grep -q "Ready to merge" "${LOG}" || { echo "FAIL: no ready-to-merge line after the conflict was fixed"; exit 1; }

# "Ready to merge" must come after the conflict fix, never before it.
ready_line="$(grep -n "Ready to merge" "${LOG}" | head -1 | cut -d: -f1)"
conflict_line="$(grep -n "approved but constraints failing (conflict)" "${LOG}" | head -1 | cut -d: -f1)"
[[ -n "${ready_line}" && -n "${conflict_line}" && "${ready_line}" -gt "${conflict_line}" ]] \
  || { echo "FAIL: the driver reported ready to merge before fixing the conflict"; exit 1; }

echo "conahcnuj approved-but-conflicting passed"
