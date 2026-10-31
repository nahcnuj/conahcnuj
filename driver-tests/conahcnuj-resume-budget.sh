#!/usr/bin/env bash
# Time-budget exhaustion on an already-handed-off resumed PR (offline).
#
# Issue #749: a resumed PR that already had review feedback (CHANGES_REQUESTED)
# ran out of time mid-feedback. The driver had not requested review in that
# process, so it treated the exhaustion as a pre-hand-off failure, exited 1 and
# filed a bogus "failed to resolve" bug report even though the PR was already
# with the owner. An existing review means an earlier run handed the PR off, so
# the budget running out is a human wait and the run must end cleanly (exit 0)
# without a bug report.
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

# Tape, in call order:
#   fetch_issue (auto-detect: this number is a PR), fetch_pr_state
#   (CHANGES_REQUESTED -> an earlier run already handed the PR off),
#   fetch_issue (stub body -> real issue body), fetch_reviews
#   (collect_initial_context). The run then hits the exhausted budget before
#   it does any work.
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"title":"Fix something","body":"stub","labels":[],"pull_request":{}}
{"data":{"repository":{"pullRequest":{"number":15,"state":"OPEN","title":"Fix something","body":"Closes #10","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"CHANGES_REQUESTED","headRefName":"feature/fix-10","baseRefName":"main","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","closingIssuesReferences":{"nodes":[{"number":10}]}}}}}
{"number": 10, "title": "Fix something", "body": "Resume this PR.", "labels": [], "state": "open"}
{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":101,"body":"Please fix this","author":{"login":"reviewer"}}]}}]}}}}}
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
  CONAHCNUJ_MAX_SECONDS=0 bash "${DRIVER}" 15 < "${TAPE}"
) > "${LOG}" 2>&1 || RC=$?

echo "----- conahcnuj run log -----"
cat "${LOG}"
echo "-----------------------------"

[[ ${RC} -eq 0 ]] || { echo "FAIL: driver exited ${RC} (expected 0: the PR is already with the owner)"; exit 1; }
grep -q "time budget" "${LOG}" || { echo "FAIL: the run did not report the exhausted budget"; exit 1; }
grep -q "waits for a human" "${LOG}" || { echo "FAIL: the run did not end as a human wait"; exit 1; }
grep -q "ERROR: time budget" "${LOG}" && { echo "FAIL: the run treated a post-hand-off exhaustion as a failure"; exit 1; }
grep -q "filing a bug report" "${LOG}" && { echo "FAIL: the run filed a bug report for a human wait"; exit 1; }
grep -q "is a pull request; resuming it in place" "${LOG}" || { echo "FAIL: PR input was not auto-detected"; exit 1; }

echo "conahcnuj resume budget handling passed"
