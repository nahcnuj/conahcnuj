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

# Trim surrounding whitespace (spaces and tabs).
WS_INPUT="   ${REAL}   "
GOT="$(resolve_host_path "${WS_INPUT}")"
[[ "${GOT}" == "${REAL}" ]] || { echo "FAIL: whitespace-padded path resolved to '${GOT}'" >&2; exit 1; }
echo "PASS surrounding whitespace trimmed"

# Nested quotes (more than one layer) are stripped.
GOT="$(resolve_host_path "\"'${REAL}'\"")"
[[ "${GOT}" == "${REAL}" ]] || { echo "FAIL: nested-quoted path resolved to '${GOT}'" >&2; exit 1; }
echo "PASS nested quotes stripped"

# Drive-letter root with no trailing path is tolerated.
GOT="$(resolve_host_path "Z:")"
[[ "${GOT}" == "Z:" ]] || { echo "FAIL: drive-letter root resolved to '${GOT}'" >&2; exit 1; }
echo "PASS drive-letter root tolerated"

# Missing drive-letter path with spaces survives (no crash).
GOT="$(resolve_host_path "Z:/no such file.pem")"
[[ "${GOT}" == "Z:/no such file.pem" ]] || { echo "FAIL: missing spaced drive path resolved to '${GOT}'" >&2; exit 1; }
echo "PASS missing spaced drive path unchanged"

# MSYS scenario (issue #588): file lives at /c/... but a WSL-style /mnt/c/...
# path is given. resolve_host_path must rewrite to the existing /c form instead
# of reporting "private key not found". Runs on Linux by creating /c when
# writable (sudo is available on GitHub runners); skipped otherwise.
MSYS_ROOT="/c/conahcnuj-test-$$"
if ( mkdir -p "${MSYS_ROOT}/.ssh" 2>/dev/null ) || sudo mkdir -p "${MSYS_ROOT}/.ssh" 2>/dev/null; then
  if [[ ! -w "${MSYS_ROOT}/.ssh" ]]; then
    sudo chown "$(id -u):$(id -g)" "${MSYS_ROOT}" "${MSYS_ROOT}/.ssh" 2>/dev/null || true
  fi
  printf 'x' > "${MSYS_ROOT}/.ssh/key.pem" 2>/dev/null || sudo sh -c "printf x > '${MSYS_ROOT}/.ssh/key.pem'" 2>/dev/null || true
  if [[ -f "${MSYS_ROOT}/.ssh/key.pem" ]]; then
    # Ensure the /mnt form does NOT exist so the conversion is exercised.
    sudo rm -rf "/mnt/c/conahcnuj-test-$$" 2>/dev/null || rm -rf "/mnt/c/conahcnuj-test-$$" 2>/dev/null || true
    GOT="$(resolve_host_path "/mnt/c/conahcnuj-test-$$/.ssh/key.pem")"
    [[ "${GOT}" == "${MSYS_ROOT}/.ssh/key.pem" ]] || { echo "FAIL: MSYS /mnt->/c rewrite resolved to '${GOT}'" >&2; exit 1; }
    echo "PASS MSYS /mnt path rewrites to /c path"
    rm -rf "${MSYS_ROOT}" 2>/dev/null || sudo rm -rf "${MSYS_ROOT}" 2>/dev/null || true
  else
    echo "SKIP MSYS scenario: could not create key file"
  fi
else
  echo "SKIP MSYS scenario: /c not writable"
fi

# /cygdrive path rewrites to an existing /<drive> form (MSYS).
if ( mkdir -p /c 2>/dev/null ) || sudo mkdir -p /c 2>/dev/null; then
  CYG_ROOT="/c/conahcnuj-cyg-$$"
  if ( mkdir -p "${CYG_ROOT}/.ssh" 2>/dev/null ) || sudo mkdir -p "${CYG_ROOT}/.ssh" 2>/dev/null; then
    if [[ ! -w "${CYG_ROOT}/.ssh" ]]; then
      sudo chown "$(id -u):$(id -g)" "${CYG_ROOT}" "${CYG_ROOT}/.ssh" 2>/dev/null || true
    fi
    printf 'x' > "${CYG_ROOT}/.ssh/key.pem" 2>/dev/null || sudo sh -c "printf x > '${CYG_ROOT}/.ssh/key.pem'" 2>/dev/null || true
    if [[ -f "${CYG_ROOT}/.ssh/key.pem" ]]; then
      GOT="$(resolve_host_path "/cygdrive/c/conahcnuj-cyg-$$/.ssh/key.pem")"
      [[ "${GOT}" == "${CYG_ROOT}/.ssh/key.pem" ]] || { echo "FAIL: cygdrive rewrite resolved to '${GOT}'" >&2; exit 1; }
      echo "PASS /cygdrive path rewrites to /c path"
      rm -rf "${CYG_ROOT}" 2>/dev/null || sudo rm -rf "${CYG_ROOT}" 2>/dev/null || true
    else
      echo "SKIP /cygdrive scenario: could not create key file"
    fi
  else
    echo "SKIP /cygdrive scenario: not writable"
  fi
