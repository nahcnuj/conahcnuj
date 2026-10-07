#!/usr/bin/env bash
# checkout_branch_head test (offline).
#
# A run that cannot fetch the feature branch must stop instead of carrying on
# with whatever origin/<branch> still holds locally. That stale ref makes the
# checkout "succeed" at an old commit, so the driver reads the branch as "not
# implemented yet" and hands a fresh implementation round to a model, which
# re-implements work that is already committed on the branch and commits that
# second copy on top of the real head (issue #115).
#
# The remote is a local bare repository, so the test needs no network, and the
# fetch failure is produced by pointing origin at a path that no longer exists.
#
# Sources bin/conahcnuj.sh via CONAHCNUJ_IMPORT=1 (main() must not run) in real
# (non-TEST_MODE) mode, because the offline flow tests take the TEST_MODE
# shortcut that skips the fetch entirely.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

ROOT="$(mktemp -d)"
REMOTE="${ROOT}/origin.git"
UPSTREAM="${ROOT}/upstream"
WORK="${ROOT}/repo"
trap 'rm -rf "${ROOT}"' EXIT

export CONAHCNUJ_TEST_MODE=0
export CONAHCNUJ_IMPORT=1
# shellcheck source=bin/conahcnuj.sh
. "${REPO}/bin/conahcnuj.sh"

# Any branch (re)creation would be an API call; a fetch failure must never
# reach it, so record it instead of letting it hit the network.
API_CALLS="${ROOT}/api-calls.txt"
: > "${API_CALLS}"
gh_api_create_branch() {
  printf 'gh_api_create_branch %s\n' "$*" >> "${API_CALLS}"
  return 1
}

git init -q --bare -b main "${REMOTE}"
git init -q "${UPSTREAM}"
git -C "${UPSTREAM}" config user.email "test@example.com"
git -C "${UPSTREAM}" config user.name "test"
git -C "${UPSTREAM}" config commit.gpgsign false
printf 'base\n' > "${UPSTREAM}/file.txt"
git -C "${UPSTREAM}" add -A
git -C "${UPSTREAM}" commit -qm init
git -C "${UPSTREAM}" remote add origin "${REMOTE}"
git -C "${UPSTREAM}" push -q origin "HEAD:refs/heads/main"
git clone -q "${REMOTE}" "${WORK}"
git -C "${WORK}" config user.email "test@example.com"
git -C "${WORK}" config user.name "test"
git -C "${WORK}" config commit.gpgsign false

BRANCH="conahcnuj/115-request-changes"

# A feature branch that already carries the implementation, as an earlier run
# left it on the remote.
printf 'implemented\n' > "${UPSTREAM}/file.txt"
git -C "${UPSTREAM}" add -A
git -C "${UPSTREAM}" commit -qm "implemented on the branch"
git -C "${UPSTREAM}" push -q origin "HEAD:refs/heads/${BRANCH}"
REMOTE_HEAD="$(git -C "${UPSTREAM}" rev-parse HEAD)"

# 1. A reachable remote: the fetch succeeds and HEAD becomes the branch head,
#    so the driver sees the work that is already committed.
(
  cd "${WORK}"
  checkout_branch_head "${BRANCH}"
) >"${ROOT}/ok.log" 2>&1
[[ "$(git -C "${WORK}" rev-parse HEAD)" == "${REMOTE_HEAD}" ]] || {
  echo "FAIL: HEAD did not move to the branch head ($(git -C "${WORK}" rev-parse HEAD))" >&2
  exit 1
}
[[ "$(cat "${WORK}/file.txt")" == "implemented" ]] || { echo "FAIL: the branch content was not checked out" >&2; exit 1; }
[[ "$(git -C "${WORK}" branch --show-current)" == "${BRANCH}" ]] || { echo "FAIL: wrong current branch" >&2; exit 1; }

