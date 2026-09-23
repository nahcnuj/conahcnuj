#!/usr/bin/env bash
# conahcnuj PR-creation-failure recovery test (offline).
#
# When GitHub refuses to create the PR (e.g. createPullRequest UNPROCESSABLE
# because there is no diff between base and head), the driver must NOT die and
# file the recursive "failed to resolve #N" bug report. It runs an
# implementation round and retries; the branch ends up with real work and the
# PR is eventually created.
#
#   issue read -> branch -> implement -> create_pr (UNPROCESSABLE) ->
#   re-implement -> create_pr (#125) -> constraints pass -> review requested
#   -> APPROVED -> "ready to merge" -> exit 0
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

# get_repo carries the local main tip so branch_has_commits compares HEAD
# against it (the fixed path); HEAD == main tip => no commits => implement.
OID="$(git -C "${WORK}" rev-parse HEAD)"

# Mocked response tape, in call order:
#   fetch_issue, get_repo, find_pr_by_head_any (empty), find_pr_by_head (empty),
#   repo id, create_pr (UNPROCESSABLE) -> then, after the recovery round:
#   find_pr_by_head (empty), repo id, create_pr (125), conditions (SUCCESS),
#   request_review, fetch_reviews (APPROVED), conditions.
TAPE="${ROOT}/tape.txt"
sed "s/OID_PLACEHOLDER/${OID}/" > "${TAPE}" <<'EOF'
{"number": 18, "title": "fix racing driver", "body": "PR creation must be retried, not fatal", "labels": [], "state": "open"}
{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"OID_PLACEHOLDER"}}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"id":"R_kgDOXmplR3p"}}}
{"data":null,"errors":[{"type":"UNPROCESSABLE","path":["createPullRequest"],"message":"no commits between base and head"}]}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"id":"R_kgDOXmplR3p"}}}
{"data":{"createPullRequest":{"pullRequest":{"number":125}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{}
{"data":{"repository":{"pullRequest":{"reviewDecision":"APPROVED","reviews":{"nodes":[{"state":"APPROVED","body":"LGTM","author":{"login":"reviewer"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
EOF

export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export MOCK_OPENCODE_MODELS="opencode/first"
export CONAHCNUJ_REPO="nahcnuj/conahcnuj"

LOG="${ROOT}/run.log"
RC=0
(
  cd "${WORK}"
  CONAHCNUJ_MAX_SECONDS=120 bash "${DRIVER}" 18 < "${TAPE}"
) > "${LOG}" 2>&1 || RC=$?

echo "----- conahcnuj run log -----"
cat "${LOG}"
echo "-----------------------------"

[[ ${RC} -eq 0 ]] || { echo "FAIL: driver exited ${RC} (expected 0)"; exit 1; }

grep -q "PR could not be created for conahcnuj/18-fix-racing-driver -> main; running an implementation round." "${LOG}" || { echo "FAIL: the driver did not recover from the PR creation failure"; exit 1; }
grep -q "Created PR #125" "${LOG}" || { echo "FAIL: PR #125 was not created on the retry"; exit 1; }
grep -q "Ready to merge" "${LOG}" || { echo "FAIL: no ready-to-merge line"; exit 1; }
grep -q "filing a bug report issue" "${LOG}" && { echo "FAIL: a failed PR creation must not trigger the bug report"; exit 1; }

echo "conahcnuj PR-creation-failure recovery passed"