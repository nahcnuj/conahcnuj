#!/usr/bin/env bash
# conahcnuj "commit creation failed" test (offline).
#
# GitHub can reject a Verified commit that the agent asked for: issue #700 was
# filed after `createCommitOnBranch` answered FORBIDDEN "Resource not accessible
# by integration" for nahcnuj/nahcnuj.github.io#841. The agent had done the work
# and left a real change plus a .commit-msg, but commit_changes called
# api-commit.sh unguarded, its exit 1 propagated through `set -e`, and the whole
# driver died with exit 1 and a "failed to resolve" bug report.
#
# A rejected commit is not a reason to crash: consume the message, keep the
# change in the working tree, and let the round carry on so the run can hand the
# PR back (or back off) instead of aborting. This test covers both the real
# api-commit.sh path and the caller guards.
#
#   Part 1: commit_changes with a failing Verified-commit API returns 1, keeps
#           the change, drops .commit-msg, and does not sync/reset the branch.
#   Part 2: a resumed PR whose feedback round leaves a change + .commit-msg and
#           whose local commit is rejected keeps running to the owner hand-off
#           with exit 0 and no bug report.
#
# No secrets, no network.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
DRIVER="${REPO}/bin/conahcnuj.sh"

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT

# --- Part 1: the real Verified-commit path -------------------------------
UNIT="${ROOT}/unit"
mkdir -p "${UNIT}/bin" "${UNIT}/gh-app"
git -C "${UNIT}" init -q
git -C "${UNIT}" config user.email "test@example.com"
git -C "${UNIT}" config user.name "test"
git -C "${UNIT}" config commit.gpgsign false
printf 'base\n' > "${UNIT}/f.txt"
git -C "${UNIT}" add -A
git -C "${UNIT}" commit -qm init
printf 'change\n' >> "${UNIT}/f.txt"
printf 'fix: keep the driver alive\n' > "${UNIT}/.commit-msg"

# Reproduce #700: the GraphQL mutation is rejected for lack of permission.
cat > "${UNIT}/gh-app/api-commit.sh" <<'STUB'
#!/usr/bin/env bash
echo 'ERROR: commit creation failed: {"data":{"createCommitOnBranch":null},"errors":[{"type":"FORBIDDEN","message":"Resource not accessible by integration"}]}' >&2
exit 1
STUB

UNIT_RC=0
(
  cd "${UNIT}"
  unset CONAHCNUJ_COMMIT_MODEL CONAHCNUJ_MODEL_LABEL_FILE OPENCODE_LAST_MODEL \
    CONAHCNUJ_SESSION_MODEL
  export CONAHCNUJ_IMPORT=1
  # shellcheck source=bin/conahcnuj.sh
  source "${DRIVER}"
  # commit_changes calls ${HERE}/../gh-app/api-commit.sh; point HERE at the stub.
  HERE="${UNIT}/bin"
  TEST_MODE=0
  if commit_changes 2> "${ROOT}/unit.log"; then
    exit 0
  else
    exit 1
  fi
) || UNIT_RC=$?

cat "${ROOT}/unit.log" >&2
[[ ${UNIT_RC} -eq 1 ]] || { echo "FAIL: commit_changes did not return 1 on a rejected commit (rc=${UNIT_RC})"; exit 1; }
grep -q 'Resource not accessible by integration' "${ROOT}/unit.log" || { echo "FAIL: the API rejection was not surfaced"; exit 1; }
grep -q 'commit via git vc failed; leaving changes uncommitted' "${ROOT}/unit.log" || { echo "FAIL: commit_changes did not report the failed commit"; exit 1; }
[[ ! -e "${UNIT}/.commit-msg" ]] || { echo "FAIL: .commit-msg was not consumed after the failed commit"; exit 1; }
grep -q 'change' "${UNIT}/f.txt" || { echo "FAIL: the change was lost"; exit 1; }
[[ "$(git -C "${UNIT}" rev-list --count HEAD)" == "1" ]] || { echo "FAIL: a commit was created despite the rejection"; exit 1; }
grep -q 'f.txt' <<<"$(git -C "${UNIT}" status --porcelain)" || { echo "FAIL: the change did not survive uncommitted"; exit 1; }

