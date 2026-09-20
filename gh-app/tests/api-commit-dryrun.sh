#!/usr/bin/env bash
# api-commit.sh --dry-run worktree collection. --dry-run exits before any
# token or network access; the fixture uses a fake origin URL that is never
# contacted. Covers: -a (modified, deleted, renamed; untracked excluded),
# staged mode, explicit --file/--delete; owner/repo auto-detection.
# Usage: bash api-commit-dryrun.sh <staged gh-app dir>
set -euo pipefail

STAGE="${1:?staged gh-app dir required}"
APICOMMIT="${STAGE}/api-commit.sh"

FIX="$(mktemp -d)"
trap 'rm -rf "${FIX}"' EXIT
git -C "${FIX}" init -q
git -C "${FIX}" config user.email "mock@test"
git -C "${FIX}" config user.name "mock"
printf 'base\n' > "${FIX}/base.txt"
printf 'del\n' > "${FIX}/del.txt"
printf 'mv\n' > "${FIX}/old.txt"
git -C "${FIX}" add -A
git -C "${FIX}" commit -qm init
printf 'mod\n' >> "${FIX}/base.txt"
printf 'new\n' > "${FIX}/new.txt"
git -C "${FIX}" rm -q del.txt
git -C "${FIX}" mv old.txt newname.txt
git -C "${FIX}" remote add origin https://github.com/o/r.git

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
git -C "${FIX2}" init -q
git -C "${FIX2}" config user.email "mock@test"
git -C "${FIX2}" config user.name "mock"
printf 'keep\n' > "${FIX2}/keep.txt"
git -C "${FIX2}" add -A
git -C "${FIX2}" commit -qm init
printf 'staged-change\n' > "${FIX2}/staged.txt"
git -C "${FIX2}" add staged.txt
printf 'indexed\n' > "${FIX2}/idx.txt"
git -C "${FIX2}" add idx.txt
rm "${FIX2}/idx.txt"
printf 'unstaged\n' >> "${FIX2}/keep.txt"
printf 'untracked\n' > "${FIX2}/untracked.txt"
git -C "${FIX2}" remote add origin https://github.com/o/r2.git
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

# Explicit --file/--delete without --all.
OUT3="$(cd "${FIX}" && bash "${APICOMMIT}" o/r b -m msg --file inline.txt=hello --delete gone.txt --dry-run)"
if [[ "${OUT3}" != *"Additions:  1 file(s)"* || "${OUT3}" != *"inline.txt"* ]]; then
  echo "FAIL: --dry-run --file mismatch:" >&2
  echo "${OUT3}" >&2
  exit 1
fi
if [[ "${OUT3}" != *"Deletions:  1 file(s)"* || "${OUT3}" != *"gone.txt"* ]]; then
  echo "FAIL: --dry-run --delete mismatch:" >&2
  echo "${OUT3}" >&2
  exit 1
fi
echo "PASS api-commit.sh --dry-run --file/--delete"
