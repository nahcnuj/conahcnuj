#!/usr/bin/env bash
# driver_bash_exe / driver_needs_relaunch test (offline).
#
# On Windows, `bash conahcnuj <n>` from PowerShell can resolve to WSL bash,
# where the MSYS-style private key path (/c/Users/...) does not exist. The
# driver must re-launch itself under the configured Git Bash (BASH_EXE) so its
# helpers see the path space they were written for (issue #31). These tests
# cover the decision logic without ever exec'ing (wslpath is mocked).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

export CONAHCNUJ_IMPORT=1
# shellcheck source=bin/conahcnuj.sh
. "${REPO}/bin/conahcnuj.sh"

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT

# Isolated gh-app env so the tests are host-independent.
export GH_APP_DIR="${ROOT}/gh-app"
mkdir -p "${GH_APP_DIR}"
fake_env() {
  printf 'BASH_EXE="%s"\n' "${1:-}" > "${GH_APP_DIR}/app.env"
}

# The dummy Git Bash the mock wslpath resolves to.
DUMMY_BASH="${ROOT}/dummy-bash"
printf '#!/bin/sh\nexit 0\n' > "${DUMMY_BASH}"
chmod +x "${DUMMY_BASH}"

# Mock wslpath: translate the configured Windows bash to a reachable path.
mock_wslpath() {
  case "${1}" in
    -u) printf '%s\n' "${WSLPATH_U_OUT:-}" ;;
    -m) printf '%s\n' "${WSLPATH_M_OUT:-}" ;;
  esac
}

# Clean baseline (never actually running under Git Bash / WSL here).
unset MSYSTEM WSL_DISTRO_NAME BASH_EXE 2>/dev/null || true
unset -f wslpath 2>/dev/null || true

# --- driver_bash_exe --------------------------------------------------------

out="$(BASH_EXE="/foo/custom-bash.exe" driver_bash_exe)"
[[ "${out}" == "/foo/custom-bash.exe" ]] || { echo "FAIL: env override expected /foo/custom-bash.exe, got ${out}" >&2; exit 1; }
echo "driver_bash_exe (env override) passed"

fake_env "C:/custom/git-bash.exe"
out="$(driver_bash_exe)"
[[ "${out}" == "C:/custom/git-bash.exe" ]] || { echo "FAIL: expected app.env value, got ${out}" >&2; exit 1; }
echo "driver_bash_exe (app.env) passed"

fake_env "<your-bash-exe>"
out="$(driver_bash_exe)"
[[ "${out}" == "C:/Program Files/Git/bin/bash.exe" ]] || { echo "FAIL: placeholder must fall back to Git for Windows, got ${out}" >&2; exit 1; }
echo "driver_bash_exe (placeholder -> default) passed"

rm -f "${GH_APP_DIR}/app.env"
out="$(driver_bash_exe)"
[[ "${out}" == "C:/Program Files/Git/bin/bash.exe" ]] || { echo "FAIL: example fallback expected default, got ${out}" >&2; exit 1; }
echo "driver_bash_exe (example fallback) passed"

# --- driver_needs_relaunch --------------------------------------------------

# Already Git Bash: never relaunch.
if MSYSTEM=MINGW64 driver_needs_relaunch; then
  echo "FAIL: must not relaunch from Git Bash" >&2; exit 1
fi
echo "driver_needs_relaunch (Git Bash) -> no passed"

# Not under WSL: never relaunch.
if driver_needs_relaunch; then
  echo "FAIL: must not relaunch outside WSL" >&2; exit 1
fi
echo "driver_needs_relaunch (non-WSL) -> no passed"

# Under WSL but no wslpath available: cannot relaunch.
if WSL_DISTRO_NAME=Ubuntu-24.04 driver_needs_relaunch; then
  echo "FAIL: must not relaunch without wslpath" >&2; exit 1
fi
echo "driver_needs_relaunch (WSL, no wslpath) -> no passed"

# Under WSL with a reachable Git Bash: relaunch.
wslpath() { mock_wslpath "$@"; }
WSLPATH_U_OUT="${DUMMY_BASH}"
if ! WSL_DISTRO_NAME=Ubuntu-24.04 driver_needs_relaunch; then
  echo "FAIL: must relaunch when BASH_EXE is reachable from WSL" >&2; exit 1
fi
echo "driver_needs_relaunch (WSL, reachable bash) -> yes passed"

# Under WSL but the configured bash is unreachable: no relaunch.
WSLPATH_U_OUT="${ROOT}/does-not-exist"
if WSL_DISTRO_NAME=Ubuntu-24.04 driver_needs_relaunch; then
  echo "FAIL: must not relaunch when BASH_EXE is unreachable" >&2; exit 1
fi
echo "driver_needs_relaunch (WSL, unreachable bash) -> no passed"

echo "driver_relaunch tests passed"