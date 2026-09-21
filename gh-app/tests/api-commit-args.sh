#!/usr/bin/env bash
# api-commit.sh argument validation. All cases exit before any token or
# network access, so no secrets are needed.
# Usage: bash api-commit-args.sh <staged gh-app dir>
set -euo pipefail

STAGE="${1:?staged gh-app dir required}"
APICOMMIT="${STAGE}/api-commit.sh"

FIXEMPTY="$(mktemp -d)"
trap 'rm -rf "${FIXEMPTY}"' EXIT
pushd "${FIXEMPTY}" >/dev/null || exit 1
git init -q
git config user.email "mock@test"
git config user.name "mock"
git config commit.gpgsign false
printf 'x\n' > x.txt
git add -A
git commit -qm init
# Staged mode with a clean index: nothing to commit (offline guard).
if bash "${APICOMMIT}" o/r b -m msg --dry-run >/dev/null 2>&1; then
  echo "FAIL: api-commit.sh with clean index should exit non-zero" >&2
  exit 1
fi
popd >/dev/null || exit 1
echo "PASS api-commit.sh rejects empty commit"

if bash "${APICOMMIT}" -m msg --file x=y >/dev/null 2>&1; then
  echo "FAIL: api-commit.sh with removed --file should exit non-zero" >&2
  exit 1
fi
echo "PASS api-commit.sh rejects removed --file"

if bash "${APICOMMIT}" -a >/dev/null 2>&1; then
  echo "FAIL: api-commit.sh without -m should exit non-zero" >&2
  exit 1
fi
echo "PASS api-commit.sh requires -m"

if bash "${APICOMMIT}" -m msg --bogus >/dev/null 2>&1; then
  echo "FAIL: api-commit.sh with unknown flag should exit non-zero" >&2
  exit 1
fi
echo "PASS api-commit.sh rejects unknown flag"
