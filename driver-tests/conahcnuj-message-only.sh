#!/usr/bin/env bash
# conahcnuj "message-only round" test (offline).
#
# A model can finish its turn having written nothing but a commit message. The
# driver has nothing to commit then, so that round counts as no work, is said so
# in the run log, and the session goes to the next model, whose change is what
# reaches the branch.
#
#   issue read -> branch -> implement (talker: message only, no change) ->
#   hand off -> implement (second: real change) -> PR #126 created ->
#   non-reviewer constraints pass -> owner assigned as reviewer -> exit 0
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
#   repo id, create_pr (126), continuation comment, fetch_reviews
#   (REVIEW_REQUIRED, nothing to act on), conditions (SUCCESS|MERGEABLE),
#   request_review. Reviews are read before the constraints poll (#219).
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"number": 21, "title": "agent answers with a message only", "body": "The change itself is the deliverable", "labels": [], "state": "open"}
{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"id":"R_kgDOXmplR3p"}}}
{"data":{"createPullRequest":{"pullRequest":{"number":126}}}}
{"id":776}
{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{}
EOF

export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export MOCK_OPENCODE_MODELS="opencode/talker
opencode/second"
# The talker writes .commit-msg and touches nothing else.
export MOCK_OPENCODE_MESSAGE_ONLY="opencode/talker"
export CONAHCNUJ_REPO="nahcnuj/conahcnuj"

LOG="${ROOT}/run.log"
RC=0
(
  cd "${WORK}"
  CONAHCNUJ_MAX_SECONDS=120 bash "${DRIVER}" 21 < "${TAPE}"
) > "${LOG}" 2>&1 || RC=$?

echo "----- conahcnuj run log -----"
cat "${LOG}"
echo "-----------------------------"

[[ ${RC} -eq 0 ]] || { echo "FAIL: driver exited ${RC} (expected 0)"; exit 1; }

grep -q "Model opencode/talker left the working tree unchanged and only wrote .commit-msg" "${LOG}" || { echo "FAIL: the message-only round was not reported in the run log"; exit 1; }
grep -q "produced no complete work" "${LOG}" && { echo "FAIL: the message-only round was reported as an ordinary empty round"; exit 1; }
grep -q "Handing off session ses_mock from opencode/talker to opencode/second" "${LOG}" || { echo "FAIL: the session was not handed to the next model"; exit 1; }
grep -q "Model opencode/second completed the work" "${LOG}" || { echo "FAIL: the second model was not adopted"; exit 1; }
grep -q "Created PR #126" "${LOG}" || { echo "FAIL: PR #126 was not created"; exit 1; }
grep -q "Review requested on PR #126 (reviewer: nahcnuj)" "${LOG}" || { echo "FAIL: the PR was not handed to the owner as reviewer"; exit 1; }
grep -q "filing a bug report issue" "${LOG}" && { echo "FAIL: a message-only round must not file a bug report when a later model finishes"; exit 1; }

# Only the model that actually changed the tree gets to name the commit.
ONELINE="$(git -C "${WORK}" log --oneline)"
grep -q "mock commit from opencode/second" <<<"${ONELINE}" || { echo "FAIL: the second model's .commit-msg was not used"; exit 1; }
grep -q "mock commit from opencode/talker" <<<"${ONELINE}" && { echo "FAIL: a message-only round was committed"; exit 1; }
# init + implement = 2 commits from the branch tip.
[[ "$(printf '%s\n' "${ONELINE}" | wc -l)" == "2" ]] || { echo "FAIL: expected init + implement commits"; exit 1; }
# The talker's message is what the driver consumes, never committed content.
[[ ! -e "${WORK}/.commit-msg" ]] || { echo "FAIL: the talker's message survived into the commit"; exit 1; }

echo "conahcnuj message-only round passed"
