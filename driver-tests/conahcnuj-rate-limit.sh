#!/usr/bin/env bash
# conahcnuj rate-limit handling test (offline).
#
# opencode sits out a provider rate limit ("Rate limit exceeded. Please try
# again later.") with its own retry backoff -- minutes of nothing on stdout.
# The driver must not wait that out: it cuts the round short the moment the
# tell shows up and moves to the next model. A rate limit is NOT an environment
# error (the provider works, its quota is just spent), so the provider's other
# models stay in the pool (#155).
#
# Two scenarios, one mocked API tape each (the shape matches
# conahcnuj-flow.sh / conahcnuj-env-failure.sh):
#
#   1. rlx/a rate-limited, rlx/b finishes -> provider kept, next model adopted
#      immediately, PR created and handed to the owner for review, exit 0
#   2. every model rate-limited -> run fails with a generic bug report, no
#      provider skipped, no environment diagnosis
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

# Mocked response tape for the successful run, in call order:
#   fetch_issue, get_repo, find_pr_by_head_any (empty), find_pr_by_head (empty),
#   repo id, create_pr (126), continuation comment, fetch_reviews
#   (REVIEW_REQUIRED, nothing to act on), request_review, conditions
#   (SUCCESS|MERGEABLE). The tape and the run log stay OUTSIDE the repo: the
#   driver's test-mode commit path does `git add -A`.
TAPE_OK="${ROOT}/tape-ok.txt"
cat > "${TAPE_OK}" <<'EOF'
{"number": 15, "title": "rate limited model gives way to the next one", "body": "Cut the wait out", "labels": [], "state": "open"}
{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"id":"R_kgDOXmplR3p"}}}
{"data":{"createPullRequest":{"pullRequest":{"number":126}}}}
{"id":776}
{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
EOF

# Mocked response tape for a run that ends in a bug report:
# fetch_issue, get_repo, find_pr_by_head_any (empty), create_issue.
TAPE_BUG="${ROOT}/tape-bug.txt"
cat > "${TAPE_BUG}" <<'EOF'
{"number": 15, "title": "rate limited model gives way to the next one", "body": "Cut the wait out", "labels": [], "state": "open"}
{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"number": 25}
EOF

export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export CONAHCNUJ_REPO="nahcnuj/conahcnuj"

LOG1="${ROOT}/run1.log"
RC1=0
(
  cd "${WORK}"
  CONAHCNUJ_MAX_SECONDS=120 \
    MOCK_OPENCODE_MODELS="$(printf '%s\n' rlx/a rlx/b)" \
    MOCK_OPENCODE_RATE_LIMIT="rlx/a" \
    bash "${DRIVER}" 15 < "${TAPE_OK}"
) > "${LOG1}" 2>&1 || RC1=$?

echo "----- scenario 1: a rate-limited model gives way to the next one -----"
cat "${LOG1}"
echo "---------------------------------------------------------------------"

[[ ${RC1} -eq 0 ]] || { echo "FAIL: scenario 1 exited ${RC1} (expected 0)"; exit 1; }

grep -q "Model rlx/a hit a rate limit; trying the next model without waiting for the retry" "${LOG1}" || { echo "FAIL: the rate-limited round was not reported in the run log"; exit 1; }
grep -q "environment error" "${LOG1}" && { echo "FAIL: a rate limit was diagnosed as an environment error"; exit 1; }
grep -q "Skipping" "${LOG1}" && { echo "FAIL: the provider was skipped on a rate limit"; exit 1; }
grep -q "Handing off session ses_mock from rlx/a to rlx/b" "${LOG1}" || { echo "FAIL: the session was not handed to the next model"; exit 1; }
grep -q "Model rlx/b completed the work" "${LOG1}" || { echo "FAIL: the second model was not adopted"; exit 1; }
grep -q "Created PR #126" "${LOG1}" || { echo "FAIL: PR #126 was not created"; exit 1; }
grep -q "Review requested on PR #126 (reviewer: nahcnuj)" "${LOG1}" || { echo "FAIL: the PR was not handed to the owner as reviewer"; exit 1; }
grep -q "filing a bug report issue" "${LOG1}" && { echo "FAIL: a rate limit must not file a bug report when a later model finishes"; exit 1; }

# No bug report in scenario 1, so only init + implement commits.
ONELINE="$(git -C "${WORK}" log --oneline)"
grep -q "mock commit from rlx/b" <<<"${ONELINE}" || { echo "FAIL: the second model's .commit-msg was not used"; exit 1; }
[[ "$(printf '%s\n' "${ONELINE}" | wc -l)" == "2" ]] || { echo "FAIL: expected init + implement commits"; exit 1; }

LOG2="${ROOT}/run2.log"
RC2=0
(
  cd "${WORK}"
  CONAHCNUJ_MAX_SECONDS=120 \
    MOCK_OPENCODE_MODELS="$(printf '%s\n' rlx/a rlx/b)" \
    MOCK_OPENCODE_RATE_LIMIT="rlx/a rlx/b" \
    bash "${DRIVER}" 15 < "${TAPE_BUG}"
) > "${LOG2}" 2>&1 || RC2=$?

echo "----- scenario 2: every model is rate-limited -----"
cat "${LOG2}"
echo "--------------------------------------------------"

[[ ${RC2} -eq 1 ]] || { echo "FAIL: scenario 2 exited ${RC2} (expected 1)"; exit 1; }

grep -q "Model rlx/a hit a rate limit; trying the next model without waiting for the retry" "${LOG2}" || { echo "FAIL: rlx/a was not reported as rate-limited"; exit 1; }
grep -q "Model rlx/b hit a rate limit; trying the next model without waiting for the retry" "${LOG2}" || { echo "FAIL: rlx/b was not reported as rate-limited"; exit 1; }
grep -q "Skipping" "${LOG2}" && { echo "FAIL: a provider was skipped on rate limits"; exit 1; }
grep -q "every model round died on an environment error" "${LOG2}" && { echo "FAIL: environment diagnosis printed although the rounds were rate-limited"; exit 1; }
grep -q "Bug report issue #25 created" "${LOG2}" || { echo "FAIL: no generic bug report was filed"; exit 1; }

echo "conahcnuj rate-limit handling passed"
