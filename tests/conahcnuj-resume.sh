#!/usr/bin/env bash
# conahcnuj resume-from-PR flow test (offline).
#
# Drives bin/conahcnuj.sh --pr N against a mocked GitHub API tape and a mocked
# opencode inside a throwaway git repository. Exercises the resume path:
#
#   PR #15 state read -> head branch checked out -> constraints pass ->
#   review requested -> CHANGES_REQUESTED feedback detected -> addressed and
#   committed -> constraints re-verified -> replied -> polled again ->
#   APPROVED + constraints -> "ready to merge" -> exit 0
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
#   fetch_pr_state, conditions, request_review, fetch_reviews
#   (CHANGES_REQUESTED), conditions, request_review, post_comment,
#   fetch_reviews (fingerprint refresh after the reply), conditions,
#   fetch_reviews (APPROVED), conditions.
# The tape and log live OUTSIDE the repo (the driver's test-mode commit
# path runs `git add -A`).
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"data":{"repository":{"pullRequest":{"number":15,"state":"OPEN","title":"Fix something","body":"Closes #10","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"CHANGES_REQUESTED","headRefName":"feature/fix-10","baseRefName":"main","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","closingIssuesReferences":{"nodes":[{"number":10}]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{}
{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[{"state":"CHANGES_REQUESTED","body":"Please rename this function","author":{"login":"reviewer"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{}
{"id":888}
{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[{"state":"CHANGES_REQUESTED","body":"Please rename this function","author":{"login":"reviewer"}}]},"comments":{"nodes":[{"body":"Addressed the review feedback:\n\nreviewDecision: CHANGES_REQUESTED","author":{"login":"conahcnuj[bot]"}}]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{"data":{"repository":{"pullRequest":{"reviewDecision":"APPROVED","reviews":{"nodes":[{"state":"APPROVED","body":"LGTM","author":{"login":"reviewer"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
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
  CONAHCNUJ_MAX_SECONDS=120 bash "${DRIVER}" 15 --pr < "${TAPE}"
) > "${LOG}" 2>&1 || RC=$?

echo "----- conahcnuj run log -----"
cat "${LOG}"
echo "-----------------------------"

[[ ${RC} -eq 0 ]] || { echo "FAIL: driver exited ${RC} (expected 0)"; exit 1; }

grep -q "PR #15" "${LOG}" || { echo "FAIL: PR #15 was not processed"; exit 1; }
grep -q "Ready to merge" "${LOG}" || { echo "FAIL: no ready-to-merge line"; exit 1; }
grep -q "New review feedback detected" "${LOG}" || { echo "FAIL: review feedback was not acted on"; exit 1; }
grep -q "Replied on PR #15 after addressing review feedback" "${LOG}" || { echo "FAIL: feedback reply was not posted"; exit 1; }

[[ "$(git -C "${WORK}" branch --show-current)" == "feature/fix-10" ]] || { echo "FAIL: wrong current branch"; exit 1; }
git -C "${WORK}" log --oneline | grep -q "address review feedback" || { echo "FAIL: feedback commit missing"; exit 1; }

echo "conahcnuj resume flow passed"