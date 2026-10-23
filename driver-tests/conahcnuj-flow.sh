#!/usr/bin/env bash
# conahcnuj driver end-to-end flow test (offline).
#
# Drives the real bin/conahcnuj.sh state machine against a mocked GitHub API
# tape (one JSON per API call, in call order) and a mocked opencode, inside a
# throwaway git repository. Exercises the happy path end to end:
#
#   issue #10 read -> feature branch -> implement -> PR #123 created ->
#   the constraints poll waits through PENDING until SUCCESS -> owner assigned
#   as reviewer -> the run keeps polling -> approval -> "ready to merge" ->
#   exit 0
#
# The driver verifies the non-reviewer constraints before it hands the PR to
# the reviewer: the human is asked only once CI is green and the branch merges,
# not while CI still runs. Whatever fails during the poll gets a fix round, so
# the issue is actually resolved rather than handed off in a failing state. The
# driver does not stop at the review request: it keeps polling for the verdict
# and ends on the approval (the merge owner-approved-auto-merge chains off it),
# which belongs to the human reviewer. The feedback round of a resumed run is
# covered by conahcnuj-resume.sh.
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
# the driver's test-mode commit path uses plain `git commit`. The README is
# there so the first prompt can be asserted to carry the collected context.
git -C "${WORK}" init -q
git -C "${WORK}" config user.email "test@example.com"
git -C "${WORK}" config user.name "test"
git -C "${WORK}" config commit.gpgsign false
printf 'base\n' > "${WORK}/file.txt"
printf '# Guide\nFlow fixture README\n' > "${WORK}/README.md"
git -C "${WORK}" add -A
git -C "${WORK}" commit -qm init

