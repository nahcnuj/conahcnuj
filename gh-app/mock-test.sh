#!/usr/bin/env bash
# Mock tests for get-token.sh (cache lookup) and git-credential-helper.sh.
#
# These tests require NO private key, NO app.env secrets, and NO network:
# they exercise the token cache and credential-helper output formats using
# a fake token that never leaves this machine. This lets CI verify the
# App-flow on every PR without needing APP_ID / INSTALLATION_ID /
# PRIVATE_KEY / TEST_REPO secrets.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Stage a copy of the scripts we are testing, plus a minimalist app.env.
# The cache path returns before any JWT signing, so no real values are needed.
mkdir -p "${TMP}/gh-app"
cp "${HERE}/get-token.sh" "${TMP}/gh-app/"
cp "${HERE}/git-credential-helper.sh" "${TMP}/gh-app/"
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

echo "ALL MOCK TESTS PASSED"
