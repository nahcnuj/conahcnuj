#!/usr/bin/env bash
# conahcnuj "unlabelled change" flow test (offline).
#
# The normal round today: the prompt asks the coding agent for the change and
# nothing else, so it leaves no .commit-msg behind. The change is the work, so
# the driver must commit it (labelling the commit itself) and take the PR to the
# review request instead of discarding the implementation - and instead of
# filing a bug report for the missing label, which is what the driver used to do
# when the label went missing (issue #146).
#
#   issue #22 read -> branch -> implement (change, no message) -> committed with
#   the driver's own label -> PR #127 created -> constraints pass -> owner
#   assigned as reviewer -> exit 0
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
#   fetch_issue, get_repo, find_pr_by_head_any (empty), find_pr_by_head (empty),
#   repo id, create_pr (127), continuation comment, conditions (SUCCESS|MERGEABLE),
#   fetch_reviews (REVIEW_REQUIRED, nothing to act on), request_review.
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"number": 22, "title": "the change is the whole deliverable", "body": "# 背景\nエージェントには変更だけを求めます。", "labels": [], "state": "open"}
{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"id":"R_kgDOXmplR3p"}}}
{"data":{"createPullRequest":{"pullRequest":{"number":127}}}}
{"id":778}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{}
EOF

export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export MOCK_OPENCODE_MODELS="opencode/quiet"
# The round changes the tree and writes no .commit-msg, because nothing asked it to.
export MOCK_OPENCODE_NO_MESSAGE="opencode/quiet"
export CONAHCNUJ_REPO="nahcnuj/conahcnuj"

LOG="${ROOT}/run.log"
RC=0
(
  cd "${WORK}"
  CONAHCNUJ_MAX_SECONDS=120 bash "${DRIVER}" 22 < "${TAPE}"
) > "${LOG}" 2>&1 || RC=$?

echo "----- conahcnuj run log -----"
cat "${LOG}"
echo "-----------------------------"

[[ ${RC} -eq 0 ]] || { echo "FAIL: driver exited ${RC} (expected 0)"; exit 1; }

grep -q "Model opencode/quiet completed the work." "${LOG}" || { echo "FAIL: the change without a message was not accepted as the work"; exit 1; }
grep -q "No commit message from the coding agent; labelling the commit: the change is the whole deliverable" "${LOG}" || { echo "FAIL: the driver did not label the commit itself"; exit 1; }
grep -q "Created PR #127" "${LOG}" || { echo "FAIL: PR #127 was not created"; exit 1; }
grep -q "Review requested on PR #127 (reviewer: nahcnuj)" "${LOG}" || { echo "FAIL: the PR was not handed to the owner as reviewer"; exit 1; }
grep -q "filing a bug report issue" "${LOG}" && { echo "FAIL: the missing commit message filed a bug report"; exit 1; }

ONELINE="$(git -C "${WORK}" log --oneline)"
grep -q "the change is the whole deliverable" <<<"${ONELINE}" || { echo "FAIL: the implementation was not committed"; exit 1; }
[[ "$(printf '%s\n' "${ONELINE}" | wc -l)" == "2" ]] || { echo "FAIL: expected init + implement commits"; exit 1; }
# The change itself is in the commit; no driver metadata is.
CONTENTS="$(git -C "${WORK}" show --stat --format=%s HEAD)"
grep -q "conahcnuj.mock" <<<"${CONTENTS}" || { echo "FAIL: the agent's change is missing from the commit"; exit 1; }
grep -q "commit-msg" <<<"${CONTENTS}" && { echo "FAIL: driver metadata was committed"; exit 1; }

echo "conahcnuj unlabelled change passed"
