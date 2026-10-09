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

echo "conahcnuj branch-head checkout passed"