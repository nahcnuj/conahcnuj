#!/usr/bin/env bash
# TODO.md lifecycle / draft-gating unit test (offline).
#
# Sources bin/conahcnuj.sh (CONAHCNUJ_IMPORT=1) and stubs the GitHub helpers,
# like ensure-pr-body.sh does, to verify:
#   * untracked `?? TODO.md` alone never counts as work (workdir_changed)
#   * ensure_pr creates the PR as a Draft while the branch still carries
#     TODO.md at its tip, and as a ready PR once it is gone
#   * ensure_pr aligns an existing PR's draft flag with the branch through
#     gh_api_set_pr_draft, once, and never flips a PR whose flag is unknown
#   * syncing to Draft must succeed (a non-Draft PR for unfinished work is
#     forbidden), while syncing to ready may fail with a warning
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

export CONAHCNUJ_IMPORT=1
PR_DRAFT_STATE_FILE="$(mktemp)"
export PR_DRAFT_STATE_FILE
# shellcheck source=bin/conahcnuj.sh
. "${REPO}/bin/conahcnuj.sh"

REPORT="$(mktemp)"
SCRATCH="$(mktemp -d)"
trap 'rm -f "${REPORT}" "${PR_DRAFT_STATE_FILE}"; rm -rf "${SCRATCH}"' EXIT

git -C "${SCRATCH}" init -q
git -C "${SCRATCH}" config user.email "test@example.com"
git -C "${SCRATCH}" config user.name "test"
git -C "${SCRATCH}" config commit.gpgsign false
printf 'base\n' > "${SCRATCH}/file.txt"
git -C "${SCRATCH}" add -A
git -C "${SCRATCH}" commit -qm init
cd "${SCRATCH}"

STUB_FIND_OUT=""
SET_FAILS=""

gh_api_create_pr() {
  printf 'CREATE|%s|%s|%s\n' "${5}" "${6}" "${7:-false}" >> "${REPORT}"
  printf '%s\n' "77"
}
gh_api_set_pr_draft() {
  printf 'SET|%s|%s\n' "${3}" "${4}" >> "${REPORT}"
  if [[ -n "${SET_FAILS}" ]]; then
    return 1
  fi
}
gh_api_find_pr_by_head() {
  printf '%s\n' "${STUB_FIND_OUT}"
}
gh_api_update_pr() { :; }

