#!/usr/bin/env bash
# TODO.md draft-gating end-to-end flow test (offline).
#
# Drives the real bin/conahcnuj.sh against a mocked GitHub API tape and a
# mocked opencode, like conahcnuj-flow.sh, and watches the PR's draft flag
# through the PR_DRAFT_STATE_FILE marker:
#
#   1. A mock round that creates TODO.md must leave the PR draft
#      (PR_DRAFT_STATE_FILE == "true", TODO.md committed on the branch).
#   2. A mock round that deletes TODO.md must leave the PR ready
#      (PR_DRAFT_STATE_FILE == "false", TODO.md gone from the branch).
#
# No secrets, no network.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
DRIVER="${REPO}/bin/conahcnuj.sh"

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT

make_repo() {
  local dir="${1}"
  mkdir -p "${dir}"
  git -C "${dir}" init -q
  git -C "${dir}" config user.email "test@example.com"
  git -C "${dir}" config user.name "test"
  git -C "${dir}" config commit.gpgsign false
  printf 'base\n' > "${dir}/file.txt"
  git -C "${dir}" add -A
  git -C "${dir}" commit -qm init
}

write_tape() {
  local tape="${1}"
  cat > "${tape}" <<'EOF'
{"number": 10, "title": "issue駆動自律開発", "body": "# 背景\n動作確認用のダミー issue です。", "labels": [{"name": "enhancement"}], "state": "open"}
{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"id":"R_kgDOXmplR3p"}}}
{"data":{"createPullRequest":{"pullRequest":{"number":123}}}}
{"id":776}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{}
EOF
}

export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export MOCK_OPENCODE_MODELS="opencode/first"
export CONAHCNUJ_REPO="nahcnuj/conahcnuj"

unset CONAHCNUJ_COMMIT_MODEL CONAHCNUJ_MODEL_LABEL_FILE CONAHCNUJ_SESSION_MODEL \
  CONAHCNUJ_RUN_TIMEOUT_SECONDS OPENCODE_LAST_MODEL

# --- scenario 1: the mock round creates TODO.md -> PR is created as a Draft ---
WORK="${ROOT}/scenario1"
make_repo "${WORK}"
write_tape "${ROOT}/tape1.txt"
STATE="${ROOT}/state1"
export PR_DRAFT_STATE_FILE="${STATE}"
export MOCK_OPENCODE_TODO=1
unset MOCK_OPENCODE_TODO_DELETE
LOG="${ROOT}/run1.log"
RC=0
(
  cd "${WORK}"
  CONAHCNUJ_MAX_SECONDS=120 bash "${DRIVER}" 10 < "${ROOT}/tape1.txt"
) > "${LOG}" 2>&1 || RC=$?
cat "${LOG}"
[[ ${RC} -eq 0 ]] || { echo "FAIL(s1): driver exited ${RC} (expected 0)"; exit 1; }
grep -q "Created PR #123" "${LOG}" || { echo "FAIL(s1): PR #123 was not created"; exit 1; }
grep -q "Review requested on PR #123" "${LOG}" || { echo "FAIL(s1): the driver did not hand the PR to the owner as reviewer"; exit 1; }
[[ "$(cat "${STATE}")" == "true" ]] || { echo "FAIL(s1): PR_DRAFT_STATE_FILE should be 'true', was '$(cat "${STATE}")'"; exit 1; }
git -C "${WORK}" cat-file -e HEAD:TODO.md || { echo "FAIL(s1): TODO.md should be committed on the branch"; exit 1; }
echo "scenario 1 (mock creates TODO.md -> draft PR): passed"

# --- scenario 2: TODO.md exists at issue start and the mock round deletes it
# --- -> the PR is created ready ---
WORK2="${ROOT}/scenario2"
make_repo "${WORK2}"
printf 'x\n' > "${WORK2}/TODO.md"
git -C "${WORK2}" add -A
git -C "${WORK2}" commit -qm todo
write_tape "${ROOT}/tape2.txt"
STATE2="${ROOT}/state2"
export PR_DRAFT_STATE_FILE="${STATE2}"
export MOCK_OPENCODE_TODO_DELETE=1
unset MOCK_OPENCODE_TODO
LOG2="${ROOT}/run2.log"
RC=0
(
  cd "${WORK2}"
  CONAHCNUJ_MAX_SECONDS=120 bash "${DRIVER}" 10 < "${ROOT}/tape2.txt"
) > "${LOG2}" 2>&1 || RC=$?
cat "${LOG2}"
[[ ${RC} -eq 0 ]] || { echo "FAIL(s2): driver exited ${RC} (expected 0)"; exit 1; }
grep -q "Created PR #123" "${LOG2}" || { echo "FAIL(s2): PR #123 was not created"; exit 1; }
grep -q "Review requested on PR #123" "${LOG2}" || { echo "FAIL(s2): the driver did not hand the PR to the owner as reviewer"; exit 1; }
[[ "$(cat "${STATE2}")" == "false" ]] || { echo "FAIL(s2): PR_DRAFT_STATE_FILE should be 'false', was '$(cat "${STATE2}")'"; exit 1; }
if git -C "${WORK2}" cat-file -e HEAD:TODO.md; then
  echo "FAIL(s2): TODO.md should be gone from the branch"; exit 1;
fi
echo "scenario 2 (mock deletes TODO.md -> ready PR): passed"

echo "conahcnuj TODO.md draft-gating flows passed"
