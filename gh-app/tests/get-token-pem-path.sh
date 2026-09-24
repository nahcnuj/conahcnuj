#!/usr/bin/env bash
# Private-key path: keep a path that exists, and rewrite a missing WSL
# /mnt/<drive>/ path to the Git Bash /<drive>/ path when that file exists.
# Usage: bash get-token-pem-path.sh <staged gh-app dir>
set -euo pipefail

STAGE="${1:?staged gh-app dir required}"
ENV_FILE="${STAGE}/app.env"
ENV_BACKUP="$(mktemp)"
cp "${ENV_FILE}" "${ENV_BACKUP}"

set_key_path() {
  local key_path="${1}"
  awk -v path="${key_path}" '
    BEGIN { replaced = 0 }
    /^PRIVATE_KEY_PATH=/ { print "PRIVATE_KEY_PATH=" path; replaced = 1; next }
    { print }
    END { if (!replaced) print "PRIVATE_KEY_PATH=" path }
  ' "${ENV_BACKUP}" > "${ENV_FILE}"
}

cleanup() {
  cp "${ENV_BACKUP}" "${ENV_FILE}"
  rm -f "${ENV_BACKUP}"
}
trap cleanup EXIT

REAL="$(mktemp)"
printf 'x' > "${REAL}"

set_key_path "${REAL}"
GOT="$(bash "${STAGE}/get-token.sh" --print-pem-path)"
if [[ "${GOT}" != "${REAL}" ]]; then
  echo "FAIL: existing path '${REAL}' resolved to '${GOT}'" >&2
  exit 1
fi
echo "PASS existing private-key path is unchanged"

set_key_path "/mnt/z/no-such-conahcnuj-key.pem"
GOT="$(bash "${STAGE}/get-token.sh" --print-pem-path)"
if [[ "${GOT}" != "/mnt/z/no-such-conahcnuj-key.pem" ]]; then
  echo "FAIL: missing path resolved to '${GOT}'" >&2
  exit 1
fi
echo "PASS missing /mnt path is left unchanged"

if command -v cygpath >/dev/null 2>&1; then
  MIXED="$(cygpath -m "${REAL}")"
  DRIVE="$(printf '%.1s' "${MIXED}" | tr '[:upper:]' '[:lower:]')"
  REST="${MIXED#?:/}"
  WSL_PATH="/mnt/${DRIVE}/${REST}"
  EXPECT="/${DRIVE}/${REST}"
  set_key_path "${WSL_PATH}"
  GOT="$(bash "${STAGE}/get-token.sh" --print-pem-path)"
  if [[ "${GOT}" != "${EXPECT}" ]]; then
    echo "FAIL: ${WSL_PATH} resolved to '${GOT}', expected '${EXPECT}'" >&2
    exit 1
  fi
  echo "PASS WSL /mnt path rewrites to Git Bash drive path"
fi

rm -f "${REAL}"
