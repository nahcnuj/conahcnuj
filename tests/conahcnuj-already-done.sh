#!/usr/bin/env bash
# conahcnuj "already implemented" flow test (offline).
#
# When the feature branch already carries the implementation (commits on top
# of the default branch) the driver must NOT run the model fall-through; it
# must go straight to opening the PR and then run the review loop. This is the
# scenario where a previous run committed the work, so asking every model to
# implement again would just spin forever.
#
#   issue #10 read -> existing feature branch (already has a commit) ->
#   implement skipped -> PR #124 created -> constraints pass -> review
#   requested -> APPROVED -> "ready to merge" -> exit 0
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
# Name the default branch explicitly so branch_has_commits can compare to it.
git -C "${WORK}" branch -M main

# Simulate a previous run: the feature branch already exists and carries the
# implementation. The driver must detect this and skip implement.
git -C "${WORK}" checkout -q -b "conahcnuj/10-issue"
printf 'implemented\n' >> "${WORK}/file.txt"
git -C "${WORK}" add -A
git -C "${WORK}" commit -qm "existing implementation"

# Mocked response tape, in call order:
#   fetch_issue, get_repo, find_pr_by_head_any (empty), find_pr_by_head (empty),
#   repo id, create_pr (124), conditions (SUCCESS), request_review,
#   fetch_reviews (APPROVED), conditions.
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"number": 10, "title": "issue駆動自律開発", "body": "# 背景\n動作確認用のダミー issue です。", "labels": [{"name": "enhancement"}], "state": "open"}
{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"id":"R_kgDOXmplR3p"}}}
{"data":{"createPullRequest":{"pullRequest":{"number":124}}}}
{"id":776}
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
  CONAHCNUJ_MAX_SECONDS=120 bash "${DRIVER}" 10 < "${TAPE}"
) > "${LOG}" 2>&1 || RC=$?

echo "----- conahcnuj run log -----"
cat "${LOG}"
echo "-----------------------------"

[[ ${RC} -eq 0 ]] || { echo "FAIL: driver exited ${RC} (expected 0)"; exit 1; }

grep -q "already has commits; skipping implement" "${LOG}" || { echo "FAIL: implement was not skipped"; exit 1; }
grep -q "Implementing with available models" "${LOG}" && { echo "FAIL: the driver still ran the model fall-through"; exit 1; }
grep -q "Created PR #124" "${LOG}" || { echo "FAIL: PR #124 was not created"; exit 1; }
grep -q "Ready to merge" "${LOG}" || { echo "FAIL: no ready-to-merge line"; exit 1; }

[[ "$(git -C "${WORK}" branch --show-current)" == "conahcnuj/10-issue" ]] || { echo "FAIL: wrong current branch"; exit 1; }
# Here-string, not `git log | grep -q`: under `set -o pipefail` an early
# grep -q exit SIGPIPEs git and fails the pipeline even on a match.
ONELINE="$(git -C "${WORK}" log --oneline)"
grep -q "existing implementation" <<<"${ONELINE}" || { echo "FAIL: pre-existing implementation commit lost"; exit 1; }
grep -q "conahcnuj: implement issue #10" <<<"${ONELINE}" && { echo "FAIL: a new implement commit was created"; exit 1; }

echo "conahcnuj already-implemented flow passed"
