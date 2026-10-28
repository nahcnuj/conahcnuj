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

set_key_path ""
OUT="$(bash "${STAGE}/get-token.sh" --print-jwt 2>&1 || true)"
if [[ "${OUT}" != *"PRIVATE_KEY_PATH is not set"* ]]; then
  echo "FAIL: empty PRIVATE_KEY_PATH should report missing config:" >&2
  echo "${OUT}" >&2
  exit 1
fi
echo "PASS empty PRIVATE_KEY_PATH reports missing config"

set_key_path "/tmp/nonexistent-conahcnuj-key-${$}.pem"
OUT="$(bash "${STAGE}/get-token.sh" --print-jwt 2>&1 || true)"
if [[ "${OUT}" != *"private key file not found"* ]]; then
  echo "FAIL: missing key file should report not found:" >&2
  echo "${OUT}" >&2
  exit 1
fi
echo "PASS missing key file reports not found"

EMPTY="$(mktemp)"
set_key_path "${EMPTY}"
OUT="$(bash "${STAGE}/get-token.sh" --print-jwt 2>&1 || true)"
if [[ "${OUT}" != *"private key file is empty"* ]]; then
  echo "FAIL: empty key file should report empty:" >&2
  echo "${OUT}" >&2
  exit 1
fi
echo "PASS empty key file reports empty"
rm -f "${EMPTY}"

BAD="$(mktemp)"
printf 'not-a-pem' > "${BAD}"
set_key_path "${BAD}"
OUT="$(bash "${STAGE}/get-token.sh" --print-jwt 2>&1 || true)"
if [[ "${OUT}" != *"failed to sign the App JWT"* ]]; then
  echo "FAIL: invalid key should report signing failure:" >&2
  echo "${OUT}" >&2
  exit 1
fi
echo "PASS invalid key reports signing failure"
rm -f "${BAD}"

# MSYS scenario (issue #588): file lives at /c/... but a WSL-style /mnt/c/...
# path is supplied via app.env. get-token.sh --print-pem-path must return the
# /c/... form (not report "private key not found").
MSYS_ROOT="/c/conahcnuj-gtpem-$$"
if ( mkdir -p "${MSYS_ROOT}/.ssh" 2>/dev/null ) || sudo mkdir -p "${MSYS_ROOT}/.ssh" 2>/dev/null; then
  if [[ ! -w "${MSYS_ROOT}/.ssh" ]]; then
    sudo chown "$(id -u):$(id -g)" "${MSYS_ROOT}" "${MSYS_ROOT}/.ssh" 2>/dev/null || true
  fi
  printf 'x' > "${MSYS_ROOT}/.ssh/key.pem" 2>/dev/null || sudo sh -c "printf x > '${MSYS_ROOT}/.ssh/key.pem'" 2>/dev/null || true
  if [[ -f "${MSYS_ROOT}/.ssh/key.pem" ]]; then
    sudo rm -rf "/mnt/c/conahcnuj-gtpem-$$" 2>/dev/null || rm -rf "/mnt/c/conahcnuj-gtpem-$$" 2>/dev/null || true
    set_key_path "/mnt/c/conahcnuj-gtpem-$$/.ssh/key.pem"
    GOT="$(bash "${STAGE}/get-token.sh" --print-pem-path)"
    if [[ "${GOT}" != "${MSYS_ROOT}/.ssh/key.pem" ]]; then
      echo "FAIL: MSYS /mnt path resolved to '${GOT}', expected '${MSYS_ROOT}/.ssh/key.pem'" >&2
      rm -rf "${MSYS_ROOT}" 2>/dev/null || sudo rm -rf "${MSYS_ROOT}" 2>/dev/null || true
      exit 1
    fi
    echo "PASS MSYS /mnt path rewrites to /c path (CLI)"
    rm -rf "${MSYS_ROOT}" 2>/dev/null || sudo rm -rf "${MSYS_ROOT}" 2>/dev/null || true
  else
    echo "SKIP MSYS scenario: could not create key file"
  fi
else
  echo "SKIP MSYS scenario: /c not writable"
fi
