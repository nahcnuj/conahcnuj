#!/usr/bin/env bash
# Token-cache behavior: fresh cache hit (no key/network), expired rejected.
# Usage: bash get-token-cache.sh <staged gh-app dir>
set -euo pipefail

STAGE="${1:?staged gh-app dir required}"
MOCK_TOKEN="ghs_mock-token-12345"

# Fresh cache -> returned without signing (no key/openssl/network).
EXPIRES="$(( $(date +%s) + 3600 ))"   # 1h ahead: still valid
printf '%s|%s' "${EXPIRES}" "${MOCK_TOKEN}" > "${STAGE}/token.cache"
OUT="$(bash "${STAGE}/get-token.sh")"
if [[ "${OUT}" != "${MOCK_TOKEN}" ]]; then
  echo "FAIL: cache-hit returned '${OUT}', expected '${MOCK_TOKEN}'" >&2
  exit 1
fi
echo "PASS get-token.sh cache-hit (no key / no network)"

# Expired cache must NOT be reused. With no key this path cannot sign a
# JWT, but we only assert it does not silently hand back the stale token.
EXPIRED="$(( $(date +%s) - 3600 ))"
printf '%s|%s' "${EXPIRED}" "${MOCK_TOKEN}" > "${STAGE}/token.cache"
OUT="$(bash "${STAGE}/get-token.sh" 2>&1 || true)"
if [[ "${OUT}" == *"${MOCK_TOKEN}"* ]]; then
  echo "FAIL: expired cache token was reused" >&2
  exit 1
fi
echo "PASS expired cache is rejected"
