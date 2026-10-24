#!/usr/bin/env bash
# reconcile_with_remote_tip regression test (offline).
#
# The Verified commit api-commit.sh creates is built against the remote branch
# tip it reads (expectedHeadOid), but the file changes are collected from the
# local index and work tree, which sit on local HEAD. When the branch advanced
# under the working tree (a concurrent run, a hand push, or a commit this
# checkout never pulled) the collected changeset is stale and GitHub rejects the
# commit: a file the local base still has may already be gone at the tip, and
# the run crashed with a confusing "A path was requested for deletion which does
# not exist as of commit oid ..." NOT_FOUND (issue #428).
#
# commit_changes now calls reconcile_with_remote_tip before staging: it replays
# the working tree's uncommitted changes onto the advanced tip (a rebase of the
# uncommitted work), so the commit is collected against the same base as
# expectedHeadOid. This test drives that helper directly through three cases:
#
#   1. No divergence            -> no-op, the tree is untouched.
#   2. Local behind, no overlap  -> changes replay cleanly onto the new tip:
#                                  a re-delete of an already-deleted file is a
#                                  no-op and an edit of an untouched file is
#                                  preserved.
#   3. Local behind, real clash  -> the pop conflicts, the tree is restored to
#                                  the original base and the call fails so the
#                                  driver reports the conflict instead of
#                                  committing a stale changeset.
#
# The remote is a local bare repository, so the test needs no network. The
# driver is sourced via CONAHCNUJ_IMPORT=1 (main() must not run) in real
# (non-TEST_MODE) mode, exactly like conahcnuj-branch-head.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

ROOT="$(mktemp -d)"
REMOTE="${ROOT}/origin.git"
WORK="${ROOT}/repo"
trap 'rm -rf "${ROOT}"' EXIT

export CONAHCNUJ_TEST_MODE=0
export CONAHCNUJ_IMPORT=1
# shellcheck source=bin/conahcnuj.sh
. "${REPO}/bin/conahcnuj.sh"

git init -q --bare -b feat "${REMOTE}"
git clone -q "${REMOTE}" "${WORK}"
git -C "${WORK}" config user.email "test@example.com"
git -C "${WORK}" config user.name "test"
git -C "${WORK}" config commit.gpgsign false

# Base commit A: the file the later tip deletes, and two files both sides will
# touch differently (one) or only the working tree will touch (the other).
printf 'base\n' > "${WORK}/del.txt"
printf 'base\n' > "${WORK}/clash.txt"
printf 'base\n' > "${WORK}/solo.txt"
git -C "${WORK}" add -A
git -C "${WORK}" commit -qm "A"
git -C "${WORK}" branch -M feat
git -C "${WORK}" push -q origin feat
A_OID="$(git -C "${WORK}" rev-parse HEAD)"

# Helper: commit the current work tree as the new branch tip and push it. Each
# scenario builds on the same base A, so the push is forced (the scenarios are
# independent, not a linear history).
make_tip() {
  git -C "${WORK}" add -A
  git -C "${WORK}" commit -qm "$1"
  git -C "${WORK}" push -q --force origin feat
  git -C "${WORK}" rev-parse HEAD
}

reset_to_base() {
  git -C "${WORK}" reset -q --hard "${A_OID}"
  git -C "${WORK}" clean -qfd
}

# --- 1. No divergence is a no-op --------------------------------------------
reset_to_base
printf 'base\nsolo-edit\n' > "${WORK}/solo.txt"
BEFORE="$(git -C "${WORK}" rev-parse HEAD)"
rc=0
( cd "${WORK}" && reconcile_with_remote_tip ) >"${ROOT}/noop.log" 2>&1 || rc=$?
[[ ${rc} -eq 0 ]] || { echo "FAIL: reconcile failed with no divergence (rc=${rc})"; cat "${ROOT}/noop.log"; exit 1; }
[[ "$(git -C "${WORK}" rev-parse HEAD)" == "${BEFORE}" ]] || { echo "FAIL: HEAD moved with no divergence"; exit 1; }
[[ "$(cat "${WORK}/solo.txt")" == $'base\nsolo-edit' ]] || { echo "FAIL: the work tree changed with no divergence"; exit 1; }

# --- 2. Local behind, no textual overlap -> clean rebase --------------------
reset_to_base
# The tip deletes del.txt and edits clash.txt; the working tree (on the old
# base) re-deletes del.txt and edits solo.txt, which the tip never touched.
git -C "${WORK}" rm -q del.txt
printf 'base\nclash-remote\n' > "${WORK}/clash.txt"
TIP_B="$(make_tip "B: remote deletes del.txt, edits clash.txt")"
reset_to_base
git -C "${WORK}" rm -q del.txt
printf 'base\nsolo-local\n' > "${WORK}/solo.txt"
rc=0
( cd "${WORK}" && reconcile_with_remote_tip ) >"${ROOT}/clean.log" 2>&1 || rc=$?
[[ ${rc} -eq 0 ]] || { echo "FAIL: clean rebase returned rc=${rc}"; cat "${ROOT}/clean.log"; exit 1; }
grep -q "Rebased the working-tree changes onto" "${ROOT}/clean.log" || { echo "FAIL: no rebase confirmation"; cat "${ROOT}/clean.log"; exit 1; }
[[ "$(git -C "${WORK}" rev-parse HEAD)" == "${TIP_B}" ]] || { echo "FAIL: HEAD did not move to the remote tip"; exit 1; }
[[ ! -e "${WORK}/del.txt" ]] || { echo "FAIL: del.txt should be gone (already deleted at the tip)"; exit 1; }
[[ "$(cat "${WORK}/solo.txt")" == $'base\nsolo-local' ]] || { echo "FAIL: the solo.txt edit was not replayed"; exit 1; }
[[ "$(cat "${WORK}/clash.txt")" == $'base\nclash-remote' ]] || { echo "FAIL: the tip's clash.txt edit was lost"; exit 1; }

# --- 3. Local behind, real clash -> conflict is reported, tree restored ------
reset_to_base
git -C "${WORK}" rm -q del.txt
printf 'base\nclash-remote\n' > "${WORK}/clash.txt"
make_tip "C: remote edits clash.txt" >/dev/null
reset_to_base
printf 'base\nclash-local\n' > "${WORK}/clash.txt"
rc=0
( cd "${WORK}" && reconcile_with_remote_tip ) >"${ROOT}/clash.log" 2>&1 || rc=$?
[[ ${rc} -ne 0 ]] || { echo "FAIL: a clashing rebase was reported as success"; cat "${ROOT}/clash.log"; exit 1; }
grep -q "cannot be rebased cleanly" "${ROOT}/clash.log" || { echo "FAIL: the conflict was not explained"; cat "${ROOT}/clash.log"; exit 1; }
# The tree is restored to the original base so nothing is silently lost.
[[ "$(git -C "${WORK}" rev-parse HEAD)" == "${A_OID}" ]] || { echo "FAIL: HEAD was not restored to the original base"; exit 1; }
[[ "$(cat "${WORK}/clash.txt")" == $'base\nclash-local' ]] || { echo "FAIL: the work tree was not restored to the agent's version"; exit 1; }
# No leftover stash entry to confuse a later commit.
[[ -z "$(git -C "${WORK}" stash list)" ]] || { echo "FAIL: a stash entry was left behind"; exit 1; }

echo "conahcnuj reconcile-with-remote-tip passed"
