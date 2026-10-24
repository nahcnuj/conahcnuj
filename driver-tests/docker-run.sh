#!/usr/bin/env bash
# docker-run.sh test (offline: docker and wslpath are mocked).
#
# Regression for issue #417: on Windows, a bare `bash` from PowerShell resolves
# to WSL bash, where `docker` only knows unix:///var/run/docker.sock and cannot
# reach Docker Desktop even though `docker ps` works in PowerShell. The wrapper
# must re-launch itself under the configured Git Bash (BASH_EXE) and pass the
# target repo through as a Windows path. These tests also pin the normal
# (non-WSL) argument building so the relaunch does not change it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
WRAPPER="${REPO}/docker-run.sh"

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT

MOCKBIN="${ROOT}/bin"
mkdir -p "${MOCKBIN}"

# Mock docker: record every invocation and succeed. `info`/`image inspect`
# succeed so the wrapper skips the build step.
cat > "${MOCKBIN}/docker" <<'EOF'
#!/usr/bin/env bash
{
  printf 'docker'
  for a in "$@"; do printf ' <%s>' "$a"; done
  printf '\n'
} >> "${DOCKER_LOG}"
exit 0
EOF
chmod +x "${MOCKBIN}/docker"

# Mock wslpath: -u resolves the configured Git Bash, -m prefixes Windows-form
# paths with W so the test can assert that the target was converted. It must be
# a script on PATH, not an exported shell function: the wrapper calls it from a
# child `bash`, and on Git Bash (MSYS) exported functions travel as environment
# variables whose names contain `%`, which Windows drops, so `command -v
# wslpath` would not see the mock and the relaunch would be skipped (Windows CI
# only; Linux passed with the function).
cat > "${MOCKBIN}/wslpath" <<'EOF'
#!/usr/bin/env bash
case "${1}" in
  -u) printf '%s\n' "${WSLPATH_U_OUT}" ;;
  -m) printf 'W%s\n' "${2}" ;;
esac
EOF
chmod +x "${MOCKBIN}/wslpath"

# The "Git Bash" the relaunch runs: record its arguments and the forwarded
# environment, then exit.
GITBASH="${ROOT}/fake-git-bash"
cat > "${GITBASH}" <<'EOF'
#!/usr/bin/env bash
printf 'args' > "${GITBASH_LOG}"
for a in "$@"; do printf ' <%s>' "$a" >> "${GITBASH_LOG}"; done
printf '\nTARGET=<%s>\n' "${CONAHCNUJ_TARGET:-}" >> "${GITBASH_LOG}"
exit 0
EOF
chmod +x "${GITBASH}"

# A throwaway git work tree and a private key that only has to exist.
TARGET_REPO="${ROOT}/target"
git init -q "${TARGET_REPO}"
PEM="${ROOT}/app.pem"
printf 'dummy\n' > "${PEM}"
APP_ENV="${ROOT}/app.env"
cat > "${APP_ENV}" <<EOF
APP_ID="1"
INSTALLATION_ID="2"
APP_SLUG="conahcnuj"
PRIVATE_KEY_PATH="${PEM}"
BASH_EXE="C:/Program Files/Git/bin/bash.exe"
EOF

export PATH="${MOCKBIN}:${PATH}"
export OPENCODE_CONFIG_DIR="${ROOT}/no-config"
export OPENCODE_DATA_DIR="${ROOT}/no-data"

# Run the wrapper with a clean WSL/Git Bash baseline plus the given overrides.
# Use the shell's `unset` rather than `env -u`: on Git Bash `env` does not
# reliably clear MSYSTEM for the child, which made the simulated WSL run look
# like it was already running under Git Bash and skip the relaunch (Windows
# CI only; Linux passed). Exported variables are inherited by the wrapper.
run_wrapper() {
  local assignment
  (
    unset MSYSTEM WSL_DISTRO_NAME BASH_EXE
    export CONAHCNUJ_IMAGE=test-image
    export CONAHCNUJ_TARGET="${TARGET_REPO}"
    export CONAHCNUJ_APP_ENV="${APP_ENV}"
    export DOCKER_LOG GITBASH_LOG
    export WSLPATH_U_OUT="${GITBASH}"
    for assignment in "$@"; do
      # shellcheck disable=SC2163  # the value is a NAME=VALUE assignment
      export "${assignment}"
    done
    bash "${WRAPPER_PATH:-${WRAPPER}}" 42
  )
}

# --- normal (non-WSL) run ---------------------------------------------------
DOCKER_LOG="${ROOT}/docker-normal.log"
GITBASH_LOG="${ROOT}/gitbash-normal.log"
: > "${DOCKER_LOG}"
: > "${GITBASH_LOG}"
run_wrapper >/dev/null 2>&1