reset_report() {
  : > "${REPORT}"
  : > "${PR_DRAFT_STATE_FILE}"
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# 1. Fresh branch without TODO.md: the PR is created ready (not draft).
reset_report
STUB_FIND_OUT=""
out="$(ensure_pr "nahcnuj" "conahcnuj" "" "branch" "main" "title" "body" "")"
[[ "${out}" == "77" ]] || fail "create path output was '${out}'"
grep -q '^CREATE|branch|main|false$' "${REPORT}" || fail "a branch without TODO.md must create a non-draft PR"
[[ "$(cat "${PR_DRAFT_STATE_FILE}")" == "false" ]] || fail "draft state was not recorded as false"
echo "create without TODO.md -> draft=false: passed"

# 2. The branch carries TODO.md at its tip: the PR must be created as a Draft.
printf 'x\n' > "${SCRATCH}/TODO.md"
git -C "${SCRATCH}" add -A
git -C "${SCRATCH}" commit -qm todo
reset_report
STUB_FIND_OUT=""
out="$(ensure_pr "nahcnuj" "conahcnuj" "" "branch" "main" "title" "body" "")"
[[ "${out}" == "77" ]] || fail "create path output was '${out}'"
grep -q '^CREATE|branch|main|true$' "${REPORT}" || fail "a branch with TODO.md must create a draft PR"
[[ "$(cat "${PR_DRAFT_STATE_FILE}")" == "true" ]] || fail "draft state was not recorded as true"
echo "create with TODO.md on branch -> draft=true: passed"

# 3. Existing PR already drafted, branch still has TODO.md: nothing to change.
reset_report
STUB_FIND_OUT="42|true"
printf 'true' > "${PR_DRAFT_STATE_FILE}"
out="$(ensure_pr "nahcnuj" "conahcnuj" "" "branch" "main" "title" "body" "")"
[[ "${out}" == "42" ]] || fail "existing draft PR output was '${out}'"
grep -q '^SET' "${REPORT}" && fail "an aligned draft PR must not be synced again"
[[ "$(cat "${PR_DRAFT_STATE_FILE}")" == "true" ]] || fail "draft state was lost"
echo "existing draft PR with TODO.md on branch -> no sync: passed"

# 4. Existing draft PR, but TODO.md is gone from the branch: mark it ready.
git -C "${SCRATCH}" rm -q TODO.md
git -C "${SCRATCH}" commit -qm rm-todo
reset_report
STUB_FIND_OUT="42|true"
printf 'true' > "${PR_DRAFT_STATE_FILE}"
out="$(ensure_pr "nahcnuj" "conahcnuj" "" "branch" "main" "title" "body" "")"
[[ "${out}" == "42" ]] || fail "existing PR output was '${out}'"
grep -q '^SET|42|false$' "${REPORT}" || fail "a draft PR with a clean branch must be marked ready"
[[ "$(cat "${PR_DRAFT_STATE_FILE}")" == "false" ]] || fail "draft state was not updated to false"
echo "existing draft PR, TODO.md gone -> SET false: passed"

# 5. Given (resumed) PR recorded as ready, but TODO.md is back on the branch:
#    convert it back to a Draft.
printf 'x\n' > "${SCRATCH}/TODO.md"
git -C "${SCRATCH}" add -A
git -C "${SCRATCH}" commit -qm todo-again
reset_report
STUB_FIND_OUT=""
printf 'false' > "${PR_DRAFT_STATE_FILE}"
out="$(ensure_pr "nahcnuj" "conahcnuj" "15" "branch" "main" "title" "body" "")"
[[ "${out}" == "15" ]] || fail "given PR output was '${out}'"
grep -q '^SET|15|true$' "${REPORT}" || fail "a non-draft PR with TODO.md on branch must convert to draft"
[[ "$(cat "${PR_DRAFT_STATE_FILE}")" == "true" ]] || fail "draft state was not updated to true"
echo "resumed non-draft PR, TODO.md present -> SET true: passed"

# 6. Failing to convert back to Draft must fail the run's PR setup.
reset_report
printf 'false' > "${PR_DRAFT_STATE_FILE}"
SET_FAILS="yes"
if ensure_pr "nahcnuj" "conahcnuj" "15" "branch" "main" "title" "body" "" > /dev/null; then
  fail "a failed to-draft sync must fail ensure_pr"
fi
SET_FAILS=""
echo "failed to-draft sync -> ensure_pr fails: passed"

# 7. Failing to mark ready only warns: a PR stuck in Draft is safe.
git -C "${SCRATCH}" rm -q TODO.md
git -C "${SCRATCH}" commit -qm rm-todo2
reset_report
printf 'true' > "${PR_DRAFT_STATE_FILE}"
SET_FAILS="yes"
out="$(ensure_pr "nahcnuj" "conahcnuj" "15" "branch" "main" "title" "body" "" 2>/dev/null)" || fail "a failed ready-sync must not fail ensure_pr"
[[ "${out}" == "15" ]] || fail "given PR output was '${out}'"
grep -q '^SET|15|false$' "${REPORT}" || fail "the ready-sync must have been attempted"
SET_FAILS=""
echo "failed ready-sync -> ensure_pr continues with a warning: passed"

# 8. A PR whose draft flag was never recorded is never converted blind.
reset_report
STUB_FIND_OUT="42" # minimal payload: no isDraft
out="$(ensure_pr "nahcnuj" "conahcnuj" "" "branch" "main" "title" "body" "")"
[[ "${out}" == "42" ]] || fail "existing PR output was '${out}'"
grep -q '^SET' "${REPORT}" && fail "unknown draft state must not trigger a sync"
[[ "$(cat "${PR_DRAFT_STATE_FILE}")" == "" ]] || fail "unknown draft state must stay unknown"
echo "unknown draft flag -> no sync: passed"

# 9. workdir_changed: metadata and the fresh-progress-file do not count.
git -C "${SCRATCH}" rm -q --ignore-unmatch TODO.md
git -C "${SCRATCH}" commit --allow-empty -qm tidy
printf 'x\n' > "${SCRATCH}/TODO.md"
if workdir_changed "${SCRATCH}"; then
  fail "a fresh untracked TODO.md must not count as work"
fi
printf 'real\n' > "${SCRATCH}/real.txt"
if ! workdir_changed "${SCRATCH}"; then
  fail "a real change must count as work"
fi
git -C "${SCRATCH}" add -A
git -C "${SCRATCH}" commit -qm commit-real
printf 'y\n' >> "${SCRATCH}/TODO.md"
if ! workdir_changed "${SCRATCH}"; then
  fail "editing a tracked TODO.md must count as work"
fi
git -C "${SCRATCH}" add -A
git -C "${SCRATCH}" commit -qm commit-todo
rm "${SCRATCH}/TODO.md"
if ! workdir_changed "${SCRATCH}"; then
  fail "deleting a tracked TODO.md must count as work"
fi
echo "workdir_changed ignores only the fresh untracked TODO.md: passed"

echo "conahcnuj TODO.md lifecycle tests passed"
