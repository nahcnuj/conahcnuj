#!/usr/bin/env bash
# Regression: ensure_issue_branch must put ONLY the branch name on stdout.
#
# `git checkout -B <branch> <remote>/<branch>` prints "branch '<b>' set up to
# track ..." / local-change reports to stdout. The caller captures the
# function's stdout to get the branch name, so any leak turns it into a
# multi-line string and breaks PR creation. This exercises the real (non-test)
# code path against a local remote-tracking ref, so no network is needed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT
WORK="${ROOT}/repo"
mkdir -p "${WORK}"

git -C "${WORK}" init -q
git -C "${WORK}" config user.email "test@example.com"
git -C "${WORK}" config user.name "test"
git -C "${WORK}" config commit.gpgsign false
printf 'base\n' > "${WORK}/file.txt"
git -C "${WORK}" add -A
git -C "${WORK}" commit -qm init
git -C "${WORK}" branch -M main
oid="$(git -C "${WORK}" rev-parse HEAD)"

# A local bare repository as origin: the resume path fetches the branch first
# (a failed fetch must stop the run instead of falling back to a stale head),
# so a fabricated remote-tracking ref alone is not enough. Local path remote,
# so no network is needed.
ORIGIN="${ROOT}/origin.git"
git init -q --bare -b main "${ORIGIN}"
git -C "${WORK}" remote add origin "${ORIGIN}"
git -C "${WORK}" push -q origin "HEAD:refs/heads/main"
git -C "${WORK}" push -q origin "HEAD:refs/heads/conahcnuj/10-issue"

# A dirty tree makes git report local changes as well, which is part of what
# used to leak into stdout.
printf 'dirty\n' >> "${WORK}/file.txt"

cd "${WORK}" || exit 1
CONAHCNUJ_IMPORT=1
CONAHCNUJ_TEST_MODE=0
# shellcheck source=bin/conahcnuj.sh
. "${REPO}/bin/conahcnuj.sh"

out="$(ensure_issue_branch nahcnuj conahcnuj 10 "issue" main "${oid}" 2>"${ROOT}/err.txt")"
printf 'OUT=[%s]\n' "${out}"

if ! grep -q "resume" "${ROOT}/err.txt"; then
  echo "FAIL: expected the resume path (existing remote branch) to be taken" >&2
  exit 1
fi
if [[ "${out}" != "conahcnuj/10-issue" ]]; then
  echo "FAIL: ensure_issue_branch stdout is not a clean branch name" >&2
  exit 1
fi
if [[ "$(printf '%s' "${out}" | wc -l)" -ne 0 ]]; then
  echo "FAIL: ensure_issue_branch stdout contains embedded newlines" >&2
  exit 1
fi

echo "ensure_issue_branch stdout is clean: passed"
