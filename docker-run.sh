#!/usr/bin/env bash
# Run the conahcnuj driver inside an isolated Docker container.
#
# The target repository is bind-mounted at /work; the driver, opencode and the
# tooling live in the image. The GitHub App secrets (app.env + private key) are
# mounted read-only and never baked into the image, so the container can reach
# GitHub without the host repo being touched by the autonomous agent.
#
# Usage:
#   cd <target-repo>
#   bash <path-to>/docker-run.sh <issue-or-pr-number>
#   "C:/Program Files/Git/bin/bash.exe" <path-to>/docker-run.sh <issue-or-pr-number>   # Windows
#
# On Windows a bare `bash` from PowerShell can resolve to WSL bash, where
# `docker` only knows unix:///var/run/docker.sock and cannot reach Docker
# Desktop, even though `docker ps` works in PowerShell. The wrapper detects
# that case and re-launches itself under the configured Git Bash (BASH_EXE),
# the same way the driver does for the GitHub App paths.
#
# By default the container runs in the foreground and stops as soon as the
# driver exits. Set CONAHCNUJ_DAEMON=1 (with an optional CONAHCNUJ_NAME) to
# run detached instead; the container is then kept (not --rm) so the run can be
# followed and inspected afterwards with `docker logs -f <name>`.
#
# Environment overrides:
#   CONAHCNUJ_IMAGE        image tag (default: conahcnuj-runner)
#   CONAHCNUJ_TARGET       target repo path (default: current directory)
#   CONAHCNUJ_APP_ENV      host app.env path (default: <this repo>/gh-app/app.env)
#   CONAHCNUJ_BUILD=1      force a rebuild of the image
#   CONAHCNUJ_DAEMON=1     run detached (container name below), poll via `docker logs`
#   CONAHCNUJ_NAME         container name to use in daemon mode (default: conahcnuj-<epoch>)
#   CONAHCNUJ_ENTRYPOINT   override the image ENTRYPOINT (default: the driver). Used
#                          by the real-Docker test to inspect the container without
#                          contacting GitHub; container args follow it as usual.
#   OPENCODE_CONFIG_DIR    host opencode config dir (default: ~/.config/opencode)
#   OPENCODE_DATA_DIR      host opencode data/auth dir (default: ~/.local/share/opencode)
#   CONAHCNUJ_REPO, CONAHCNUJ_MAX_SECONDS, CONAHCNUJ_POLL_* are passed through.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${CONAHCNUJ_IMAGE:-conahcnuj-runner}"
TARGET="${CONAHCNUJ_TARGET:-${PWD}}"

# Git Bash / MSYS rewrites arguments that look like POSIX paths, which corrupts
# container-side absolute paths (-w /work becomes C:/Program Files/Git/work).
# Convert host-side paths to Windows form ourselves and run docker with MSYS
# conversion disabled, so the container paths pass through untouched.
if command -v cygpath >/dev/null 2>&1; then
  host_path() { cygpath -m "${1}"; }
else
  host_path() { printf '%s\n' "${1}"; }
fi
docker_() { MSYS_NO_PATHCONV=1 docker "$@"; }

