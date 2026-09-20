#!/usr/bin/env bash
# api-commit.sh argument validation. All cases exit before any token or
# network access, so no secrets are needed.
# Usage: bash api-commit-args.sh <staged gh-app dir>
set -euo pipefail

STAGE="${1:?staged gh-app dir required}"
APICOMMIT="${STAGE}/api-commit.sh"

FIXEMPTY="$(mktemp -d)"
git -C "${FIXEMPTY}" init -q
git -C "${FIXEMPTY}" config user.email "mock@test"
git -C "${FIXEMPTY}" config user.name "mock"
printf 'x\n' > "${FIXEMPTY}/x.txt"
git -C "${FIXEMPTY}" add -A
git -C "${FIXEMPTY}" commit -qm init
# Staged mode with a clean index: nothing to commit (offline guard).
if ( cd "${FIXEMPTY}" && bash "${APICOMMIT}" o/r b -m msg --dry-run >/dev/null 2>&1 ); then
  echo "FAIL: api-commit.sh with clean index should exit non-zero" >&2
  rm -rf "${FIXEMPTY}"
  exit 1
fi
rm -rf "${FIXEMPTY}"
echo "PASS api-commit.sh rejects empty commit"

if bash "${APICOMMIT}" -m msg -a --file x=y >/dev/null 2>&1; then
  echo "FAIL: api-commit.sh -a with --file should exit non-zero" >&2
  exit 1
fi
echo "PASS api-commit.sh rejects -a with --file"

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

if bash "${APICOMMIT}" o/r b -m msg --file x=@/tmp/nonexistent-mock-file >/dev/null 2>&1; then
  echo "FAIL: api-commit.sh with missing @file should exit non-zero" >&2
  exit 1
fi
echo "PASS api-commit.sh rejects missing @file"