# The remote moves on and this clone loses its reachability: origin/<branch> is
# now stale, which is the state that used to be worked on silently.
git -C "${UPSTREAM}" commit -q --allow-empty -m "remote moved on"
git -C "${UPSTREAM}" push -q origin "HEAD:refs/heads/${BRANCH}"
git -C "${WORK}" remote set-url origin "${ROOT}/gone.git"

STALE_HEAD="$(git -C "${WORK}" rev-parse HEAD)"

# 2. The failed fetch is reported and stops the run.
LOG="${ROOT}/failed.log"
rc=0
(
  cd "${WORK}"
  checkout_branch_head "${BRANCH}"
) >"${LOG}" 2>&1 || rc=$?
[[ ${rc} -ne 0 ]] || { echo "FAIL: a failed fetch was reported as success" >&2; exit 1; }
grep -q "refusing to work on a stale branch head" "${LOG}" || { echo "FAIL: no explanation for the stopped run" >&2; exit 1; }
[[ "$(git -C "${WORK}" rev-parse HEAD)" == "${STALE_HEAD}" ]] || { echo "FAIL: HEAD moved despite the failed fetch" >&2; exit 1; }

# 3. The resume path (PR input) stops as well.
rc=0
(
  cd "${WORK}"
  ensure_pr_branch_head "nahcnuj" "conahcnuj" "${BRANCH}"
) >"${LOG}" 2>&1 || rc=$?
[[ ${rc} -ne 0 ]] || { echo "FAIL: ensure_pr_branch_head carried on with a stale head" >&2; exit 1; }

# 4. The issue path stops too, and prints no branch name for the caller to use.
rc=0
out="$(
  cd "${WORK}"
  ensure_issue_branch "nahcnuj" "conahcnuj" 115 "request changes" "main" "$(git -C "${WORK}" rev-parse origin/main)" "${BRANCH}" 2>"${LOG}"
)" || rc=$?
[[ ${rc} -ne 0 ]] || { echo "FAIL: ensure_issue_branch carried on with a stale head" >&2; exit 1; }
[[ -z "${out}" ]] || { echo "FAIL: ensure_issue_branch returned a branch name on failure: ${out}" >&2; exit 1; }
[[ "$(git -C "${WORK}" rev-parse HEAD)" == "${STALE_HEAD}" ]] || { echo "FAIL: HEAD moved despite the failed fetch" >&2; exit 1; }
[[ ! -s "${API_CALLS}" ]] || { echo "FAIL: a failed fetch recreated the branch: $(cat "${API_CALLS}")" >&2; exit 1; }

WORK2="${ROOT}/other-repo"
git clone -q "${REMOTE}" "${WORK2}"
git -C "${WORK2}" fetch -q origin "${BRANCH}"
printf 'personal changes\n' >> "${WORK2}/file.txt"

out="$(
  cd "${WORK2}"
  ensure_issue_branch "nahcnuj" "conahcnuj" 115 "request changes" main "$(git rev-parse origin/main)" "${BRANCH}"
)"
[[ "${out}" == "${BRANCH}" ]] || { echo "FAIL: worktree branch name was polluted" >&2; exit 1; }
TREE="${WORK2}.worktrees/${BRANCH}"
[[ "$(git -C "${WORK2}" branch --show-current)" == "main" ]] || { echo "FAIL: caller branch was changed" >&2; exit 1; }
[[ "$(cat "${WORK2}/file.txt")" == $'base\npersonal changes' ]] || { echo "FAIL: caller changes were lost" >&2; exit 1; }
[[ "$(git -C "${TREE}" branch --show-current)" == "${BRANCH}" ]] || { echo "FAIL: worktree did not check out the branch" >&2; exit 1; }
[[ "$(git -C "${TREE}" rev-parse HEAD)" == "$(git -C "${UPSTREAM}" rev-parse HEAD)" ]] || { echo "FAIL: worktree head is stale" >&2; exit 1; }

printf 'unfinished\n' > "${TREE}/scratch.txt"
(
  cd "${WORK2}"
  ensure_pr_branch_head "nahcnuj" "conahcnuj" "${BRANCH}"
) >"${ROOT}/reuse.log" 2>&1
[[ "$(cat "${TREE}/scratch.txt")" == "unfinished" ]] || { echo "FAIL: resumed worktree changes were lost" >&2; exit 1; }

