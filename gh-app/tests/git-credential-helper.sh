#!/usr/bin/env bash
# Credential helper emits username/password for the cached token.
# Usage: bash git-credential-helper.sh <staged gh-app dir>
set -euo pipefail

STAGE="${1:?staged gh-app dir required}"
MOCK_TOKEN="ghs_mock-token-12345"

EXPIRES="$(( $(date +%s) + 3600 ))"   # 1h ahead: still valid
printf '%s|%s' "${EXPIRES}" "${MOCK_TOKEN}" > "${STAGE}/token.cache"
HELPER_IN="protocol=https
host=github.com
"
HELPER_OUT="$(printf '%s' "${HELPER_IN}" | bash "${STAGE}/git-credential-helper.sh" get)"
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
