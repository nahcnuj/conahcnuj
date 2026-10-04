#!/usr/bin/env bash
# conahcnuj "fix a conflicting branch" round test (offline).
#
# A pull request whose head branch sits behind the base reports
# mergeable=CONFLICTING / mergeStateStatus=DIRTY, and GitHub runs no CI on it.
# poll_conditions must hand the coding agent that state, not the bare
# "constraints failing" line: the only fix available from inside the run is to
# merge the base branch into the working tree (api-commit.sh appends commits
# and never rewrites history), and the agent cannot even try that without the
# base branch and its history, which a shallow checkout does not carry.
#
# Drives bin/conahcnuj.sh <PR> against a mocked GitHub API tape whose
# statusCheckRollup is green while the PR itself is conflicting:
#
#   PR #15 state read -> head branch checked out -> conditions report
#   CONFLICTING/DIRTY (checks are green, so this is purely the stale base) ->
#   implementation round that names the base branch and how to fetch it ->
#   constraints re-verified (now MERGEABLE) -> owner assigned as reviewer ->
#   "review requested" -> exit 0
#
# The round must also stay inside the agent's scope: nothing in the prompt may
# suggest changing repository merge policy (see tests/merge-policy-scope.sh).
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

# Mocked response tape, in call order. The conditions payloads carry a
# statusCheckRollup so the driver's own workflow run can be told apart from
# real CI; here real CI is already green, which is what makes the conflict the
# only thing left to fix.
#   fetch_issue (auto-detect: PR input), fetch_pr_state, fetch_issue (stub
#   body -> real issue body), update_pr (body sync), continuation comment,
#   conditions (SUCCESS checks + CONFLICTING/DIRTY), conditions (SUCCESS +
#   MERGEABLE), fetch_reviews (nothing to act on), request_review.
# The tape and log live OUTSIDE the repo (the driver's test-mode commit
# path runs `git add -A`).
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"title":"Fix something","body":"stub","labels":[],"pull_request":{}}
{"data":{"repository":{"pullRequest":{"number":15,"state":"OPEN","title":"Fix something","body":"Closes #10","isDraft":false,"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","reviewDecision":"REVIEW_REQUIRED","headRefName":"feature/fix-10","baseRefName":"main","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","closingIssuesReferences":{"nodes":[{"number":10}]}}}}}
{"number": 10, "title": "Fix something", "body": "# 背景\nブランチ保護を緩めない範囲で作業する。", "labels": [{"name": "enhancement"}], "state": "open"}
{}
{"id":889}
{"data":{"repository":{"pullRequest":{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","state":"OPEN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS","contexts":{"nodes":[{"__typename":"CheckRun","name":"Lint shell scripts (ubuntu-latest)","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}}],"pageInfo":{"hasNextPage":false}}}}]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","state":"OPEN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS","contexts":{"nodes":[{"__typename":"CheckRun","name":"Lint shell scripts (ubuntu-latest)","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}}],"pageInfo":{"hasNextPage":false}}}}]}}}}}
{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{}
EOF

export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export MOCK_OPENCODE_MODELS="opencode/first"
export CONAHCNUJ_REPO="nahcnuj/conahcnuj"

# A wrapping agent session (the conahcnuj opencode plugin) exports these for
# the real driver runs; the mock trailer check below must not see them.
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

grep -q "PR #15 constraints: checks=SUCCESS mergeable=CONFLICTING mergeState=DIRTY" "${LOG}" || { echo "FAIL: the conflict was not recognised as the failing constraint"; exit 1; }
grep -q "PR #15: constraints failing; fixing with a new implementation round." "${LOG}" || { echo "FAIL: the driver did not run a fix round for the conflict"; exit 1; }
grep -q "Review requested on PR #15 (reviewer: nahcnuj): https://github.com/nahcnuj/conahcnuj/pull/15" "${LOG}" || { echo "FAIL: the driver did not hand the PR back to the owner as reviewer"; exit 1; }
# The fix round must name what is actually wrong, and the base branch it has to
# integrate. Without both, the agent re-implements the issue instead of the
# conflict and the PR stays CONFLICTING forever.
grep -q "Observed on PR #15: checks=SUCCESS mergeable=CONFLICTING mergeStateStatus=DIRTY" "${LOG}" || { echo "FAIL: the agent was not told which constraint is failing"; exit 1; }
grep -q "git fetch origin main" "${LOG}" || { echo "FAIL: the agent was not told how to get the base branch"; exit 1; }
grep -q "git fetch --unshallow origin" "${LOG}" || { echo "FAIL: the agent was not told about the shallow checkout"; exit 1; }
# Scope: the round must not point at the owner's merge policy as the way out.
# The scope rules themselves appear in the mocked prompt and are negated, so
# mirror tests/merge-policy-scope.sh and drop negated hits.
POLICY_HITS="$(grep -iE "(remove|disable|relax|weaken|bypass).{0,80}(branch protection|protection rules|required status checks)" "${LOG}" | grep -viE "never|not|cannot|can not|without|refuse|forbidden" || true)"
if [[ -n "${POLICY_HITS}" ]]; then
  echo "FAIL: the fix round suggests changing repository merge policy:"
  printf '%s\n' "${POLICY_HITS}"
  exit 1
fi

[[ "$(git -C "${WORK}" branch --show-current)" == "feature/fix-10" ]] || { echo "FAIL: wrong current branch"; exit 1; }
ONELINE="$(git -C "${WORK}" log --oneline)"
grep -q "mock commit from opencode/first" <<<"${ONELINE}" || { echo "FAIL: the agent's .commit-msg was not used for the commit"; exit 1; }

echo "conahcnuj conflicting-branch fix round passed"