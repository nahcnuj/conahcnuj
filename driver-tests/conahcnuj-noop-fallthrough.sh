#!/usr/bin/env bash
# conahcnuj "a no-op model must not abandon the remaining models" test (offline).
#
# A model can finish a round without failing while producing nothing at all
# (no working-tree change, no commit, no .commit-msg). The driver retries such
# a model once, and if it still produces nothing it must move on to the next
# model instead of ending the whole model fall-through. Ending it there means a
# single idle model aborts an issue even though later models could do the work,
# which files the recursive "failed to resolve #N" bug report (issue #556).
#
#   issue #10 read -> feature branch -> implement:
#     opencode/noop   produces nothing twice ("produced no complete work")
#     opencode/second takes the session over and commits
#   -> PR #123 created -> constraints pass -> review requested -> approved
#   -> exit 0, no bug report.
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
printf '# Guide\nNoop fixture README\n' > "${WORK}/README.md"
git -C "${WORK}" add -A
git -C "${WORK}" commit -qm init

# Mocked response tape (same shape as conahcnuj-flow.sh).
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"number": 10, "title": "no-op model fall-through", "body": "# 背景\nnoop fixture", "labels": [{"name": "enhancement"}], "state": "open"}
{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"id":"R_kgDOXmplR3p"}}}
{"data":{"createPullRequest":{"pullRequest":{"number":123}}}}
{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{}
{}
{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"reviewDecision":"APPROVED","reviews":{"nodes":[{"state":"APPROVED","body":"LGTM","author":{"login":"nahcnuj"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
EOF

export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export MOCK_OPENCODE_MODELS="opencode/noop
opencode/second"
# The first model succeeds (no error) but produces no change at all.
export MOCK_OPENCODE_NOOP="opencode/noop"
export CONAHCNUJ_REPO="nahcnuj/conahcnuj"

unset CONAHCNUJ_COMMIT_MODEL CONAHCNUJ_MODEL_LABEL_FILE CONAHCNUJ_SESSION_MODEL \
  CONAHCNUJ_RUN_TIMEOUT_SECONDS OPENCODE_LAST_MODEL

LOG="${ROOT}/run.log"
RC=0
(
  cd "${WORK}"
  CONAHCNUJ_MAX_SECONDS=120 bash "${DRIVER}" 10 < "${TAPE}"
) > "${LOG}" 2>&1 || RC=$?

echo "----- conahcnuj run log -----"
cat "${LOG}"
echo "-----------------------------"

[[ ${RC} -eq 0 ]] || { echo "FAIL: driver exited ${RC} (expected 0)"; exit 1; }
grep -q "filing a bug report issue" "${LOG}" && { echo "FAIL: the driver filed a bug report over an idle model"; exit 1; }

# The no-op model is retried once, then reported without ending the run.
grep -q "Model opencode/noop produced no complete work; retrying once with the same model." "${LOG}" || { echo "FAIL: the no-op round was not retried once"; exit 1; }
grep -q "Model opencode/noop produced no complete work." "${LOG}" || { echo "FAIL: the idle model was not reported as producing no work"; exit 1; }

# The crux: the remaining model is still tried and completes the work.
grep -q "Model opencode/second completed the work" "${LOG}" || { echo "FAIL: the run did not fall through to the next model"; exit 1; }
grep -q "Created PR #123" "${LOG}" || { echo "FAIL: PR #123 was not created"; exit 1; }
grep -q "Review requested on PR #123 (reviewer: nahcnuj)" "${LOG}" || { echo "FAIL: the driver did not hand the PR to the owner as reviewer"; exit 1; }
grep -q "Ready to merge" "${LOG}" || { echo "FAIL: the run did not reach the owner's approval"; exit 1; }

ONELINE="$(git -C "${WORK}" log --oneline)"
grep -q "mock commit from opencode/second" <<<"${ONELINE}" || { echo "FAIL: the completing model's .commit-msg was not used"; exit 1; }

echo "conahcnuj no-op fall-through passed"
