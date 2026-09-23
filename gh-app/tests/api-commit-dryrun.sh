#!/usr/bin/env bash
# api-commit.sh --dry-run worktree collection. --dry-run exits before any
# token or network access; the fixture uses a fake origin URL that is never
# contacted. Covers: -a (modified, deleted, renamed; untracked excluded),
# staged mode, explicit --delete; owner/repo auto-detection.
# Usage: bash api-commit-dryrun.sh <staged gh-app dir>
set -euo pipefail

STAGE="${1:?staged gh-app dir required}"
APICOMMIT="${STAGE}/api-commit.sh"

FIX="$(mktemp -d)"
trap 'rm -rf "${FIX}" "${FIX2:-}"' EXIT
pushd "${FIX}" >/dev/null || exit 1
git init -q
git config user.email "mock@test"
git config user.name "mock"
git config commit.gpgsign false
printf 'base\n' > base.txt
printf 'del\n' > del.txt
printf 'mv\n' > old.txt
git add -A
git commit -qm init
printf 'mod\n' >> base.txt
printf 'new\n' > new.txt
git rm -q del.txt
git mv old.txt newname.txt
git remote add origin https://github.com/o/r.git
popd >/dev/null || exit 1

# -a collects tracked worktree changes like `git commit -a`, excluding untracked.
OUT5="$(cd "${FIX}" && bash "${APICOMMIT}" o/r b -m msg -a --dry-run)"
if [[ "${OUT5}" != *"Additions:  2 file(s)"* ]]; then
  echo "FAIL: -a additions mismatch:" >&2
  echo "${OUT5}" >&2
  exit 1
fi
if [[ "${OUT5}" != *"Deletions:  2 file(s)"* ]]; then
  echo "FAIL: -a deletions mismatch:" >&2
  echo "${OUT5}" >&2
  exit 1
fi
for f in base.txt newname.txt del.txt old.txt; do
  if [[ "${OUT5}" != *"${f}"* ]]; then
    echo "FAIL: -a missing ${f}:" >&2
    echo "${OUT5}" >&2
    exit 1
  fi
done
if printf '%s\n' "${OUT5}" | grep -qx '  new.txt'; then
  echo "FAIL: -a leaked untracked file:" >&2
  echo "${OUT5}" >&2
  exit 1
fi
echo "PASS api-commit.sh -a collects tracked only (git commit -a)"

# Single positional branch name: owner/repo auto-detected from git remote.
if OUT2="$(cd "${FIX}" && bash "${APICOMMIT}" somebranch -m msg -a --dry-run 2>&1)"; then
  :
else
  echo "FAIL: auto-detect run exited non-zero:" >&2
  echo "${OUT2}" >&2
  exit 1
fi
if [[ "${OUT2}" != *"Owner/Repo: o/r"* ]]; then
  echo "FAIL: auto-detect owner/repo mismatch:" >&2
  echo "${OUT2}" >&2
  exit 1
fi
echo "PASS api-commit.sh auto-detects owner/repo"

# Staged mode (no -a): only staged changes, content read from the index.
# idx.txt is staged then deleted from the worktree: collecting it proves the
# index (not worktree) is read. Unstaged/untracked files must be ignored.
FIX2="$(mktemp -d)"
pushd "${FIX2}" >/dev/null || exit 1
git init -q
git config user.email "mock@test"
git config user.name "mock"
git config commit.gpgsign false
printf 'keep\n' > keep.txt
git add -A
git commit -qm init
printf 'staged-change\n' > staged.txt
git add staged.txt
printf 'indexed\n' > idx.txt
git add idx.txt
rm idx.txt
printf 'unstaged\n' >> keep.txt
printf 'untracked\n' > untracked.txt
git remote add origin https://github.com/o/r2.git
popd >/dev/null || exit 1
OUT4="$(cd "${FIX2}" && bash "${APICOMMIT}" o/r b -m msg --dry-run)"
if [[ "${OUT4}" != *"Additions:  2 file(s)"* ]]; then
  echo "FAIL: staged additions mismatch:" >&2
  echo "${OUT4}" >&2
  exit 1
fi
for f in staged.txt idx.txt; do
  if [[ "${OUT4}" != *"${f}"* ]]; then
    echo "FAIL: staged missing addition ${f}:" >&2
    echo "${OUT4}" >&2
    exit 1
  fi
done
if [[ "${OUT4}" != *"Deletions:  0 file(s)"* ]]; then
  echo "FAIL: staged deletions mismatch:" >&2
  echo "${OUT4}" >&2
  exit 1
fi
for f in keep.txt untracked.txt; do
  if printf '%s\n' "${OUT4}" | grep -qx "  ${f}"; then
    echo "FAIL: staged leaked worktree file ${f}:" >&2
    echo "${OUT4}" >&2
    exit 1
  fi
done
rm -rf "${FIX2}"
echo "PASS api-commit.sh staged mode collects index only"

# Explicit --delete without a collection flag.
OUT3="$(cd "${FIX}" && bash "${APICOMMIT}" o/r b -m msg --delete gone.txt --dry-run)"
if [[ "${OUT3}" != *"Additions:  0 file(s)"* ]]; then
  echo "FAIL: --dry-run additions mismatch:" >&2
  echo "${OUT3}" >&2
  exit 1
fi
if [[ "${OUT3}" != *"Deletions:  1 file(s)"* || "${OUT3}" != *"gone.txt"* ]]; then
  echo "FAIL: --dry-run --delete mismatch:" >&2
  echo "${OUT3}" >&2
  exit 1
fi
echo "PASS api-commit.sh --dry-run --delete"