# --- Part 2: the driver keeps running when a commit is rejected -----------
WORK="${ROOT}/repo"
mkdir -p "${WORK}"
git -C "${WORK}" init -q
git -C "${WORK}" config user.email "test@example.com"
git -C "${WORK}" config user.name "test"
git -C "${WORK}" config commit.gpgsign false
printf 'base\n' > "${WORK}/file.txt"
printf '# Guide\nCommit-failure fixture README\n' > "${WORK}/README.md"
git -C "${WORK}" add -A
git -C "${WORK}" commit -qm init
# A change the agent started but could not commit (the branch head never moved).
printf 'mock change from opencode/first\n' > "${WORK}/conahcnuj.mock"
# Every local commit is rejected, standing in for the FORBIDDEN API answer.
mkdir -p "${WORK}/.git/hooks"
printf '#!/bin/sh\nexit 1\n' > "${WORK}/.git/hooks/pre-commit"
chmod +x "${WORK}/.git/hooks/pre-commit"

# Mocked response tape, in call order (same shape as the resume fixtures):
#   fetch_issue (auto-detect: PR input), fetch_pr_state, fetch_issue (real body),
#   fetch_reviews (collection), update_pr, fetch_reviews
#   (CHANGES_REQUESTED with an open thread), conditions, request_review,
#   fetch_reviews (APPROVED -> ready to merge).
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"title":"Fix something","body":"stub","labels":[],"pull_request":{}}
{"data":{"repository":{"pullRequest":{"number":15,"state":"OPEN","title":"Fix something","body":"Closes #10","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"CHANGES_REQUESTED","headRefName":"feature/fix-10","baseRefName":"main","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","closingIssuesReferences":{"nodes":[{"number":10}]}}}}}
{"number": 10, "title": "Fix something", "body": "# 背景\nコミット失敗時の継続。", "labels": [{"name": "enhancement"}], "state": "open"}
{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":101,"body":"Please document the collected context","author":{"login":"reviewer"}}]}}]}}}}}
{}
{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[{"state":"CHANGES_REQUESTED","body":"Please rename this function","author":{"login":"reviewer"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":12345,"body":"What is Input?","author":{"login":"reviewer"}}]}}]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{}
{"data":{"repository":{"pullRequest":{"reviewDecision":"APPROVED","reviews":{"nodes":[{"state":"APPROVED","body":"LGTM","author":{"login":"nahcnuj"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
EOF

export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export MOCK_OPENCODE_MODELS="opencode/first"
# The model answers with only a .commit-msg; the pre-seeded change is the work
# it could not commit.
export MOCK_OPENCODE_MESSAGE_ONLY="opencode/first"
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

[[ ${RC} -eq 0 ]] || { echo "FAIL: driver exited ${RC} (expected 0) after a rejected commit"; exit 1; }
grep -q "New review feedback detected" "${LOG}" || { echo "FAIL: review feedback was not acted on"; exit 1; }
# The local commit is rejected; the driver reports it and keeps going.
grep -q "commit failed (test mode); leaving changes uncommitted" "${LOG}" || { echo "FAIL: commit_changes did not report the failed commit"; exit 1; }
grep -q "commit failed while addressing feedback" "${LOG}" || { echo "FAIL: the feedback site did not guard the failed commit"; exit 1; }
grep -q "filing a bug report issue" "${LOG}" && { echo "FAIL: a rejected commit filed a bug report"; exit 1; }
grep -q "Driver exited abnormally" "${LOG}" && { echo "FAIL: a rejected commit aborted the run"; exit 1; }

# The change survives uncommitted and the message is cleaned up.
[[ -f "${WORK}/conahcnuj.mock" ]] || { echo "FAIL: the uncommitted change disappeared"; exit 1; }
[[ ! -e "${WORK}/.commit-msg" ]] || { echo "FAIL: .commit-msg was left behind"; exit 1; }
[[ "$(git -C "${WORK}" rev-list --count HEAD)" == "1" ]] || { echo "FAIL: an unexpected commit was created"; exit 1; }
grep -q "conahcnuj.mock" <<<"$(git -C "${WORK}" status --porcelain)" || { echo "FAIL: the change is no longer present uncommitted"; exit 1; }

# The run still hands the PR back to the owner and finishes cleanly.
grep -q "Review requested on PR #15 (reviewer: nahcnuj)" "${LOG}" || { echo "FAIL: the driver did not hand the PR back to the owner as reviewer"; exit 1; }

echo "conahcnuj commit-failure flow passed"
