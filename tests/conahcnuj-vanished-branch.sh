#!/usr/bin/env bash
# Vanished feature branch recovery (offline).
#
# A feature branch can disappear while the model works: GitHub deletes the head
# branch of a merged pull request, and a concurrent run of this driver (another
# workflow job, a local run) can merge and clean up the very branch this run is
# implementing on (issue #93). The commit then failed with a bare
# "branch ... not found" and threw away a finished implementation.
#
# Covers the two halves of the recovery:
#   * commit_changes always asks api-commit.sh for --create-branch and records
#     whether the remote branch was gone (COMMIT_BRANCH_RECREATED)
#   * branch_has_diff_from_base recognises the re-created branch that no longer
#     differs from the base, so the run stops instead of opening an empty PR
#
# api-commit.sh is replaced by a stub that records its arguments, so no network
# or secret is involved.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT

# --- a copy of the driver with a stubbed api-commit.sh ---------------------
STAGE="${ROOT}/stage"
mkdir -p "${STAGE}/bin" "${STAGE}/gh-app" "${STAGE}/lib"
cp "${REPO}/bin/conahcnuj.sh" "${STAGE}/bin/"
cp "${REPO}/lib/"*.sh "${STAGE}/lib/"
ARGS_LOG="${ROOT}/api-commit-args.log"
cat > "${STAGE}/gh-app/api-commit.sh" <<EOF
#!/usr/bin/env bash
# Stub: record the arguments the driver passes and answer with a fake sha.
printf '%s\n' "\$*" >> "${ARGS_LOG}"
printf 'stubnewsha'
EOF

# --- a work tree whose origin is a local bare repo --------------------------
git init -q --bare "${ROOT}/remote.git"
git init -q "${ROOT}/seed"
git -C "${ROOT}/seed" config user.email "test@example.com"
git -C "${ROOT}/seed" config user.name "test"
printf 'base\n' > "${ROOT}/seed/file.txt"
git -C "${ROOT}/seed" add -A
git -C "${ROOT}/seed" commit -qm init
git -C "${ROOT}/seed" branch -M main
git -C "${ROOT}/seed" remote add origin "${ROOT}/remote.git"
git -C "${ROOT}/seed" push -q origin main
# Point the bare repo's HEAD at main so the clone checks out a work tree.
git -C "${ROOT}/remote.git" symbolic-ref HEAD refs/heads/main

WORK="${ROOT}/repo"
git clone -q "${ROOT}/remote.git" "${WORK}"
git -C "${WORK}" config user.email "test@example.com"
git -C "${WORK}" config user.name "test"
git -C "${WORK}" config commit.gpgsign false

cd "${WORK}" || exit 1
CONAHCNUJ_IMPORT=1
CONAHCNUJ_TEST_MODE=0
# shellcheck source=bin/conahcnuj.sh
. "${STAGE}/bin/conahcnuj.sh"

BRANCH="conahcnuj/10-issue"
git checkout -q -b "${BRANCH}"

# The implementation the model produced, plus its commit message.
printf 'implemented\n' >> "${WORK}/file.txt"

# 1. The feature branch is gone from the remote (merged + deleted elsewhere):
#    commit_changes must ask for --create-branch and flag the recreation.
printf 'fix: implement issue #10\n' > .commit-msg
commit_changes
[[ -e .commit-msg ]] && { echo "FAIL: .commit-msg must be consumed" >&2; exit 1; }
grep -q -- "--create-branch" "${ARGS_LOG}" \
  || { echo "FAIL: commit_changes did not pass --create-branch:" >&2; cat "${ARGS_LOG}" >&2; exit 1; }
grep -q "fix: implement issue #10" "${ARGS_LOG}" \
  || { echo "FAIL: the agent's commit message was not forwarded" >&2; exit 1; }
if [[ "${COMMIT_BRANCH_RECREATED}" != "true" ]]; then
  echo "FAIL: a missing remote branch must be flagged as re-created" >&2
  exit 1
fi
echo "commit_changes (remote branch gone) -> --create-branch + flagged: passed"

# 2. The feature branch is on the remote: nothing is re-created, but the option
#    stays on so a branch deleted between this check and the commit still works.
git push -q origin "${BRANCH}"
: > "${ARGS_LOG}"
printf 'more\n' >> "${WORK}/file.txt"
printf 'fix: implement issue #10 (round 2)\n' > .commit-msg
commit_changes
grep -q -- "--create-branch" "${ARGS_LOG}" \
  || { echo "FAIL: commit_changes must always pass --create-branch" >&2; exit 1; }
if [[ "${COMMIT_BRANCH_RECREATED}" == "true" ]]; then
  echo "FAIL: an existing remote branch must not be flagged as re-created" >&2
  exit 1
fi
echo "commit_changes (remote branch present) -> not flagged: passed"

# 3. A re-created branch identical to the base has nothing left to review.
git checkout -q main
git fetch -q origin
if branch_has_diff_from_base main; then
  echo "FAIL: main must not differ from itself" >&2
  exit 1
fi
echo "branch_has_diff_from_base (identical to base) -> nothing to review: passed"

# 4. A branch that really carries a change still has something to review.
git checkout -q -B "${BRANCH}" origin/main
printf 'implemented\n' >> "${WORK}/file.txt"
git commit -qam "fix: implement issue #10"
if ! branch_has_diff_from_base main; then
  echo "FAIL: a branch with a real change must differ from the base" >&2
  exit 1
fi
echo "branch_has_diff_from_base (real change) -> something to review: passed"

# 5. The run stops only when the branch was re-created AND the base already has
#    the work. A real change keeps the run going.
COMMIT_BRANCH_RECREATED="true"
if stop_when_base_has_the_work main 2>"${ROOT}/err.txt"; then
  echo "FAIL: a re-created branch with a real change must not stop the run" >&2
  exit 1
fi
git checkout -q main
if ! stop_when_base_has_the_work main 2>"${ROOT}/err.txt"; then
  echo "FAIL: a re-created branch identical to the base must stop the run" >&2
  exit 1
fi
grep -q "The implementation is already in main" "${ROOT}/err.txt" \
  || { echo "FAIL: the stop was not explained:" >&2; cat "${ROOT}/err.txt" >&2; exit 1; }
COMMIT_BRANCH_RECREATED="false"
if stop_when_base_has_the_work main 2>"${ROOT}/err.txt"; then
  echo "FAIL: an existing branch must never stop the run here" >&2
  exit 1
fi
COMMIT_BRANCH_RECREATED="true"
echo "stop_when_base_has_the_work (re-created branch, work already merged) -> stops: passed"

# 6. Fails open: no origin at all must not be read as "nothing to review".
git remote remove origin
if ! branch_has_diff_from_base main; then
  echo "FAIL: an unfetchable base must be treated as still having a diff" >&2
  exit 1
fi
if stop_when_base_has_the_work main 2>"${ROOT}/err.txt"; then
  echo "FAIL: an unfetchable base must not stop the run" >&2
  exit 1
fi
echo "branch_has_diff_from_base (no origin) -> fails open: passed"

echo "vanished-branch recovery passed"
