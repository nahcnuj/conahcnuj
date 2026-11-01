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
# No real run should sit in the fetch retry pause during an offline test.
export CONAHCNUJ_BRANCH_FETCH_RETRY_PAUSE=0
# shellcheck source=bin/conahcnuj.sh
. "${REPO}/bin/conahcnuj.sh"

# Any branch (re)creation would be an API call; a fetch failure must never
# reach it, so record it instead of letting it hit the network. The exit status
# is switchable: creation can succeed while the ref is still not fetchable,
# which is the case that used to abort a run on a brand-new branch.
API_CALLS="${ROOT}/api-calls.txt"
: > "${API_CALLS}"
CREATE_BRANCH_RC=1
gh_api_create_branch() {
  printf 'gh_api_create_branch %s\n' "$*" >> "${API_CALLS}"
  return "${CREATE_BRANCH_RC}"
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

# 5. A brand-new branch whose remote creation succeeds but which is not
#    fetchable yet (the create API returns before the git endpoint advertises
#    the ref, or the fetch is briefly unavailable) must NOT abort: nothing is
#    committed on a new branch, so the run starts it from the base and carries
#    on. The remote repository is reachable again, and the branch simply is not
#    there, so the fetch fails exactly as it did in the reported #738 run.
git -C "${WORK}" remote set-url origin "${REMOTE}"
git -C "${WORK}" fetch -q origin main
BASE_HEAD="$(git -C "${WORK}" rev-parse origin/main)"
NEW_BRANCH="conahcnuj/115-brand-new"
CREATE_BRANCH_RC=0
: > "${API_CALLS}"
rc=0
out="$(
  cd "${WORK}"
  ensure_issue_branch "nahcnuj" "conahcnuj" 115 "brand new" "main" "${BASE_HEAD}" "${NEW_BRANCH}" 2>"${ROOT}/new.log"
)" || rc=$?
[[ ${rc} -eq 0 ]] || { echo "FAIL: a brand-new branch with a transient fetch failure aborted (rc=${rc})" >&2; exit 1; }
[[ "${out}" == "${NEW_BRANCH}" ]] || { echo "FAIL: ensure_issue_branch did not return the new branch name: ${out}" >&2; exit 1; }
[[ "$(git -C "${WORK}" rev-parse HEAD)" == "${BASE_HEAD}" ]] || { echo "FAIL: the new branch was not started from the base" >&2; exit 1; }
[[ "$(git -C "${WORK}" branch --show-current)" == "${NEW_BRANCH}" ]] || { echo "FAIL: wrong current branch after the fallback" >&2; exit 1; }
grep -q "gh_api_create_branch" "${API_CALLS}" || { echo "FAIL: the remote branch was not created" >&2; exit 1; }
grep -q "not fetchable right after creation" "${ROOT}/new.log" || { echo "FAIL: the fallback was not explained in the log" >&2; exit 1; }

# 6. A stale local remote-tracking ref must not abort the run: when the branch
#    was deleted on the remote but origin/<branch> lingers locally (a clone
#    that was not pruned), the remote itself is the authority. The branch is
#    verifiably absent upstream, so nothing can be lost by starting it from the
#    base; checking out the stale ref instead used to fail the fetch and stop
#    the run (the reported #734 run).
STALE_BRANCH="conahcnuj/115-deleted-remotely"
git -C "${UPSTREAM}" commit -q --allow-empty -m "to be deleted"
git -C "${UPSTREAM}" push -q origin "HEAD:refs/heads/${STALE_BRANCH}"
git -C "${WORK}" fetch -q origin "${STALE_BRANCH}"
git -C "${UPSTREAM}" push -q origin ":refs/heads/${STALE_BRANCH}"
git -C "${WORK}" rev-parse --verify -q "origin/${STALE_BRANCH}" >/dev/null || {
  echo "FAIL: the test fixture did not leave a stale remote-tracking ref" >&2
  exit 1
}
CREATE_BRANCH_RC=0
: > "${API_CALLS}"
rc=0
out="$(
  cd "${WORK}"
  ensure_issue_branch "nahcnuj" "conahcnuj" 115 "deleted remotely" "main" "${BASE_HEAD}" "${STALE_BRANCH}" 2>"${ROOT}/stale.log"
)" || rc=$?
[[ ${rc} -eq 0 ]] || { echo "FAIL: a stale remote-tracking ref with no remote branch aborted (rc=${rc})" >&2; exit 1; }
[[ "${out}" == "${STALE_BRANCH}" ]] || { echo "FAIL: ensure_issue_branch did not return the branch name: ${out}" >&2; exit 1; }
[[ "$(git -C "${WORK}" rev-parse HEAD)" == "${BASE_HEAD}" ]] || { echo "FAIL: the stale branch was not restarted from the base" >&2; exit 1; }
[[ "$(git -C "${WORK}" branch --show-current)" == "${STALE_BRANCH}" ]] || { echo "FAIL: wrong current branch after the stale-ref fallback" >&2; exit 1; }
