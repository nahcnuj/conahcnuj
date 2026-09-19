#!/usr/bin/env bash
# Mock test for get-token.sh (cache-hit path) and git-credential-helper.sh.
# Requires NO private key, NO app.env secrets, and NO network:
# - get-token.sh must return a cached token from a future-expiry token.cache
#   without attempting JWT signing (no openssl/curl/key needed).
# - git-credential-helper.sh must emit username/password for that cached token.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Stage a copy of the helper scripts so we never touch the real repo dir.
mkdir -p "${TMP}/gh-app"
cp "${HERE}/get-token.sh" "${TMP}/gh-app/"
cp "${HERE}/git-credential-helper.sh" "${TMP}/gh-app/"
# No app.env needed: cache-hit returns before reading key settings.

EXPIRES="$(( $(date +%s) + 3600 ))"   # 1h in the future
MOCK_TOKEN="ghs_mock-token-12345"
FUTURE_CACHE="${EXPIRES}|${MOCK_TOKEN}"
printf '%s' "${FUTURE_CACHE}" > "${TMP}/gh-app/token.cache"

# 1) get-token.sh cache-hit
OUT="$(bash "${TMP}/gh-app/get-token.sh")"
if [[ "${OUT}" != "${MOCK_TOKEN}" ]]; then
  echo "FAIL: cache-hit returned '${OUT}' expected '${MOCK_TOKEN}'" >&2
  exit 1
fi
echo "PASS get-token.sh cache-hit (no key/network)"

# 2) expired cache must NOT be returned (and should not re-sign without key;
#    absence of jq/openssl failures at least proves we fell through).
EXPIRED="$(( $(date +%s) - 10 ))|${MOCK_TOKEN}"
printf '%s' "${EXPIRED}" > "${TMP}/gh-app/token.cache"
EXPIRED_OUT="$(bash "${TMP}/gh-app/get-token.sh" 2>&1 || true)"
if [[ "${EXPIRED_OUT}" == *"${MOCK_TOKEN}"* ]]; then
  echo "FAIL: expired cache token was reused" >&2
  exit 1
fi
echo "PASS expired cache is rejected"

# 3) git-credential-helper.sh output format
printf '%s' "${FUTURE_CACHE}" > "${TMP}/gh-app/token.cache"
HELPER_OUT="$(printf 'protocol=https\nhost=github.com\n\n' | bash "${TMP}/gh-app/git-credential-helper.sh" get)"
if [[ "${HELPER_OUT}" != *"username=x-access-token"* ]]; then
  echo "FAIL: unexpected username in helper output" >&2
  echo "${HELPER_OUT}" >&2
  exit 1
fi
if [[ "${HELPER_OUT}" != *"password=${MOCK_TOKEN}"* ]]; then
  echo "FAIL: unexpected password in helper output" >&2
  echo "${HELPER_OUT}" >&2
  exit 1
fi
echo "PASS credential helper emits username/password for cached token"
echo "ALL MOCK TESTS PASSED"