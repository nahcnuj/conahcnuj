#!/usr/bin/env bash
# conahcnuj approved-but-conflicting test (offline).
#
# Reproduces the bug where a pull request whose reviewDecision is APPROVED was
# reported as "Ready to merge" even though its branch still conflicted with the
# base. An approval only means a human approved the code; it does not make an
# unmergeable branch mergeable (the base can advance after the approval). The
# driver must verify the non-reviewer constraints even when approved, resolve
# the conflict, and only then report the PR as ready.
#
# The tape drives a resumed PR that is already APPROVED and CONFLICTING. It
# asserts that the conflict is fixed and that "Ready to merge" only appears
# after the conflict has been resolved.
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
git -C "${WORK}" branch -M main
git -C "${WORK}" checkout -q -b feature/fix-10
printf 'implementation\n' >> "${WORK}/file.txt"
git -C "${WORK}" add -A
git -C "${WORK}" commit -qm "implementation"

# Mocked response tape, in call order:
#   fetch_issue (auto-detect: PR input), fetch_pr_state, fetch_reviews
#   (collection: nothing open), update_pr (body sync), post_comment (the
#   continuation comment), fetch_reviews (APPROVED), conditions
#   (CONFLICTING/DIRTY -> the conflict fix round), fetch_reviews (still
#   APPROVED), conditions (MERGEABLE/CLEAN -> passes, then ready to merge).
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"title":"Fix something","body":"A written description","labels":[],"pull_request":{}}
{"data":{"repository":{"pullRequest":{"number":15,"state":"OPEN","title":"Fix something","body":"A written description","isDraft":false,"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","reviewDecision":"APPROVED","headRefName":"feature/fix-10","baseRefName":"main","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","closingIssuesReferences":{"nodes":[{"number":10}]}}}}}
{"data":{"repository":{"pullRequest":{"reviewDecision":"APPROVED","reviews":{"nodes":[{"state":"APPROVED","body":"LGTM","author":{"login":"nahcnuj"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{}
{"id":889}
{"data":{"repository":{"pullRequest":{"reviewDecision":"APPROVED","reviews":{"nodes":[{"state":"APPROVED","body":"LGTM","author":{"login":"nahcnuj"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","state":"OPEN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{"data":{"repository":{"pullRequest":{"reviewDecision":"APPROVED","reviews":{"nodes":[{"state":"APPROVED","body":"LGTM","author":{"login":"nahcnuj"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","state":"OPEN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
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

grep -q "reviewDecision: APPROVED" "${LOG}" || { echo "FAIL: the approval was not read"; exit 1; }

# The approval must not short-circuit the constraint check: the conflict is
# recognized and fixed instead of being reported as ready.
grep -q "constraints failing (conflict)" "${LOG}" || { echo "FAIL: the approved PR's conflict was not fixed"; exit 1; }
grep -q "has a merge conflict with its base branch" "${LOG}" || { echo "FAIL: the driver did not report the merge conflict"; exit 1; }

FIX_COMMIT="$(git -C "${WORK}" log --oneline -1)"
grep -q "mock commit from opencode/first" <<<"${FIX_COMMIT}" || { echo "FAIL: the conflict-fix commit is missing"; exit 1; }

# "Ready to merge" must come only after the conflict fix, never before it.
CONFLICT_LINE="$(grep -n "constraints failing (conflict)" "${LOG}" | head -1 | cut -d: -f1)"
READY_LINE="$(grep -n "Ready to merge" "${LOG}" | head -1 | cut -d: -f1)"
[[ -n "${READY_LINE}" ]] || { echo "FAIL: no ready-to-merge line"; exit 1; }
[[ -n "${CONFLICT_LINE}" && "${CONFLICT_LINE}" -lt "${READY_LINE}" ]] || { echo "FAIL: the PR was reported ready before the conflict was fixed"; exit 1; }

echo "conahcnuj approved-but-conflicting passed"