else
  echo "SKIP /cygdrive scenario: /c not writable"
fi

# Drive-letter path rewrites to an existing /<drive> form.
DRV_ROOT="/c/conahcnuj-drv-$$"
if ( mkdir -p "${DRV_ROOT}/.ssh" 2>/dev/null ) || sudo mkdir -p "${DRV_ROOT}/.ssh" 2>/dev/null; then
  if [[ ! -w "${DRV_ROOT}/.ssh" ]]; then
    sudo chown "$(id -u):$(id -g)" "${DRV_ROOT}" "${DRV_ROOT}/.ssh" 2>/dev/null || true
  fi
  printf 'x' > "${DRV_ROOT}/.ssh/key.pem" 2>/dev/null || sudo sh -c "printf x > '${DRV_ROOT}/.ssh/key.pem'" 2>/dev/null || true
  if [[ -f "${DRV_ROOT}/.ssh/key.pem" ]]; then
    GOT="$(resolve_host_path "C:/conahcnuj-drv-$$/.ssh/key.pem")"
    [[ "${GOT}" == "${DRV_ROOT}/.ssh/key.pem" ]] || { echo "FAIL: drive-letter rewrite resolved to '${GOT}'" >&2; exit 1; }
    echo "PASS drive-letter path rewrites to /c path"
    rm -rf "${DRV_ROOT}" 2>/dev/null || sudo rm -rf "${DRV_ROOT}" 2>/dev/null || true
  else
    echo "SKIP drive-letter scenario: could not create key file"
  fi
else
  echo "SKIP drive-letter scenario: /c not writable"
fi

# Backslash (Windows) path is normalized and resolved.
BS_ROOT="/c/conahcnuj-bs-$$"
if ( mkdir -p "${BS_ROOT}/.ssh" 2>/dev/null ) || sudo mkdir -p "${BS_ROOT}/.ssh" 2>/dev/null; then
  if [[ ! -w "${BS_ROOT}/.ssh" ]]; then
    sudo chown "$(id -u):$(id -g)" "${BS_ROOT}" "${BS_ROOT}/.ssh" 2>/dev/null || true
  fi
  printf 'x' > "${BS_ROOT}/.ssh/key.pem" 2>/dev/null || sudo sh -c "printf x > '${BS_ROOT}/.ssh/key.pem'" 2>/dev/null || true
  if [[ -f "${BS_ROOT}/.ssh/key.pem" ]]; then
    GOT="$(resolve_host_path "C:\conahcnuj-bs-$$\.ssh\key.pem")"
    [[ "${GOT}" == "${BS_ROOT}/.ssh/key.pem" ]] || { echo "FAIL: backslash rewrite resolved to '${GOT}'" >&2; exit 1; }
    echo "PASS backslash Windows path resolves to /c path"
    rm -rf "${BS_ROOT}" 2>/dev/null || sudo rm -rf "${BS_ROOT}" 2>/dev/null || true
  else
    echo "SKIP backslash scenario: could not create key file"
  fi
else
  echo "SKIP backslash scenario: /c not writable"
fi

# Quoted path with internal spaces resolves when the file exists.
SPACE_DIR="${ROOT}/dir with space"
mkdir -p "${SPACE_DIR}"
SPACE_FILE="${SPACE_DIR}/key file.pem"
printf 'x' > "${SPACE_FILE}"
GOT="$(resolve_host_path "\"${SPACE_FILE}\"")"
[[ "${GOT}" == "${SPACE_FILE}" ]] || { echo "FAIL: quoted spaced path resolved to '${GOT}'" >&2; exit 1; }
echo "PASS quoted path with spaces resolves"

# Empty input resolves to empty (no crash).
GOT="$(resolve_host_path "")"
[[ "${GOT}" == "" ]] || { echo "FAIL: empty input resolved to '${GOT}'" >&2; exit 1; }
echo "PASS empty input tolerated"

# Combined: surrounding spaces + quotes + CRLF normalize to the existing path.
COMBINED="   \"${REAL}\"   "$'\r'
GOT="$(resolve_host_path "${COMBINED}")"
[[ "${GOT}" == "${REAL}" ]] || { echo "FAIL: combined input resolved to '${GOT}'" >&2; exit 1; }
echo "PASS combined whitespace/quote/CRLF normalized"

echo "All resolve_host_path tests passed"
