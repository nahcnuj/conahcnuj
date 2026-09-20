#!/usr/bin/env bash
# Mock tests for get-token.sh (cache lookup), git-credential-helper.sh,
# and api-commit.sh (arg validation + --dry-run worktree collection).
#
# These tests require NO private key, NO app.env secrets, and NO network:
# they exercise the token cache and credential-helper output formats using
# a fake token that never leaves this machine, plus api-commit.sh paths
# that never reach the network (--dry-run exits before any token/API call).
# This lets CI verify the App-flow on every PR without needing APP_ID /
# INSTALLATION_ID / PRIVATE_KEY / TEST_REPO secrets.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Stage a copy of the scripts we are testing, plus a minimalist app.env.
# The cache path returns before any JWT signing, so no real values are needed.
mkdir -p "${TMP}/gh-app"
cp "${HERE}/get-token.sh" "${TMP}/gh-app/"
cp "${HERE}/git-credential-helper.sh" "${TMP}/gh-app/"
cp "${HERE}/api-commit.sh" "${TMP}/gh-app/"
APICOMMIT="${TMP}/gh-app/api-commit.sh"
cat > "${TMP}/gh-app/app.env" <<'EOF'
APP_ID=00000
INSTALLATION_ID=00000
APP_SLUG=conahcnuj
PRIVATE_KEY_PATH=/tmp/nonexistent.pem
BASH_EXE="C:/Program Files/Git/bin/bash.exe"
EOF

EXPIRES="$(( $(date +%s) + 3600 ))"   # 1h ahead: still valid
MOCK_TOKEN="ghs_mock-token-12345"
FUTURE_CACHE="${EXPIRES}|${MOCK_TOKEN}"
printf '%s' "${FUTURE_CACHE}" > "${TMP}/gh-app/token.cache"

# 1) Fresh cache -> returned without signing (no key/openssl/network).
OUT="$(bash "${TMP}/gh-app/get-token.sh")"
if [[ "${OUT}" != "${MOCK_TOKEN}" ]]; then
  echo "FAIL: cache-hit returned '${OUT}', expected '${MOCK_TOKEN}'" >&2
  exit 1
fi
echo "PASS get-token.sh cache-hit (no key / no network)"

# 2) Expired cache must NOT be reused. With no key this path cannot sign a
#    JWT, but we only assert it does not silently hand back the stale token.
EXPIRED="$(( $(date +%s) - 3600 ))|${MOCK_TOKEN}"
printf '%s' "${EXPIRED}" > "${TMP}/gh-app/token.cache"
OUT="$(bash "${TMP}/gh-app/get-token.sh" 2>&1 || true)"
if [[ "${OUT}" == *"${MOCK_TOKEN}"* ]]; then
  echo "FAIL: expired cache token was reused" >&2
  exit 1
fi
echo "PASS expired cache is rejected"

# 3) Credential helper emits username/password for the cached token.
printf '%s' "${FUTURE_CACHE}" > "${TMP}/gh-app/token.cache"
HELPER_IN="protocol=https
host=github.com
"
HELPER_OUT="$(printf '%s' "${HELPER_IN}" | bash "${TMP}/gh-app/git-credential-helper.sh" get)"
if [[ "${HELPER_OUT}" != *"username=x-access-token"* ]]; then
  echo "FAIL: missing 'username=x-access-token' in helper output" >&2
  echo "${HELPER_OUT}" >&2
  exit 1
fi
if [[ "${HELPER_OUT}" != *"password=${MOCK_TOKEN}"* ]]; then
  echo "FAIL: missing 'password=' in helper output" >&2
  echo "${HELPER_OUT}" >&2
  exit 1
fi
echo "PASS credential-helper outputs username/password for cached token"

# 4) api-commit.sh arg validation fails before any network access.
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

# 5) api-commit.sh --dry-run collects worktree changes without network.
#    Fixture: modified + untracked + deleted + renamed files.
FIX="${TMP}/fixture"
mkdir -p "${FIX}"
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
OUT="$(cd "${FIX}" && bash "${APICOMMIT}" o/r b -m msg --all --dry-run)"
if [[ "${OUT}" != *"Additions:  3 file(s)"* ]]; then
  echo "FAIL: --dry-run additions mismatch:" >&2
  echo "${OUT}" >&2
  exit 1
fi
for f in base.txt new.txt newname.txt; do
  if [[ "${OUT}" != *"${f}"* ]]; then
    echo "FAIL: --dry-run missing addition ${f}:" >&2
    echo "${OUT}" >&2
    exit 1
  fi
done
if [[ "${OUT}" != *"Deletions:  2 file(s)"* ]]; then
  echo "FAIL: --dry-run deletions mismatch:" >&2
  echo "${OUT}" >&2
  exit 1
fi
for f in del.txt old.txt; do
  if [[ "${OUT}" != *"${f}"* ]]; then
    echo "FAIL: --dry-run missing deletion ${f}:" >&2
    echo "${OUT}" >&2
    exit 1
  fi
done
echo "PASS api-commit.sh --dry-run --all collects modify/add/delete/rename"

# 6) api-commit.sh --dry-run auto-detects owner/repo from git remote.
OUT2="$(cd "${FIX}" && bash "${APICOMMIT}" somebranch -m msg --all --dry-run 2>&1 || true)"
if [[ "${OUT2}" != *"Owner/Repo: o/r"* ]]; then
  echo "FAIL: auto-detect owner/repo mismatch:" >&2
  echo "${OUT2}" >&2
  exit 1
fi
echo "PASS api-commit.sh auto-detects owner/repo"

# 7) api-commit.sh --dry-run with explicit --file/--delete (no --all).
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

echo "ALL MOCK TESTS PASSED"
