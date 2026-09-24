#!/usr/bin/env bash
# conahcnuj UNKNOWN-mergeability flow test (offline).
#
# Regression test for issue #56: GitHub background-computes PR mergeability,
# so right after PR creation mergeable is "UNKNOWN" (mergeStateStatus UNKNOWN
# or BLOCKED) even when all status checks already pass. The driver must treat
# "checks green + no reported conflict" as satisfying the non-reviewer
# constraints instead of polling until the whole run budget burns out and
# crashing with "time budget exhausted while waiting".
#
#   issue #10 read -> implement -> PR #124 created -> constraints
#   (checks=SUCCESS, mergeable=UNKNOWN) pass -> review requested ->
#   APPROVED -> constraints pass again -> "ready to merge" -> exit 0
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
#   repo id, create_pr (124), conditions (checks SUCCESS but mergeable
#   UNKNOWN / mergeState UNKNOWN - the #56 state), request_review,
#   fetch_reviews (APPROVED), conditions (SUCCESS, BLOCKED).
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"number": 10, "title": "issue駆動自律開発", "body": "# 背景\n動作確認用のダミー issue です。", "labels": [{"name": "enhancement"}], "state": "open"}
{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"id":"R_kgDOXmplR3p"}}}
{"data":{"createPullRequest":{"pullRequest":{"number":124}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{}
{"data":{"repository":{"pullRequest":{"reviewDecision":"APPROVED","reviews":{"nodes":[{"state":"APPROVED","body":"LGTM","author":{"login":"reviewer"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"UNKNOWN","mergeStateStatus":"BLOCKED","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
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
  CONAHCNUJ_MAX_SECONDS=60 bash "${DRIVER}" 10 < "${TAPE}"
) > "${LOG}" 2>&1 || RC=$?

echo "----- conahcnuj unknown-mergeable run log -----"
cat "${LOG}"
echo "-----------------------------------------------"

[[ ${RC} -eq 0 ]] || { echo "FAIL: driver exited ${RC} (expected 0)"; exit 1; }

grep -q "Ready to merge" "${LOG}" || { echo "FAIL: no ready-to-merge line"; exit 1; }
grep -q "Created PR #124" "${LOG}" || { echo "FAIL: PR #124 was not created"; exit 1; }
# The #56 regression: checks pass but mergeable is UNKNOWN, so the driver must
# proceed (not spin) and never hit the run budget.
grep -q "assuming MERGEABLE" "${LOG}" || { echo "FAIL: UNKNOWN mergeability was not handled as passable"; exit 1; }
grep -q "time budget" "${LOG}" && { echo "FAIL: the driver burned the run budget awaiting mergeability"; exit 1; }

echo "conahcnuj unknown-mergeable flow passed"