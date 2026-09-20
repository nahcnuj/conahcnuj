#!/usr/bin/env bash
# api-commit.sh argument validation. All cases exit before any token or
# network access, so no secrets are needed.
# Usage: bash api-commit-args.sh <staged gh-app dir>
set -euo pipefail

STAGE="${1:?staged gh-app dir required}"
APICOMMIT="${STAGE}/api-commit.sh"

if bash "${APICOMMIT}" o/r b -m msg >/dev/null 2>&1; then
  echo "FAIL: api-commit.sh without files should exit non-zero" >&2
  exit 1
fi
echo "PASS api-commit.sh rejects empty commit"

if bash "${APICOMMIT}" -m msg --all --file x=y >/dev/null 2>&1; then
  echo "FAIL: api-commit.sh --all with --file should exit non-zero" >&2
  exit 1
fi
echo "PASS api-commit.sh rejects --all with --file"

if bash "${APICOMMIT}" --all >/dev/null 2>&1; then
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