# Mocked response tape. One JSON document per GitHub API call, in call order:
#   fetch_issue, get_repo, find_pr_by_head (empty), repo id lookup, create_pr
#   (123), continuation comment, fetch_reviews (REVIEW_REQUIRED, nothing to act
#   on), conditions (PENDING|MERGEABLE), conditions (SUCCESS|MERGEABLE),
#   request_review, then the wait loop: PR body sync, fetch_reviews
#   (REVIEW_REQUIRED, still waiting), fetch_reviews (APPROVED -> ready to
#   merge). The constraints are polled before the review request: a fresh PR is
#   only handed to the reviewer once the checks are green and the branch merges,
#   never while CI still runs. CI is PENDING on the first poll, so the driver
#   must keep polling until SUCCESS before it asks. The reviews are read before
#   the poll so known review feedback is handled before waiting on CI (#219).
#   The approval is read only after the driver has waited once, so the test
#   proves the run keeps polling past the review request instead of exiting.
# Keep the tape and the run log OUTSIDE the repo: the driver's test-mode
# commit path does `git add -A`, and a file living in the worktree would be
# re-staged as it grows.
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"number": 10, "title": "issue駆動自律開発", "body": "# 背景\n動作確認用のダミー issue です。", "labels": [{"name": "enhancement"}], "state": "open"}
{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"id":"R_kgDOXmplR3p"}}}
{"data":{"createPullRequest":{"pullRequest":{"number":123}}}}
{"id":776}
{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"PENDING"}}}]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{}
{}
{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"reviewDecision":"APPROVED","reviews":{"nodes":[{"state":"APPROVED","body":"LGTM","author":{"login":"nahcnuj"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","state":"OPEN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
EOF

export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export MOCK_OPENCODE_MODELS="opencode/first
opencode/second"
export MOCK_OPENCODE_ERROR="opencode/first"
export CONAHCNUJ_REPO="nahcnuj/conahcnuj"

# A wrapping agent session (the conahcnuj opencode plugin) exports these for
# the real driver runs; the mock trailer check below must not see them.
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

grep -q "Review requested on PR #123 (reviewer: nahcnuj): https://github.com/nahcnuj/conahcnuj/pull/123" "${LOG}" || { echo "FAIL: the driver did not hand the PR to the owner as reviewer"; exit 1; }
grep -q "Assigned nahcnuj as reviewer on PR #123" "${LOG}" || { echo "FAIL: the owner was not assigned as reviewer"; exit 1; }
# The reviewer is asked only after the constraints pass: a fresh PR is handed
# to the human once it merges and CI is green, not while CI still runs.
ASSIGNED_LINE="$(grep -n 'Assigned nahcnuj as reviewer on PR #123' "${LOG}" | head -1 | cut -d: -f1)"
PASS_LINE="$(grep -n 'All non-reviewer constraints pass.' "${LOG}" | head -1 | cut -d: -f1)"
[[ -n "${ASSIGNED_LINE}" && -n "${PASS_LINE}" && "${PASS_LINE}" -lt "${ASSIGNED_LINE}" ]] || { echo "FAIL: the review request must come after the constraints pass"; exit 1; }
# The first poll finds CI still PENDING, so the driver must keep polling until
# SUCCESS before it asks for review. Asking while CI runs would hand the
# reviewer a PR that might still fail.
PENDING_LINE="$(grep -n 'PR #123 constraints: checks=PENDING' "${LOG}" | head -1 | cut -d: -f1)"
SUCCESS_LINE="$(grep -n 'PR #123 constraints: checks=SUCCESS' "${LOG}" | head -1 | cut -d: -f1)"
[[ -n "${PENDING_LINE}" ]] || { echo "FAIL: the driver did not poll while CI was still PENDING"; exit 1; }
[[ -n "${SUCCESS_LINE}" && "${PENDING_LINE}" -lt "${SUCCESS_LINE}" ]] || { echo "FAIL: the driver must keep polling until CI is green"; exit 1; }
[[ -n "${PASS_LINE}" && "${SUCCESS_LINE}" -lt "${PASS_LINE}" ]] || { echo "FAIL: the run must only finish once the constraints are satisfied"; exit 1; }
# The run does not stop at the review request: it keeps polling until the
# reviewer approves, so "Ready to merge" must appear and must come after the
# hand-off (and after a wait iteration in between).
READY_LINE="$(grep -n 'Ready to merge' "${LOG}" | head -1 | cut -d: -f1)"
WAIT_LINE="$(grep -n "waiting for the reviewer's decision" "${LOG}" | head -1 | cut -d: -f1)"
[[ -n "${WAIT_LINE}" ]] || { echo "FAIL: the driver exited at the review request instead of waiting for the verdict"; exit 1; }
[[ -n "${READY_LINE}" && "${ASSIGNED_LINE}" -lt "${READY_LINE}" ]] || { echo "FAIL: the driver did not keep polling to the approval"; exit 1; }
[[ "${WAIT_LINE}" -lt "${READY_LINE}" ]] || { echo "FAIL: the driver must wait for the verdict before it sees the approval"; exit 1; }
grep -q "Created PR #123" "${LOG}" || { echo "FAIL: PR #123 was not created"; exit 1; }
grep -q "New review feedback detected" "${LOG}" && { echo "FAIL: a fresh PR must not fire an implementation round"; exit 1; }
grep -q "Model opencode/first failed before completing the work; handing off to the next model" "${LOG}" || { echo "FAIL: failed model did not hand off"; exit 1; }
grep -q "Handing off session ses_mock from opencode/first to opencode/second" "${LOG}" || { echo "FAIL: session was not handed to the second model"; exit 1; }
grep -q -- "--session ses_mock" "${LOG}" || { echo "FAIL: continuation command omitted --session"; exit 1; }
grep -q "Model opencode/second completed the work" "${LOG}" || { echo "FAIL: second model was not adopted"; exit 1; }
# The first prompt already carries the checkout's README (an issue has no
# PR yet, so the collected context is the files alone).
grep -q "Collected context:" "${LOG}" || { echo "FAIL: the prompt has no collected context block"; exit 1; }
grep -q "Flow fixture README" "${LOG}" || { echo "FAIL: README.md was not collected into the prompt"; exit 1; }
grep -q "Collected context up front: README.md" "${LOG}" || { echo "FAIL: the run log does not say what was collected"; exit 1; }

[[ "$(git -C "${WORK}" branch --show-current)" == "conahcnuj/10-issue" ]] || { echo "FAIL: wrong current branch"; exit 1; }
# Capture first, then grep via here-string: `git log | grep -q` under
# `set -o pipefail` is flaky (grep -q exits on the first match, git gets
# SIGPIPE, and pipefail reports a false failure).
# The commit message always comes from the coding agent (.commit-msg), never
# from a fixed driver-side fallback.
ONELINE="$(git -C "${WORK}" log --oneline)"
grep -q "conahcnuj: implement issue #10" <<<"${ONELINE}" && { echo "FAIL: driver still used a fixed commit message"; exit 1; }
grep -q "mock commit from opencode/second" <<<"${ONELINE}" || { echo "FAIL: the handoff model's .commit-msg was not used"; exit 1; }
FULL_LOG="$(git -C "${WORK}" log --format=%B)"
grep -q "Co-Authored-By: opencode (second)" <<<"${FULL_LOG}" || { echo "FAIL: handoff model trailer missing"; exit 1; }
# init + implement = 2 commits from the branch tip (no feedback round here).
[[ "$(printf '%s\n' "${ONELINE}" | wc -l)" == "2" ]] || { echo "FAIL: expected init + implement commits"; exit 1; }

echo "conahcnuj flow passed"
