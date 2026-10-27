#!/usr/bin/env bash
# driver_bash_exe / driver_needs_relaunch / driver_relaunch test (offline).
#
# On Windows, `bash conahcnuj <n>` from PowerShell can resolve to WSL bash,
# where the MSYS-style private key path (/c/Users/...) does not exist. The
# driver must re-launch itself under the configured Git Bash (BASH_EXE) so its
# helpers see the path space they were written for (issue #31). These tests
# cover the decision logic with wslpath mocked, and driver_relaunch itself:
# Git Bash runs as a child and an interrupt is forwarded to it, so Ctrl-C from
# PowerShell stops the run instead of looking ineffective (issue #203).
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

# --- driver_relaunch --------------------------------------------------------
# wslpath -u resolves the configured bash to this real bash; wslpath -m resolves
# the script to a dummy child so no Windows Git Bash is needed.
fake_env "C:/x/git-bash.exe"
WSLPATH_U_OUT="${BASH}"

# A child that records its arguments and exits 7: driver_relaunch must exit
# with the child's status and must not continue in the WSL shell (exec used to
# replace the process; now the shell waits for the child and exits with it).
CHILD="${ROOT}/child.sh"
cat > "${CHILD}" <<'EOF'
#!/usr/bin/env bash
printf 'args:%s\n' "$*" > "${DRIVER_RELAUNCH_MARKER}"
exit 7
EOF
chmod +x "${CHILD}"
WSLPATH_M_OUT="${CHILD}"
export DRIVER_RELAUNCH_MARKER="${ROOT}/normal.txt"
RC=0
( driver_relaunch alpha beta ) || RC=$?
[[ ${RC} -eq 7 ]] || { echo "FAIL: driver_relaunch exit ${RC} (expected the child's 7)" >&2; exit 1; }
grep -q 'args:alpha beta' "${DRIVER_RELAUNCH_MARKER}" || { echo "FAIL: child arguments were not passed through" >&2; exit 1; }
echo "driver_relaunch (child exit status + args) passed"

# A child that waits until it is signalled: an interrupt delivered to the WSL
# shell must be forwarded to it as TERM (an async child ignores SIGINT), so
# Ctrl-C reaches Git Bash and the run stops (issue #203).
CHILD="${ROOT}/waiting-child.sh"
cat > "${CHILD}" <<'EOF'
#!/usr/bin/env bash
trap 'printf "term\n" >> "${DRIVER_RELAUNCH_MARKER}"; exit 143' TERM
printf 'ready\n' > "${DRIVER_RELAUNCH_READY}"
sleep 30
EOF
chmod +x "${CHILD}"
WSLPATH_M_OUT="${CHILD}"
export DRIVER_RELAUNCH_READY="${ROOT}/ready.txt"
export DRIVER_RELAUNCH_MARKER="${ROOT}/signal.txt"
: > "${DRIVER_RELAUNCH_MARKER}"
rm -f "${DRIVER_RELAUNCH_READY}"
set -m
( driver_relaunch ) &
DRV=$!
set +m
i=0
while [[ ! -s "${DRIVER_RELAUNCH_READY}" && ${i} -lt 50 ]]; do sleep 0.1; i=$((i + 1)); done
[[ -s "${DRIVER_RELAUNCH_READY}" ]] || { echo "FAIL: relaunched child never started" >&2; exit 1; }
kill -INT "${DRV}"
RC=0
wait "${DRV}" || RC=$?
[[ ${RC} -eq 130 ]] || { echo "FAIL: driver_relaunch did not report the interrupt (exit ${RC})" >&2; exit 1; }
grep -q '^term$' "${DRIVER_RELAUNCH_MARKER}" || { echo "FAIL: the interrupt was not forwarded to the child" >&2; exit 1; }
echo "driver_relaunch (forwards SIGINT as TERM) passed"

echo "driver_relaunch tests passed"
