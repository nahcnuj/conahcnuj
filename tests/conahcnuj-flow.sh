#!/usr/bin/env bash
# conahcnuj driver end-to-end flow test (offline).
#
# Drives the real bin/conahcnuj.sh state machine against a mocked GitHub API
# tape (one JSON per API call, in call order) and a mocked opencode, inside a
# throwaway git repository. Exercises the happy path end to end:
#
#   issue #10 read -> feature branch -> implement -> PR #123 created ->
#   non-reviewer constraints pass -> review requested -> CHANGES_REQUESTED
#   feedback detected -> addressed + committed -> re-verified -> replied ->
#   polled again -> APPROVED + constraints -> "ready to merge" -> exit 0
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

# A tiny repository on the default branch. Git identity is required because
# the driver's test-mode commit path uses plain `git commit`.
git -C "${WORK}" init -q
git -C "${WORK}" config user.email "test@example.com"
git -C "${WORK}" config user.name "test"
git -C "${WORK}" config commit.gpgsign false
printf 'base\n' > "${WORK}/file.txt"
git -C "${WORK}" add -A
git -C "${WORK}" commit -qm init

# Mocked response tape. One JSON document per GitHub API call, in call order:
#   fetch_issue, get_repo, find_pr_by_head (empty), repo id lookup, create_pr
#   (123), conditions (SUCCESS|MERGEABLE), request_review, fetch_reviews
#   (CHANGES_REQUESTED), conditions, request_review, post_comment,
#   fetch_reviews (fingerprint refresh after the reply), update_pr (body sync on
#   the reuse path), conditions, fetch_reviews (APPROVED), conditions.
# Keep the tape and the run log OUTSIDE the repo: the driver's test-mode
# commit path does `git add -A`, and a file living in the worktree would be
# re-staged as it grows.
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"number": 10, "title": "issue駆動自律開発", "body": "# 背景\n動作確認用のダミー issue です。", "labels": [{"name": "enhancement"}], "state": "open"}
{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"id":"R_kgDOXmplR3p"}}}
{"data":{"createPullRequest":{"pullRequest":{"number":123}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{}
{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[{"state":"CHANGES_REQUESTED","body":"Please fix the typo","author":{"login":"reviewer"}}]},"comments":{"nodes":[{"body":"Nice work so far!","author":{"login":"reviewer"}}]},"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"body":"Inline note on line 10"}]}}]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{}
{"id":777}
{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[{"state":"CHANGES_REQUESTED","body":"Please fix the typo","author":{"login":"reviewer"}}]},"comments":{"nodes":[{"body":"Nice work so far!","author":{"login":"reviewer"}},{"body":"Addressed the review feedback:\n\nreviewDecision: CHANGES_REQUESTED\nREVIEWS:","author":{"login":"conahcnuj[bot]"}}]},"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"body":"Inline note on line 10"}]}}]}}}}}
{}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{"data":{"repository":{"pullRequest":{"reviewDecision":"APPROVED","reviews":{"nodes":[{"state":"APPROVED","body":"LGTM","author":{"login":"reviewer"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
EOF

export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1
# Two models; the first produces changes so the "try all models then stop"
# fallthrough stays on the happy path.
export MOCK_OPENCODE_MODELS="opencode/first
opencode/second"
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

grep -q "Ready to merge" "${LOG}" || { echo "FAIL: no ready-to-merge line"; exit 1; }
grep -q "Created PR #123" "${LOG}" || { echo "FAIL: PR #123 was not created"; exit 1; }
grep -q "Replied on PR #123 after addressing review feedback" "${LOG}" || { echo "FAIL: feedback reply was not posted"; exit 1; }
grep -q "New review feedback detected" "${LOG}" || { echo "FAIL: review feedback was not acted on"; exit 1; }

[[ "$(git -C "${WORK}" branch --show-current)" == "conahcnuj/10-issue" ]] || { echo "FAIL: wrong current branch"; exit 1; }
git -C "${WORK}" log --oneline | grep -q "conahcnuj: implement issue #10" || { echo "FAIL: implement commit missing"; exit 1; }
git -C "${WORK}" log --oneline | grep -q "address review feedback" || { echo "FAIL: feedback commit missing"; exit 1; }

echo "conahcnuj flow passed"