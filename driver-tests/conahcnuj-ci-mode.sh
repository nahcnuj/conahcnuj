#!/usr/bin/env bash
# conahcnuj CI-mode flow test (offline).
#
# In GitHub Actions, waiting for a human reviewer's approval is not realistic:
# the run must end as soon as the PR has been handed to the owner (the reviewer
# assignment / review request), and the pull_request_review trigger starts the
# next run for any feedback. This drives the real bin/conahcnuj.sh state machine
# with GITHUB_ACTIONS=true against a mocked API tape that never answers with an
# approval: a driver that still polls for the verdict would hang or exhaust its
# budget, so the test proves the run ends at the review request.
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
printf '# Guide\nCI fixture README\n' > "${WORK}/README.md"
git -C "${WORK}" add -A
git -C "${WORK}" commit -qm init

# The tape has no APPROVED review: the run must not need one. It ends at the
# request_review call (the `{}` after the successful conditions poll).
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"number": 10, "title": "CI mode", "body": "End at the review request.", "labels": [], "state": "open"}
{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"id":"R_kgDOXmplR3p"}}}
{"data":{"createPullRequest":{"pullRequest":{"number":123}}}}
{}
{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"PENDING"}}}]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
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
# GITHUB_ACTIONS=true is what the runner provides: the driver must end at the
# review request. A short budget keeps a regression from hanging for long.
(
  cd "${WORK}"
  GITHUB_ACTIONS=true CONAHCNUJ_MAX_SECONDS=10 bash "${DRIVER}" 10 < "${TAPE}"
) > "${LOG}" 2>&1 || RC=$?

echo "----- conahcnuj CI-mode run log -----"
cat "${LOG}"
echo "-------------------------------------"

[[ ${RC} -eq 0 ]] || { echo "FAIL: driver exited ${RC} (expected 0)"; exit 1; }

grep -q "Assigned nahcnuj as reviewer on PR #123" "${LOG}" || { echo "FAIL: the owner was not assigned as reviewer"; exit 1; }
grep -q "Review requested on PR #123 (reviewer: nahcnuj): https://github.com/nahcnuj/conahcnuj/pull/123" "${LOG}" || { echo "FAIL: the PR was not handed to the owner"; exit 1; }
# The review request is the end of a CI run: no polling for an approval, and
# no claim that a human approved.
grep -q "waiting for the reviewer's decision" "${LOG}" && { echo "FAIL: the CI run kept waiting for the reviewer"; exit 1; }
grep -q "Ready to merge" "${LOG}" && { echo "FAIL: the CI run waited for an approval it never got"; exit 1; }
! grep -q "time budget is exhausted" "${LOG}" || { echo "FAIL: the CI run burned its budget waiting"; exit 1; }

echo "conahcnuj CI-mode review-request completion passed"
