#!/usr/bin/env bash
# conahcnuj "mergeable state unknown" test (offline).
#
# Reproduces issue #253: poll_conditions used to treat an empty mergeable
# field as MERGEABLE whenever the checks passed ("Checks pass but mergeable
# state unknown; assuming MERGEABLE."). GitHub returns an empty / UNKNOWN
# mergeable while it computes mergeability and a failed conditions call comes
# back with no payload at all, so the assumption let a PR whose merge state
# was never observed be reported as a passing hand-off.
#
# Drives bin/conahcnuj.sh <PR> against a mocked tape whose first conditions
# response carries an empty mergeable (checks SUCCESS) and whose second one is
# MERGEABLE. The driver must not assume the first is mergeable: it has to poll
# again, so the run only finishes after the second, known-good response.
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
#   fetch_issue (auto-detect: PR input), fetch_pr_state, fetch_reviews
#   (collection: nothing open), update_pr (body sync), post_comment (the
#   continuation comment), fetch_reviews (REVIEW_REQUIRED, no feedback),
#   conditions (empty line -> the read failed, must be retried, never read as
#   "no checks, mergeable"), conditions (checks SUCCESS, mergeable MERGEABLE
#   -> passes), request_review.
# The tape and log live OUTSIDE the repo (the driver's test-mode commit path
# runs `git add -A`).
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"title":"Fix something","body":"A written description","labels":[],"pull_request":{}}
{"data":{"repository":{"pullRequest":{"number":15,"state":"OPEN","title":"Fix something","body":"A written description","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"REVIEW_REQUIRED","headRefName":"feature/fix-10","baseRefName":"main","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","closingIssuesReferences":{"nodes":[{"number":10}]}}}}}
{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{}
{"id":889}
{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}

{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","state":"OPEN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{}
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

# The unsafe assumption is gone.
grep -q "assuming MERGEABLE" "${LOG}" && { echo "FAIL: the driver still assumes MERGEABLE"; exit 1; }

# The failed conditions read must be retried, not read as a passing PR, and the
# run must finish only on a known MERGEABLE state.
RETRY_LINE="$(grep -n 'could not read constraints; retrying' "${LOG}" | head -1 | cut -d: -f1 || true)"
KNOWN_LINE="$(grep -n 'constraints: checks=SUCCESS mergeable=MERGEABLE' "${LOG}" | head -1 | cut -d: -f1 || true)"
PASS_LINE="$(grep -n 'All non-reviewer constraints pass.' "${LOG}" | head -1 | cut -d: -f1 || true)"
[[ -n "${RETRY_LINE}" ]] || { echo "FAIL: the failed conditions read was not retried"; exit 1; }
[[ -n "${KNOWN_LINE}" && "${RETRY_LINE}" -lt "${KNOWN_LINE}" ]] || { echo "FAIL: the driver did not poll again after a failed conditions read"; exit 1; }
[[ -n "${PASS_LINE}" && "${KNOWN_LINE}" -lt "${PASS_LINE}" ]] || { echo "FAIL: the run must finish only on a known MERGEABLE state"; exit 1; }
# A failed read must not have been counted as a constraints failure either.
grep -q "Constraints require changes" "${LOG}" && { echo "FAIL: a failed conditions read was treated as a hard failure"; exit 1; }

grep -q "Review requested on PR #15 (reviewer: nahcnuj)" "${LOG}" || { echo "FAIL: the PR was not handed to the owner"; exit 1; }

echo "conahcnuj mergeable-unknown passed"
