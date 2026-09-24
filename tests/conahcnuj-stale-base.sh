#!/usr/bin/env bash
# conahcnuj stale default-branch ref regression test (offline).
#
# The driver decides "the branch already carries the implementation" by
# comparing HEAD against the default branch's tip as freshly read from the API.
# A stale local origin/<default> ref must NOT make a branch that sits exactly
# at the real main tip look "already implemented": previously that skipped
# implementation and tried to open a PR that GitHub rejects (createPullRequest:
# UNPROCESSABLE, no commits between base and head), crashing the driver and
# filing the recursive bug-report chain (issues #33/#34).
#
#   stale origin/main == old main, API default oid == real main == branch
#   tip -> implement runs -> commit -> PR #124 -> APPROVED -> ready to merge
#   -> exit 0
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

# The real default branch has since advanced (a PR was merged): this is the
# current main tip the API reports and the feature branch gets created from.
printf 'merged\n' >> "${WORK}/file.txt"
git -C "${WORK}" add -A
git -C "${WORK}" commit -qm "real main head"
REAL_OID="$(git -C "${WORK}" rev-parse HEAD)"
# ... but the local clone's origin/main ref is stale, still at the old main.
STALE_OID="$(git -C "${WORK}" rev-parse HEAD~1)"
git -C "${WORK}" update-ref "refs/remotes/origin/main" "${STALE_OID}"

# Mocked response tape: the get_repo answer carries the freshly-read real OID,
# not the stale local ref. With the old buggy branch_has_commits the driver
# would misclassify the empty branch as done and skip implementation.
TAPE="${ROOT}/tape.txt"
sed "s/REAL_OID_PLACEHOLDER/${REAL_OID}/" > "${TAPE}" <<'EOF'
{"number": 17, "title": "shellcheck disable", "body": "stale base ref test", "labels": [], "state": "open"}
{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"REAL_OID_PLACEHOLDER"}}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"id":"R_kgDOXmplR3p"}}}
{"data":{"createPullRequest":{"pullRequest":{"number":124}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{}
{"data":{"repository":{"pullRequest":{"reviewDecision":"APPROVED","reviews":{"nodes":[{"state":"APPROVED","body":"LGTM","author":{"login":"reviewer"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
EOF

unset CONAHCNUJ_COMMIT_MODEL
export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export MOCK_OPENCODE_MODELS="opencode/first"
export CONAHCNUJ_REPO="nahcnuj/conahcnuj"

LOG="${ROOT}/run.log"
RC=0
(
  cd "${WORK}"
  CONAHCNUJ_MAX_SECONDS=120 bash "${DRIVER}" 17 < "${TAPE}"
) > "${LOG}" 2>&1 || RC=$?

echo "----- conahcnuj run log -----"
cat "${LOG}"
echo "-----------------------------"

[[ ${RC} -eq 0 ]] || { echo "FAIL: driver exited ${RC} (expected 0)"; exit 1; }

grep -q "Implementing with available models" "${LOG}" || { echo "FAIL: the driver skipped implementation despite an empty branch"; exit 1; }
grep -q "already has commits; skipping implement" "${LOG}" && { echo "FAIL: the stale origin/main ref wrongly triggered the already-done skip"; exit 1; }
grep -q "Created PR #124" "${LOG}" || { echo "FAIL: PR #124 was not created"; exit 1; }
grep -q "Ready to merge" "${LOG}" || { echo "FAIL: no ready-to-merge line"; exit 1; }

# Here-string, not `git log | grep -q`: under `set -o pipefail` an early
# grep -q exit SIGPIPEs git and fails the pipeline even on a match.
ONELINE="$(git -C "${WORK}" log --oneline)"
grep -q "mock commit from opencode/first" <<<"${ONELINE}" || { echo "FAIL: the agent's implementation commit is missing"; exit 1; }

echo "conahcnuj stale default-branch ref flow passed"