git -C "${UPSTREAM}" commit -q --allow-empty -m "new remote head"
git -C "${UPSTREAM}" push -q origin "HEAD:refs/heads/${BRANCH}"
rc=0
(
  cd "${WORK2}"
  ensure_pr_branch_head "nahcnuj" "conahcnuj" "${BRANCH}"
) >"${ROOT}/dirty.log" 2>&1 || rc=$?
[[ ${rc} -ne 0 ]] || { echo "FAIL: remote advance overwrote uncommitted work" >&2; exit 1; }
[[ "$(cat "${TREE}/scratch.txt")" == "unfinished" ]] || { echo "FAIL: remote advance removed uncommitted work" >&2; exit 1; }
[[ "$(git -C "${WORK2}" branch --show-current)" == "main" ]] || { echo "FAIL: resume changed caller branch" >&2; exit 1; }
git -C "${WORK2}" remote set-url origin "${ROOT}/gone.git"
rc=0
(
  cd "${WORK2}"
  ensure_pr_branch_head "nahcnuj" "conahcnuj" "${BRANCH}"
) >"${ROOT}/worktree-fetch-failed.log" 2>&1 || rc=$?
[[ ${rc} -ne 0 ]] || { echo "FAIL: worktree resumed after a failed fetch" >&2; exit 1; }
[[ "$(cat "${TREE}/scratch.txt")" == "unfinished" ]] || { echo "FAIL: failed fetch removed worktree changes" >&2; exit 1; }

WORK3="${ROOT}/agent-repo"
git clone -q "${REMOTE}" "${WORK3}"
CHOICE_TREE="${WORK3}.worktrees/feature/agent-choice"
DEFAULT_OID="$(git -C "${WORK3}" rev-parse HEAD)"
gh_api_get_repo() { printf 'main|%s\n' "${DEFAULT_OID}"; }
gh_api_find_pr_by_head_any() { :; }
gh_api_create_branch() {
  git -C "${WORK3}" push -q origin "${4}:refs/heads/${3}"
}
implement() {
  printf 'implementation\n' > new.txt
  printf 'feature/agent-choice\n' > .branch-name
  printf 'agent commit\n' > .commit-msg
}
commit_changes() {
  [[ "$(pwd)" == "${CHOICE_TREE}" && -f new.txt && -f .commit-msg ]]
}
drive() {
  [[ "${4}" == "feature/agent-choice" && "$(pwd)" == "${CHOICE_TREE}" ]]
}
ISSUE="$(printf 'agent worktree' | base64 | tr -d '\n')|$(printf 'body' | base64 | tr -d '\n')"
(
  cd "${WORK3}"
  start_issue "nahcnuj" "conahcnuj" 99 "${ISSUE}"
) >"${ROOT}/agent.log" 2>&1 || { echo "FAIL: agent branch worktree move failed" >&2; exit 1; }
[[ "$(git -C "${WORK3}" branch --show-current)" == "main" ]] || { echo "FAIL: issue run changed caller branch" >&2; exit 1; }
[[ "$(git -C "${CHOICE_TREE}" branch --show-current)" == "feature/agent-choice" ]] || { echo "FAIL: chosen branch was not checked out in moved worktree" >&2; exit 1; }
[[ ! -d "${WORK3}.worktrees/conahcnuj/99-agent-worktree" ]] || { echo "FAIL: old worktree path remains after rename" >&2; exit 1; }
(
  cd "${WORK3}"
  ensure_pr_branch_head "nahcnuj" "conahcnuj" "feature/agent-choice"
) >"${ROOT}/agent-resume.log" 2>&1
[[ -f "${CHOICE_TREE}/new.txt" ]] || { echo "FAIL: resume lost the agent's changes" >&2; exit 1; }

echo "conahcnuj branch-head checkout passed"
