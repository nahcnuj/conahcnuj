#!/usr/bin/env bash
# Real-Docker test for docker-run.sh (no mocked docker/wslpath).
#
# The offline test (driver-tests/docker-run-mocked.bash) pins argument building and the
# WSL relaunch, but it cannot prove the wrapper actually works: the reported
# failures came from real Docker Desktop, not from the arguments we mocked.
# This test builds the real image and runs the wrapper with an entrypoint
# override, then inspects the container to assert that the target repo, the
# generated app.env and the private key are mounted where the driver expects.
#
# docker-run.sh runs whenever a Docker daemon is available; the offline
# suite (driver-tests/run.sh) skips it where there is none. CI runs it in the
# dedicated `docker-runner` job.
set -euo pipefail

# Run whenever a working Docker daemon is available; skip (do not fail) in
# environments without one (e.g. the offline suite on a developer machine).
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "SKIP: docker is not available"
  exit 0
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
WRAPPER="${REPO}/docker-run.sh"
IMAGE="conahcnuj-runner-test"

ROOT="$(mktemp -d)"
cleanup() {
  rm -rf "${ROOT}"
  docker image rm -f "${IMAGE}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

TARGET="${ROOT}/target"
git init -q "${TARGET}"
printf 'hello\n' > "${TARGET}/hello.txt"

PEM="${ROOT}/app.pem"
APP_ENV="${ROOT}/app.env"
# Use the real GitHub App env when it is provided (CI passes the repo secrets),
# so the wrapper is exercised the way it is in regular usage; fall back to
# dummy values for local runs without secrets.
if [[ -n "${APP_ID:-}" && -n "${INSTALLATION_ID:-}" && -n "${PRIVATE_KEY:-}" ]]; then
  REAL_ENV=1
  printf '%s\n' "${PRIVATE_KEY}" > "${PEM}"
  APP_SLUG_VAL="${APP_SLUG:-conahcnuj}"
  cat > "${APP_ENV}" <<EOF
APP_ID="${APP_ID}"
INSTALLATION_ID="${INSTALLATION_ID}"
APP_SLUG="${APP_SLUG_VAL}"
PRIVATE_KEY_PATH="${PEM}"
BASH_EXE="C:/Program Files/Git/bin/bash.exe"
EOF
else
  REAL_ENV=0
  APP_SLUG_VAL="conahcnuj"
  printf 'dummy-pem-%s\n' "$$" > "${PEM}"
  cat > "${APP_ENV}" <<EOF
APP_ID="1"
INSTALLATION_ID="2"
APP_SLUG="${APP_SLUG_VAL}"
PRIVATE_KEY_PATH="${PEM}"
BASH_EXE="C:/Program Files/Git/bin/bash.exe"
EOF
fi

export OPENCODE_CONFIG_DIR="${ROOT}/no-config"
export OPENCODE_DATA_DIR="${ROOT}/no-data"

# Build the real image and run the wrapper through real Docker. The override
# entrypoint lets us inspect the container instead of launching the driver
# (which would need live GitHub credentials).
if (( REAL_ENV == 1 )); then
  TOKEN_CHECK='bash /opt/conahcnuj/gh-app/get-token.sh >/dev/null && echo "TOKEN_OK"'
else
  TOKEN_CHECK='echo "TOKEN_SKIP (no real env)"'
fi
set +e
out="$(
  CONAHCNUJ_BUILD=1 \
  CONAHCNUJ_IMAGE="${IMAGE}" \
  CONAHCNUJ_TARGET="${TARGET}" \
  CONAHCNUJ_APP_ENV="${APP_ENV}" \
  CONAHCNUJ_ENTRYPOINT=/bin/bash \
  bash "${WRAPPER}" -c "
    set -e
    test -d /work/.git
    test -f /work/hello.txt
    test -x /opt/conahcnuj/bin/conahcnuj.sh
    test -f /opt/conahcnuj/lib/gh-api.sh
    test -f /opt/conahcnuj/gh-app/get-token.sh
    command -v gh >/dev/null
    command -v opencode >/dev/null
    test -f /opt/conahcnuj/gh-app/app.env
    grep -qx 'PRIVATE_KEY_PATH=/run/secrets/app.pem' /opt/conahcnuj/gh-app/app.env
    grep -qx 'BASH_EXE=/usr/bin/bash' /opt/conahcnuj/gh-app/app.env
    grep -qx \"APP_SLUG=${APP_SLUG_VAL}\" /opt/conahcnuj/gh-app/app.env
    test -r /run/secrets/app.pem
    test ! -w /run/secrets/app.pem
    test ! -w /opt/conahcnuj/gh-app/app.env
    ${TOKEN_CHECK}
    printf 'PWD=%s\\n' \"\$(pwd)\"
    printf 'PEM=%s\\n' \"\$(cat /run/secrets/app.pem)\"
  " 2>&1
)
rc=$?
set -e
if [[ ${rc} -ne 0 ]]; then
  echo "FAIL: wrapper exited ${rc}; output:" >&2
  printf '%s\n' "${out}" >&2
  exit 1
fi

grep -q 'PWD=/work' <<<"${out}" || {
  echo "FAIL: container did not start in /work; output:" >&2
  printf '%s\n' "${out}" >&2
  exit 1
}
if (( REAL_ENV == 1 )); then
  grep -q "TOKEN_OK" <<<"${out}" || {
    echo "FAIL: get-token.sh did not succeed with the real env; output:" >&2
    printf '%s\n' "${out}" >&2
    exit 1
  }
else
  grep -q "PEM=dummy-pem-$$" <<<"${out}" || {
    echo "FAIL: private key was not mounted read-only at /run/secrets/app.pem; output:" >&2
    printf '%s\n' "${out}" >&2
    exit 1
  }
fi
grep -q 'PEM=' <<<"${out}" || {
  echo "FAIL: private key was not mounted at /run/secrets/app.pem; output:" >&2
  printf '%s\n' "${out}" >&2
  exit 1
}

