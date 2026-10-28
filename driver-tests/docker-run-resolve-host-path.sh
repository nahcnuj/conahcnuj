#!/usr/bin/env bash
# Unit tests for docker-run.sh's resolve_host_path (offline).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

export CONAHCNUJ_IMPORT=1
# shellcheck source=../docker-run.sh
. "${REPO}/docker-run.sh"

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT

REAL="${ROOT}/real.pem"
printf 'x' > "${REAL}"

# Existing path is returned unchanged.
GOT="$(resolve_host_path "${REAL}")"
[[ "${GOT}" == "${REAL}" ]] || { echo "FAIL: existing path '${REAL}' resolved to '${GOT}'" >&2; exit 1; }
echo "PASS existing path unchanged"

# Missing /mnt path is left unchanged.
GOT="$(resolve_host_path "/mnt/z/no-such-conahcnuj-key.pem")"
[[ "${GOT}" == "/mnt/z/no-such-conahcnuj-key.pem" ]] || { echo "FAIL: missing /mnt path resolved to '${GOT}'" >&2; exit 1; }
echo "PASS missing /mnt path unchanged"

# Backslash paths are normalized.
WIN="${ROOT}\\sub\\key.pem"
mkdir -p "${ROOT}/sub"
printf 'x' > "${ROOT}/sub/key.pem"
GOT="$(resolve_host_path "${WIN}")"
[[ "${GOT}" == "${ROOT}/sub/key.pem" ]] || { echo "FAIL: backslash path resolved to '${GOT}'" >&2; exit 1; }
echo "PASS backslash path normalized"

# Tilde expansion uses HOME.
HOME_BACKUP="${HOME}"
export HOME="${ROOT}/home"
mkdir -p "${HOME}/.ssh"
printf 'x' > "${HOME}/.ssh/key.pem"
GOT="$(resolve_host_path "~/.ssh/key.pem")"
[[ "${GOT}" == "${HOME}/.ssh/key.pem" ]] || { echo "FAIL: tilde path resolved to '${GOT}'" >&2; exit 1; }
export HOME="${HOME_BACKUP}"
echo "PASS tilde expansion"

# WSL /mnt path rewrites to Git Bash drive path when that file exists.
if command -v cygpath >/dev/null 2>&1; then
  MIXED="$(cygpath -m "${REAL}")"
  DRIVE="$(printf '%.1s' "${MIXED}" | tr '[:upper:]' '[:lower:]')"
  REST="${MIXED#?:/}"
  WSL_PATH="/mnt/${DRIVE}/${REST}"
  EXPECT="/${DRIVE}/${REST}"
  # Create the /drive-side file so the candidate exists.
  DRIVE_DIR="/${DRIVE}/$(dirname "${REST}")"
  mkdir -p "${DRIVE_DIR}" 2>/dev/null || true
  cp "${REAL}" "/${DRIVE}/${REST}" 2>/dev/null || true
  if [[ -f "/${DRIVE}/${REST}" ]]; then
    GOT="$(resolve_host_path "${WSL_PATH}")"
    [[ "${GOT}" == "${EXPECT}" ]] || { echo "FAIL: ${WSL_PATH} resolved to '${GOT}', expected '${EXPECT}'" >&2; exit 1; }
    echo "PASS WSL /mnt path rewrites to drive path"
    rm -f "/${DRIVE}/${REST}"
  else
    echo "SKIP /${DRIVE} not writable; WSL rewrite not tested"
  fi
fi

# CRLF in the path (Windows app.env) is stripped.
CRLF_INPUT="${REAL}"$'\r'
GOT="$(resolve_host_path "${CRLF_INPUT}")"
[[ "${GOT}" == "${REAL}" ]] || { echo "FAIL: CRLF path resolved to '${GOT}'" >&2; exit 1; }
echo "PASS CRLF path stripped"

# Surrounding double quotes are stripped.
GOT="$(resolve_host_path "\"${REAL}\"")"
[[ "${GOT}" == "${REAL}" ]] || { echo "FAIL: double-quoted path resolved to '${GOT}'" >&2; exit 1; }
echo "PASS double-quoted path stripped"

# Surrounding single quotes are stripped.
GOT="$(resolve_host_path "'${REAL}'")"
[[ "${GOT}" == "${REAL}" ]] || { echo "FAIL: single-quoted path resolved to '${GOT}'" >&2; exit 1; }
echo "PASS single-quoted path stripped"

# Missing cygdrive path is left unchanged.
GOT="$(resolve_host_path "/cygdrive/z/no-such-conahcnuj-key.pem")"
[[ "${GOT}" == "/cygdrive/z/no-such-conahcnuj-key.pem" ]] || { echo "FAIL: missing cygdrive path resolved to '${GOT}'" >&2; exit 1; }
echo "PASS missing cygdrive path unchanged"

# Missing Windows drive-letter path is left unchanged.
GOT="$(resolve_host_path "Z:/no-such-conahcnuj-key.pem")"
[[ "${GOT}" == "Z:/no-such-conahcnuj-key.pem" ]] || { echo "FAIL: missing drive-letter path resolved to '${GOT}'" >&2; exit 1; }
echo "PASS missing drive-letter path unchanged"

echo "All resolve_host_path tests passed"