resolve_host_path() {
  local input="${1}"
  # Drop CR so CRLF app.env files (common on Windows) do not leave a
  # trailing \r on the path, which would make every -e check fail.
  input="${input//$'\r'/}"
  # Trim surrounding whitespace.
  input="${input#"${input%%[![:space:]]*}"}"
  input="${input%"${input##*[![:space:]]}"}"
  # Strip surrounding quotes that an app.env value may carry (possibly
  # more than one layer, e.g. "\"path\"").
  while true; do
    case "${input}" in
      \"*\") input="${input:1:${#input}-2}" ;;
      \'*\') input="${input:1:${#input}-2}" ;;
      *) break ;;
    esac
  done
  local p="${input/#\~/${HOME}}"
  p="${p//\\//}"
  p="${p//$'\r'/}"
  # Trim again after normalization.
  p="${p#"${p%%[![:space:]]*}"}"
  p="${p%"${p##*[![:space:]]}"}"
  local candidates=("${p}")
  if [[ "${p}" =~ ^/mnt/([a-zA-Z])(/.*)?$ ]]; then
    local drive="${BASH_REMATCH[1]}"
    local rest="${BASH_REMATCH[2]}"
    candidates+=("/${drive,,}${rest}")
    candidates+=("/cygdrive/${drive,,}${rest}")
    candidates+=("${drive^^}:${rest}")
  fi
  if [[ "${p}" =~ ^/cygdrive/([a-zA-Z])(/.*)?$ ]]; then
    local drive="${BASH_REMATCH[1]}"
    local rest="${BASH_REMATCH[2]}"
    candidates+=("/${drive,,}${rest}")
    candidates+=("/mnt/${drive,,}${rest}")
    candidates+=("${drive^^}:${rest}")
  fi
  if [[ "${p}" =~ ^/([a-zA-Z])(/.*)?$ ]]; then
    local drive="${BASH_REMATCH[1]}"
    local rest="${BASH_REMATCH[2]}"
    candidates+=("/mnt/${drive,,}${rest}")
    candidates+=("/cygdrive/${drive,,}${rest}")
    candidates+=("${drive^^}:${rest}")
  fi
  if [[ "${p}" =~ ^([a-zA-Z]):(/.*)?$ ]]; then
    local drive="${BASH_REMATCH[1]}"
    local rest="${BASH_REMATCH[2]:-}"
    if [[ -n "${rest}" && -e "/${drive,,}${rest}" ]]; then
      printf '%s\n' "/${drive,,}${rest}"
      return 0
    fi
    if [[ -n "${rest}" ]]; then
      candidates+=("/${drive,,}${rest}")
    else
      candidates+=("/${drive,,}")
    fi
    candidates+=("/mnt/${drive,,}${rest}")
    candidates+=("/cygdrive/${drive,,}${rest}")
    if [[ -z "${rest}" ]]; then
      candidates+=("${drive^^}:")
    else
      candidates+=("${drive^^}:${rest}")
    fi
  fi
  local c
  for c in "${candidates[@]}"; do
    if [[ -e "${c}" ]]; then
      printf '%s\n' "${c}"
      return 0
    fi
  done
  printf '%s\n' "${p}"
}


# --- Windows / WSL relaunch -------------------------------------------------

# The configured Git Bash: environment override > app.env > the committed
# app.env.example. A placeholder means "not configured", so fall back to the
# standard Git for Windows location (issue #417: PowerShell's `bash` is WSL
# bash, whose docker cannot reach Docker Desktop).
docker_bash_exe() {
  local env_file line
  if [[ -n "${BASH_EXE:-}" ]]; then
    printf '%s\n' "${BASH_EXE}"
    return 0
  fi
  env_file="$(resolve_host_path "${CONAHCNUJ_APP_ENV:-${HERE}/gh-app/app.env}")"
  if [[ ! -f "${env_file}" ]]; then
    env_file="$(resolve_host_path "${HERE}/gh-app/app.env.example")"
  fi
  if [[ -f "${env_file}" ]]; then
    line="$(tr -d '\r' < "${env_file}" | sed -n 's/^[[:space:]]*BASH_EXE[[:space:]]*=[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p' | head -1)"
    if [[ -z "${line}" ]]; then
      line="$(tr -d '\r' < "${env_file}" | sed -n "s/^[[:space:]]*BASH_EXE[[:space:]]*=[[:space:]]*'\([^']*\)'[[:space:]]*$/\1/p" | head -1)"
    fi
    if [[ -z "${line}" ]]; then
      line="$(tr -d '\r' < "${env_file}" | sed -n 's/^[[:space:]]*BASH_EXE[[:space:]]*=[[:space:]]*\([^[:space:]]*\)[[:space:]]*$/\1/p' | head -1)"
    fi
    if [[ -n "${line}" && "${line}" != "<your-bash-exe>" ]]; then
      printf '%s\n' "${line}"
      return 0
    fi
  fi
  printf '%s\n' "C:/Program Files/Git/bin/bash.exe"
}

# True when the wrapper must re-launch itself under Git Bash. Only under WSL
# (a bare Windows `bash`) and only when the configured Git Bash is reachable.
docker_needs_relaunch() {
  # WSL sets WSL_DISTRO_NAME; Git Bash (MSYS) does not. Do not also require
  # MSYSTEM to be empty: on Windows, Git Bash forces MSYSTEM into the
  # environment and it cannot reliably be unset (issue #417), which made the
  # WSL simulation in the tests (and real invocations under a WSL bash that
  # inherited MSYSTEM) skip the relaunch.
  [[ -n "${WSL_DISTRO_NAME:-}" ]] || return 1
  command -v wslpath >/dev/null 2>&1 || return 1
  local bash_exe bash_mnt
  bash_exe="$(docker_bash_exe)"
  bash_mnt="$(wslpath -u "${bash_exe}" 2>/dev/null || true)"
  if [[ -z "${bash_mnt}" || ! -x "${bash_mnt}" ]]; then
    echo "WARNING: BASH_EXE ${bash_exe} is not reachable from WSL; continuing (docker may not reach Docker Desktop)." >&2
    return 1
  fi
  return 0
}

# Convert a WSL path to the Windows form Git Bash understands. Windows paths
# and relative paths are passed through untouched.
wsl_win_path() {
  local path="${1}"
  if [[ "${path}" == /* ]]; then
    wslpath -m "${path}" 2>/dev/null || printf '%s\n' "${path}"
  else
    printf '%s\n' "${path}"
  fi
}

# Re-run the wrapper under the configured Git Bash, preserving the target repo,
# app.env location and CONAHCNUJ_* / OPENCODE_* / DOCKER_* overrides (WSL
# interop only forwards variables listed in WSLENV). Git Bash runs as a child
# and an interrupt is forwarded as TERM, matching bin/conahcnuj.sh.
docker_relaunch() {
  local bash_exe bash_mnt self self_win child rc
  bash_exe="$(docker_bash_exe)"
  bash_mnt="$(wslpath -u "${bash_exe}")"
  # Resolve the wrapper to an absolute path first. Invoking it as
  # `bash ../conahcnuj/docker-run.sh` (the reported PowerShell case) leaves a
  # relative BASH_SOURCE[0], and wslpath cannot turn that into a Windows path.
  self="${BASH_SOURCE[0]}"
  if [[ "${self}" != */* ]]; then
    self="$(command -v "${self}" 2>/dev/null || true)"
  fi
  if [[ -n "${self}" && "${self}" != /* ]]; then
    self="$(cd "$(dirname "${self}")" 2>/dev/null && pwd)/$(basename "${self}")"
  fi
  if [[ -z "${self}" ]]; then
    echo "WARNING: could not resolve ${BASH_SOURCE[0]} to relaunch; continuing under WSL." >&2
    return 1
  fi
  self_win="$(wslpath -m "${self}" 2>/dev/null || true)"
  if [[ -z "${self_win}" ]]; then
    echo "WARNING: could not convert ${self} to a Windows path; continuing under WSL." >&2
    return 1
  fi

  CONAHCNUJ_TARGET="$(wsl_win_path "${TARGET}")"
  export CONAHCNUJ_TARGET
  if [[ -n "${CONAHCNUJ_APP_ENV:-}" ]]; then
    CONAHCNUJ_APP_ENV="$(wsl_win_path "${CONAHCNUJ_APP_ENV}")"
    export CONAHCNUJ_APP_ENV
  fi

  local wslenv_add="" name
  for name in $(compgen -v); do
    case "${name}" in
      CONAHCNUJ_*|OPENCODE_*|DOCKER_*|BASH_EXE)
        if [[ -n "${!name:-}" ]]; then
          wslenv_add="${wslenv_add:+${wslenv_add}:}${name}"
        fi
        ;;
    esac
  done
  if [[ -n "${wslenv_add}" ]]; then
    export WSLENV="${WSLENV:+${WSLENV}:}${wslenv_add}"
  fi

  "${bash_mnt}" "${self_win}" "$@" &
  child=$!
  trap 'kill -TERM "${child}" 2>/dev/null || true' INT TERM
  rc=0
  wait "${child}" || rc=$?
  wait "${child}" 2>/dev/null || true
  trap - INT TERM
  exit "${rc}"
}

# Sourceable: tests set CONAHCNUJ_IMPORT=1 to load helpers without running.
if [[ "${CONAHCNUJ_IMPORT:-0}" == "1" && "${BASH_SOURCE[0]}" != "${0}" ]]; then
  return 0
fi

if docker_needs_relaunch; then
  docker_relaunch "$@"
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed or not on PATH." >&2
  exit 1
fi

# Fail with the daemon's own message (and a Windows hint) instead of letting
# `docker build` surface a raw "failed to connect" error. The WSL case is the
# common one: PowerShell's docker works but the WSL one has no daemon.
if ! docker_ info >/dev/null 2>&1; then
  echo "ERROR: cannot reach the Docker daemon with $(command -v docker)." >&2
  docker_ info >&2 || true
  if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
    echo "HINT: run this script with Git Bash (BASH_EXE), not WSL bash, so it uses Docker Desktop." >&2
  fi
  exit 1
fi

if [[ ! -d "${TARGET}/.git" ]] && ! git -C "${TARGET}" rev-parse --git-dir >/dev/null 2>&1; then
  echo "ERROR: ${TARGET} is not a git repository (set CONAHCNUJ_TARGET)." >&2
  exit 1
fi

if [[ "${CONAHCNUJ_BUILD:-0}" == "1" ]] || ! docker_ image inspect "${IMAGE}" >/dev/null 2>&1; then
  echo "Building ${IMAGE}..." >&2
  docker_ build -t "${IMAGE}" "$(host_path "${HERE}")"
fi

# Turn the host app.env into a container-friendly one: the credential helper
# must call the container's bash, and the key must point at the mounted secret.
HOST_ENV="$(resolve_host_path "${CONAHCNUJ_APP_ENV:-${HERE}/gh-app/app.env}")"
if [[ ! -f "${HOST_ENV}" ]]; then
  echo "ERROR: ${HOST_ENV} not found. Create it from gh-app/app.env.example." >&2
  exit 1
fi
set -a
# shellcheck source=gh-app/app.env.example
# Strip CR so CRLF app.env files (common on Windows) parse cleanly.
. <(tr -d '\r' < "${HOST_ENV}")
set +a
: "${APP_ID:?APP_ID missing from ${HOST_ENV}}"
: "${INSTALLATION_ID:?INSTALLATION_ID missing from ${HOST_ENV}}"
: "${APP_SLUG:?APP_SLUG missing from ${HOST_ENV}}"
: "${PRIVATE_KEY_PATH:?PRIVATE_KEY_PATH missing from ${HOST_ENV}}"

PEM_HOST="$(resolve_host_path "${PRIVATE_KEY_PATH}")"
if [[ ! -f "${PEM_HOST}" ]]; then
  echo "ERROR: private key not found: ${PEM_HOST}" >&2
  exit 1
fi

RUN_DIR="$(mktemp -d)"
trap 'rm -rf "${RUN_DIR}"' EXIT
{
  printf 'APP_ID=%s\n' "${APP_ID}"
  printf 'INSTALLATION_ID=%s\n' "${INSTALLATION_ID}"
  printf 'APP_SLUG=%s\n' "${APP_SLUG}"
  printf 'PRIVATE_KEY_PATH=%s\n' "/run/secrets/app.pem"
  printf 'BASH_EXE=%s\n' "/usr/bin/bash"
  if [[ -n "${BOT_USER_ID:-}" ]]; then
    printf 'BOT_USER_ID=%s\n' "${BOT_USER_ID}"
  fi
} > "${RUN_DIR}/app.env"

# Forward driver overrides that are actually set.
env_args=()
for name in CONAHCNUJ_REPO CONAHCNUJ_MAX_SECONDS \
            CONAHCNUJ_POLL_CONDITIONS_MIN CONAHCNUJ_POLL_CONDITIONS_MAX; do
  if [[ -n "${!name:-}" ]]; then
    env_args+=(-e "${name}=${!name}")
  fi
done

# Mount opencode config/auth when present, so the container sees the same
# providers and logged-in models as the host.
#
# The data dir is NOT mounted wholesale: opencode keeps its state in a SQLite
# database there (opencode.db + WAL), and SQLite over a Docker Desktop bind
# mount fails with "disk I/O error". Only the auth file is needed; the rest of
# the (container-local) data dir is created on the fly.
oc_args=()
OC_CONFIG="${OPENCODE_CONFIG_DIR:-${HOME}/.config/opencode}"
OC_DATA="${OPENCODE_DATA_DIR:-${HOME}/.local/share/opencode}"
if [[ -d "${OC_CONFIG}" ]]; then
  oc_args+=(-v "$(host_path "${OC_CONFIG}"):/root/.config/opencode")
  # Point the gh-app-token plugin at the container-friendly app.env (container
  # bash + the mounted private key) instead of the host one sitting in the
  # mounted config dir.
  if [[ -d "${OC_CONFIG}/gh-app" ]]; then
    oc_args+=(-v "$(host_path "${RUN_DIR}/app.env"):/root/.config/opencode/gh-app/app.env:ro")
  fi
fi
if [[ -f "${OC_DATA}/auth.json" ]]; then
  oc_args+=(-v "$(host_path "${OC_DATA}/auth.json"):/root/.local/share/opencode/auth.json")
fi

# Attach a TTY only when one is present, so the wrapper also works from
# non-interactive callers (CI, editors, scripts).
tty_args=()
if [[ -t 0 && -t 1 ]]; then
  tty_args+=(-it)
fi

# Common run arguments: all mounts, driver overrides and the positional
# driver arguments. Shared by foreground and daemon modes.
run_args=(
  -v "$(host_path "${TARGET}"):/work"
  -v "$(host_path "${RUN_DIR}/app.env"):/opt/conahcnuj/gh-app/app.env:ro"
  -v "$(host_path "${PEM_HOST}"):/run/secrets/app.pem:ro"
)

if (( ${#oc_args[@]} > 0 )); then
  run_args+=("${oc_args[@]}")
fi
if (( ${#env_args[@]} > 0 )); then
  run_args+=("${env_args[@]}")
fi

# Optional entrypoint override (the real-Docker test supplies /bin/bash to
# exercise the mounts without running the driver against GitHub).
if [[ -n "${CONAHCNUJ_ENTRYPOINT:-}" ]]; then
  run_args+=(--entrypoint "${CONAHCNUJ_ENTRYPOINT}")
fi
run_args+=(-w /work "${IMAGE}" "$@")

# Daemon mode: run detached with a stable name so the caller (or an agent) can
# follow progress with `docker logs -f <name>`. The container is intentionally
# NOT --rm in this mode, so its logs survive the driver exiting (or crashing)
# and can be inspected afterwards; remove it with `docker rm <name>`.
if [[ "${CONAHCNUJ_DAEMON:-0}" == "1" ]]; then
  NAME="${CONAHCNUJ_NAME:-conahcnuj-$(date +%s)}"
  # The EXIT trap must NOT remove RUN_DIR here: the detached container still
  # bind-mounts RUN_DIR/app.env, so clearing the trap (not just leaving the
  # dir) keeps the mount valid for the whole lifetime of the run.
  trap - EXIT
  # docker run -d prints the container ID to stdout; keep the wrapper's own
  # diagnostics on stderr so the caller can parse stdout if needed.
  docker_ run -d --name "${NAME}" \
    "${run_args[@]}" 1>&2
  echo "Detached container ${NAME} started; follow with: docker logs -f ${NAME}" >&2
  echo "${NAME}"
  exit 0
fi

# Foreground (attached) run. NOT exec: the EXIT trap must still fire to remove
# RUN_DIR, whose container app.env would otherwise leak on every run. A failing
# docker still propagates its status through set -e, and signals reach both the
# wrapper and docker, which shares this foreground process group.
docker_args=(env MSYS_NO_PATHCONV=1 docker run --rm)
if (( ${#tty_args[@]} > 0 )); then
  docker_args+=("${tty_args[@]}")
fi
docker_args+=("${run_args[@]}")
"${docker_args[@]}"
