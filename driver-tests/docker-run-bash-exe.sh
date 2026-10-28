#!/usr/bin/env bash
# Unit tests for docker-run.sh's docker_bash_exe BASH_EXE parsing (offline).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT

APP_ENV="${ROOT}/app.env"
export CONAHCNUJ_IMPORT=1

# Helper: write an app.env with the given BASH_EXE assignment and return
# what docker_bash_exe resolves.
run_case() {
  local assignment="${1}"
  printf '%s\n' "${assignment}" > "${APP_ENV}"
  export CONAHCNUJ_APP_ENV="${APP_ENV}"
  # shellcheck source=../docker-run.sh
  . "${REPO}/docker-run.sh"
  docker_bash_exe
}

# Double-quoted BASH_EXE (with spaces) is parsed.
GOT="$(run_case 'BASH_EXE="C:/Program Files/Git/bin/bash.exe"')"
[[ "${GOT}" == "C:/Program Files/Git/bin/bash.exe" ]] || { echo "FAIL: double-quoted: got '${GOT}'" >&2; exit 1; }
echo "PASS double-quoted BASH_EXE"

# Single-quoted BASH_EXE (with spaces) is parsed.
GOT="$(run_case "BASH_EXE='C:/Program Files/Git/bin/bash.exe'")"
[[ "${GOT}" == "C:/Program Files/Git/bin/bash.exe" ]] || { echo "FAIL: single-quoted: got '${GOT}'" >&2; exit 1; }
echo "PASS single-quoted BASH_EXE"

# Unquoted BASH_EXE (no spaces) is parsed.
GOT="$(run_case 'BASH_EXE=C:/Git/bin/bash.exe')"
[[ "${GOT}" == "C:/Git/bin/bash.exe" ]] || { echo "FAIL: unquoted: got '${GOT}'" >&2; exit 1; }
echo "PASS unquoted BASH_EXE"

# CRLF line endings are tolerated.
printf 'BASH_EXE="C:/Program Files/Git/bin/bash.exe"\r\n' > "${APP_ENV}"
export CONAHCNUJ_APP_ENV="${APP_ENV}"
. "${REPO}/docker-run.sh"
GOT="$(docker_bash_exe)"
[[ "${GOT}" == "C:/Program Files/Git/bin/bash.exe" ]] || { echo "FAIL: CRLF: got '${GOT}'" >&2; exit 1; }
echo "PASS CRLF BASH_EXE"

# Placeholder value falls back to the default Git Bash path.
GOT="$(run_case 'BASH_EXE=<your-bash-exe>')"
[[ "${GOT}" == "C:/Program Files/Git/bin/bash.exe" ]] || { echo "FAIL: placeholder: got '${GOT}'" >&2; exit 1; }
echo "PASS placeholder falls back to default"

# Missing BASH_EXE falls back to the default Git Bash path.
GOT="$(run_case 'APP_ID=1')"
[[ "${GOT}" == "C:/Program Files/Git/bin/bash.exe" ]] || { echo "FAIL: missing: got '${GOT}'" >&2; exit 1; }
echo "PASS missing BASH_EXE falls back to default"

# BASH_EXE env var takes precedence over app.env.
export BASH_EXE="D:/custom/bash.exe"
GOT="$(run_case 'BASH_EXE="C:/Program Files/Git/bin/bash.exe"')"
[[ "${GOT}" == "D:/custom/bash.exe" ]] || { echo "FAIL: env override: got '${GOT}'" >&2; exit 1; }
unset BASH_EXE
echo "PASS BASH_EXE env var takes precedence"

echo "All docker_bash_exe tests passed"
