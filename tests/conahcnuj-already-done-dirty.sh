#!/usr/bin/env bash
# conahcnuj "already implemented, dirty workdir" flow test (offline).
#
# When the feature branch already carries the implementation the driver skips
# the model fall-through and opens the PR directly - no implement round runs,
# so no coding agent ever writes a .commit-msg. If the local workdir still
# holds leftover files from an interrupted earlier run (scratch scripts, API
# reply payloads, ...), those must NOT make the driver call commit_changes and
# then die on the missing .commit-msg (that crashed a real run and filed a bug
# report issue). The driver should leave the scratch files untouched and go
# straight to the PR / review loop.
#
#   issue #10 read -> existing feature branch (already has a commit) and an
#   untracked scratch file + no .commit-msg -> implement skipped -> PR #124
#   created -> constraints pass -> review requested -> APPROVED ->
#   "ready to merge" -> exit 0, scratch file still present and uncommitted.
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

# Leftover scratch files from an interrupted earlier run: untracked, and the
# coding agent never got to write its .commit-msg. These must neither crash the
# driver nor get swept into a commit.
printf 'scratch\n' > "${WORK}/scratch.txt"
printf '{"reply": 1}\n' > "${WORK}/reply.json"

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
grep -q "left no .commit-msg" "${LOG}" && { echo "FAIL: the driver still crashed on the missing commit message"; exit 1; }
grep -q "Bug report issue" "${LOG}" && { echo "FAIL: the driver filed a bug report"; exit 1; }

# The scratch files must be untouched and must not have been committed.
# Capture command output first, then grep via here-string: `cmd | grep -q`
# under `set -o pipefail` is flaky (grep -q exits on the first match, cmd
# gets SIGPIPE, and pipefail turns that into a false failure).
[[ "$(cat "${WORK}/scratch.txt")" == "scratch" ]] || { echo "FAIL: scratch.txt was modified"; exit 1; }
[[ "$(cat "${WORK}/reply.json")" == '{"reply": 1}' ]] || { echo "FAIL: reply.json was modified"; exit 1; }
STATUS_OUT="$(git -C "${WORK}" status --porcelain)"
grep -q "scratch.txt" <<<"${STATUS_OUT}" || { echo "FAIL: scratch.txt disappeared"; exit 1; }
ONELINE="$(git -C "${WORK}" log --oneline)"
grep -q "existing implementation" <<<"${ONELINE}" || { echo "FAIL: pre-existing implementation commit lost"; exit 1; }
[[ "$(printf '%s\n' "${ONELINE}" | wc -l)" -eq 2 ]] || { echo "FAIL: unexpected extra commit(s) were created"; exit 1; }

echo "conahcnuj already-implemented-with-dirty-workdir flow passed"