grep -q '^docker <info>' "${DOCKER_LOG}" || { echo "FAIL: docker info was not checked" >&2; exit 1; }
grep -q '<run>.*<--rm>' "${DOCKER_LOG}" || { echo "FAIL: docker run --rm was not invoked" >&2; exit 1; }
grep -q '<test-image> <42>' "${DOCKER_LOG}" || { echo "FAIL: image + issue number were not passed" >&2; exit 1; }
grep -q '<-w> </work>' "${DOCKER_LOG}" || { echo "FAIL: container workdir /work missing" >&2; exit 1; }
grep -q ':/work>' "${DOCKER_LOG}" || { echo "FAIL: target repo was not mounted at /work" >&2; exit 1; }
grep -q ':/opt/conahcnuj/gh-app/app.env:ro>' "${DOCKER_LOG}" || { echo "FAIL: container app.env was not mounted" >&2; exit 1; }
grep -q ':/run/secrets/app.pem:ro>' "${DOCKER_LOG}" || { echo "FAIL: private key was not mounted" >&2; exit 1; }
[[ ! -s "${GITBASH_LOG}" ]] || { echo "FAIL: no relaunch expected outside WSL" >&2; exit 1; }
echo "docker-run.sh (non-WSL) passed"

# --- WSL with a reachable Git Bash: relaunch -------------------------------
DOCKER_LOG="${ROOT}/docker-wsl.log"
GITBASH_LOG="${ROOT}/gitbash-wsl.log"
: > "${DOCKER_LOG}"
: > "${GITBASH_LOG}"
run_wrapper WSL_DISTRO_NAME=Ubuntu-24.04 BASH_EXE='C:/Program Files/Git/bin/bash.exe' >/dev/null 2>&1

[[ -s "${GITBASH_LOG}" ]] || { echo "FAIL: WSL run did not re-launch under Git Bash" >&2; exit 1; }
grep -q '<42>' "${GITBASH_LOG}" || { echo "FAIL: issue number not passed to the relaunch" >&2; exit 1; }
grep -q 'docker-run\.sh>' "${GITBASH_LOG}" || { echo "FAIL: wrapper script not passed to the relaunch" >&2; exit 1; }
grep -q 'TARGET=<W' "${GITBASH_LOG}" || { echo "FAIL: target repo was not converted to a Windows path" >&2; exit 1; }
[[ ! -s "${DOCKER_LOG}" ]] || { echo "FAIL: WSL shell must not call the WSL docker before relaunching" >&2; exit 1; }
echo "docker-run.sh (WSL -> Git Bash relaunch) passed"

# --- WSL invoked via a relative script path: resolve it before conversion ----
# Regression for the reported `bash ../conahcnuj/docker-run.sh` invocation: a
# relative BASH_SOURCE[0] cannot be converted by wslpath, so the wrapper must
# make it absolute first or Docker Desktop is still unreachable.
DOCKER_LOG="${ROOT}/docker-relative.log"
GITBASH_LOG="${ROOT}/gitbash-relative.log"
: > "${DOCKER_LOG}"
: > "${GITBASH_LOG}"
( cd "${REPO}" && WRAPPER_PATH="./docker-run.sh" run_wrapper \
    WSL_DISTRO_NAME=Ubuntu-24.04 BASH_EXE='C:/Program Files/Git/bin/bash.exe' ) >/dev/null 2>&1

[[ -s "${GITBASH_LOG}" ]] || { echo "FAIL: relative-path WSL run did not re-launch" >&2; exit 1; }
grep -q 'W/' "${GITBASH_LOG}" || { echo "FAIL: relative wrapper path was not made absolute" >&2; exit 1; }
grep -q 'W\.\.' "${GITBASH_LOG}" && { echo "FAIL: relative wrapper path reached wslpath" >&2; exit 1; }
grep -q 'docker-run\.sh>' "${GITBASH_LOG}" || { echo "FAIL: wrapper script not passed to the relaunch" >&2; exit 1; }
echo "docker-run.sh (WSL relative path -> Git Bash relaunch) passed"

# --- WSL but the configured Git Bash is unreachable: no relaunch ------------
DOCKER_LOG="${ROOT}/docker-unreachable.log"
GITBASH_LOG="${ROOT}/gitbash-unreachable.log"
: > "${DOCKER_LOG}"
: > "${GITBASH_LOG}"
run_wrapper WSL_DISTRO_NAME=Ubuntu-24.04 BASH_EXE='C:/missing/bash.exe' \
  WSLPATH_U_OUT="${ROOT}/does-not-exist" >/dev/null 2>&1

grep -q '<run>.*<--rm>' "${DOCKER_LOG}" || { echo "FAIL: unreachable Git Bash should continue under WSL" >&2; exit 1; }
[[ ! -s "${GITBASH_LOG}" ]] || { echo "FAIL: unreachable Git Bash must not be executed" >&2; exit 1; }
echo "docker-run.sh (WSL, unreachable Git Bash) passed"

echo "docker-run.sh tests passed"
