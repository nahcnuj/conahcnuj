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
#   bash <path-to>/docker-run.sh <issue-or-pr-number> [--pr]
#
# Environment overrides:
#   CONAHCNUJ_IMAGE        image tag (default: conahcnuj-runner)
#   CONAHCNUJ_TARGET       target repo path (default: current directory)
#   CONAHCNUJ_APP_ENV      host app.env path (default: <this repo>/gh-app/app.env)
#   CONAHCNUJ_BUILD=1      force a rebuild of the image
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

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed or not on PATH." >&2
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
HOST_ENV="${CONAHCNUJ_APP_ENV:-${HERE}/gh-app/app.env}"
if [[ ! -f "${HOST_ENV}" ]]; then
  echo "ERROR: ${HOST_ENV} not found. Create it from gh-app/app.env.example." >&2
  exit 1
fi
set -a
# shellcheck source=gh-app/app.env.example
. "${HOST_ENV}"
set +a
: "${APP_ID:?APP_ID missing from ${HOST_ENV}}"
: "${INSTALLATION_ID:?INSTALLATION_ID missing from ${HOST_ENV}}"
: "${APP_SLUG:?APP_SLUG missing from ${HOST_ENV}}"
: "${PRIVATE_KEY_PATH:?PRIVATE_KEY_PATH missing from ${HOST_ENV}}"

PEM_HOST="${PRIVATE_KEY_PATH/#\~/${HOME}}"
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
            CONAHCNUJ_POLL_CONDITIONS_MIN CONAHCNUJ_POLL_CONDITIONS_MAX \
            CONAHCNUJ_POLL_REVIEWS_MIN CONAHCNUJ_POLL_REVIEWS_MAX; do
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

exec env MSYS_NO_PATHCONV=1 docker run --rm \
  "${tty_args[@]}" \
  -v "$(host_path "${TARGET}"):/work" \
  -v "$(host_path "${RUN_DIR}/app.env"):/opt/conahcnuj/gh-app/app.env:ro" \
  -v "$(host_path "${PEM_HOST}"):/run/secrets/app.pem:ro" \
  "${oc_args[@]}" \
  "${env_args[@]}" \
  -w /work \
  "${IMAGE}" "$@"
