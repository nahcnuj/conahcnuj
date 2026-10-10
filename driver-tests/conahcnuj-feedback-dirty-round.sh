#!/usr/bin/env bash
# conahcnuj "failed feedback round left a dirty tree" test (offline).
#
# A resumed PR has review feedback. The agent's feedback round can fail after
# touching the tree but before writing .commit-msg: a provider outage mid-round
# leaves a partial change behind. There is nothing the driver may commit, and
# refusing to commit a message-less round must not abort the whole run.
#
# This is issue #251: the feedback site called commit_changes unconditionally,
# so a dirty tree without a .commit-msg made commit_changes return 1 and - under
# `set -e` - killed the driver with exit 1 and a "failed to resolve" bug report,
# even though the run had done everything it could.
#
#   PR #15 resumed -> head branch checked out -> collected context -> review
#   feedback detected -> the model's round dies leaving conahcnuj.mock and no
#   .commit-msg -> the feedback is NOT committed (guard) -> owner assigned as
#   reviewer -> constraints pass -> "review requested" -> exit 0, no bug report,
#   the partial file left untouched.
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
printf '# Guide\nFeedback fixture README\n' > "${WORK}/README.md"
git -C "${WORK}" add -A
git -C "${WORK}" commit -qm init

# Mocked response tape, in call order (same shape as the resume fixture):
#   fetch_issue (auto-detect: PR input), fetch_pr_state, fetch_issue (real body),
#   fetch_reviews (collection), update_pr, post_comment, fetch_reviews
#   (CHANGES_REQUESTED with an open thread), request_review, conditions.
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"title":"Fix something","body":"stub","labels":[],"pull_request":{}}
{"data":{"repository":{"pullRequest":{"number":15,"state":"OPEN","title":"Fix something","body":"Closes #10","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"CHANGES_REQUESTED","headRefName":"feature/fix-10","baseRefName":"main","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","closingIssuesReferences":{"nodes":[{"number":10}]}}}}}
{"number": 10, "title": "Fix something", "body": "# 背景\nフィードバック対応の修正。", "labels": [{"name": "enhancement"}], "state": "open"}
{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":101,"body":"Please document the collected context","author":{"login":"reviewer"}}]}}]}}}}}
{}
{"id":889}
{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[{"state":"CHANGES_REQUESTED","body":"Please rename this function","author":{"login":"reviewer"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":12345,"body":"What is Input?","author":{"login":"reviewer"}}]}}]}}}}}
{}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
EOF

export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export MOCK_OPENCODE_MODELS="opencode/first"
# The only model dies mid-round: it leaves conahcnuj.mock and no .commit-msg.
export MOCK_OPENCODE_ERROR="opencode/first"
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
grep -q "New review feedback detected" "${LOG}" || { echo "FAIL: review feedback was not acted on"; exit 1; }
grep -q "No working-tree change was produced for this feedback" "${LOG}" || { echo "FAIL: the failed feedback round was not reported"; exit 1; }
# The crux: a dirty tree with no .commit-msg must not be committed nor crash.
grep -q "left no .commit-msg" "${LOG}" && { echo "FAIL: the driver tried to commit a message-less round"; exit 1; }
grep -q "filing a bug report issue" "${LOG}" && { echo "FAIL: the driver filed a bug report"; exit 1; }
grep -q "Driver exited abnormally" "${LOG}" && { echo "FAIL: the driver exited abnormally"; exit 1; }
# The run still hands the PR back to the owner and finishes cleanly.
grep -q "Assigned nahcnuj as reviewer on PR #15" "${LOG}" || { echo "FAIL: review was not re-requested from the owner"; exit 1; }
grep -q "Review requested on PR #15 (reviewer: nahcnuj)" "${LOG}" || { echo "FAIL: the driver did not hand the PR back to the owner as reviewer"; exit 1; }

# The partial change survives, uncommitted: no branch commit was made for it.
[[ -f "${WORK}/conahcnuj.mock" ]] || { echo "FAIL: the partial change disappeared"; exit 1; }
ONELINE="$(git -C "${WORK}" log --oneline)"
[[ "$(printf '%s\n' "${ONELINE}" | wc -l)" -eq 1 ]] || { echo "FAIL: an unexpected commit was created from the failed round"; exit 1; }
STATUS_OUT="$(git -C "${WORK}" status --porcelain)"
grep -q "conahcnuj.mock" <<<"${STATUS_OUT}" || { echo "FAIL: the partial change is no longer untracked"; exit 1; }

echo "conahcnuj failed-feedback-dirty-round flow passed"
