#!/usr/bin/env bash
# install.sh - Deploy the GitHub App "conahcnuj" git-identity files into the
# opencode user-level config directory (Linux / macOS / any POSIX shell).
#
# Usage:
#   ./install.sh                        # -> $XDG_CONFIG_HOME/opencode (or ~/.config/opencode)
#   ./install.sh --destination <dir>    # -> <dir>
#   ./install.sh --install-path <dir>   # default: ~/.local/bin
#   ./install.sh --help
#
# POSIX counterpart of install.ps1 (Windows); both deploy the same payload:
#   - <destination>/gh-app/...          used by the opencode plugin (resolves
#                                       gh-app relative to its own plugins dir)
#   - <install-path parent>/gh-app/...  used by the conahcnuj driver binary
#                                       (resolves gh-app relative to itself)
# plus:
#   - <destination>/plugins/gh-app-token.ts   opencode plugin
#   - <install-path>/conahcnuj                driver binary
#   - <install-path parent>/lib/*.sh           driver runtime libs
# If the config destination has no app.env yet, it is created from
# app.env.example (an app.env already present at the destination is kept).
# plugins/package.json, package-lock.json, tsconfig.json and node_modules are
# local typecheck tooling and are never deployed; gh-app/tests and other test
# code is never deployed either.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [--destination <dir>] [--install-path <dir>]

  -d, --destination <dir>   opencode config dir (default: \$XDG_CONFIG_HOME/opencode
                            or ~/.config/opencode)
  -i, --install-path <dir>  directory for the conahcnuj binary (default: ~/.local/bin)
  -h, --help                show this help
EOF
}

DESTINATION=""
INSTALL_PATH=""
while [[ $# -gt 0 ]]; do
  case "${1}" in
    -d | --destination)
      [[ $# -ge 2 ]] || { echo "ERROR: ${1} requires a directory" >&2; exit 1; }
      DESTINATION="${2}"
      shift 2
      ;;
    --destination=*)
      DESTINATION="${1#*=}"
      shift
      ;;
    -i | --install-path)
      [[ $# -ge 2 ]] || { echo "ERROR: ${1} requires a directory" >&2; exit 1; }
      INSTALL_PATH="${2}"
      shift 2
      ;;
    --install-path=*)
      INSTALL_PATH="${1#*=}"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: ${1}" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${DESTINATION}" ]]; then
  DESTINATION="${XDG_CONFIG_HOME:-${HOME}/.config}/opencode"
fi
if [[ -z "${INSTALL_PATH}" ]]; then
  INSTALL_PATH="${HOME}/.local/bin"
fi

SRC_GH_APP="${REPO_ROOT}/gh-app"
SRC_PLUGINS="${REPO_ROOT}/plugins"
SRC_BIN="${REPO_ROOT}/bin"
SRC_LIB="${REPO_ROOT}/lib"

for dir in "${SRC_GH_APP}" "${SRC_PLUGINS}" "${SRC_BIN}" "${SRC_LIB}"; do
  if [[ ! -d "${dir}" ]]; then
    echo "ERROR: ${dir} not found. Run install.sh from a checkout of the repository." >&2
    exit 1
  fi
done

# The opencode plugin resolves gh-app next to its own plugins dir, so the
# config destination needs a full gh-app tree. The driver binary reads gh-app
# and lib relative to its own location, so those are mirrored beside it.
DST_GH_APP_CONFIG="${DESTINATION}/gh-app"
DST_PLUGINS="${DESTINATION}/plugins"
DST_BIN_DIR="${INSTALL_PATH}"
DST_BIN_SIDE="$(dirname "${INSTALL_PATH}")"
DST_GH_APP_BIN="${DST_BIN_SIDE}/gh-app"
DST_LIB_BIN="${DST_BIN_SIDE}/lib"

echo "Config destination: ${DESTINATION}"
echo "Binary path: ${DST_BIN_DIR}"

# Deploy one gh-app tree: all top-level scripts, app.env.example and app.env.
deploy_gh_app() {
  local dst="${1}"
  local src name legacy example
  mkdir -p "${dst}"
  for src in "${SRC_GH_APP}"/*.sh; do
    name="$(basename "${src}")"
    cp "${src}" "${dst}/${name}"
    chmod +x "${dst}/${name}"
    echo "  copied ${name}"
  done

  # Test code is never deployed: tests run from the repo in CI.
  # Drop leftovers from earlier installs that shipped it.
  for legacy in mock-test.sh tests; do
    if [[ -e "${dst}/${legacy}" ]]; then
      rm -rf "${dst:?}/${legacy}"
      echo "  removed legacy ${legacy} (test code is not deployed)"
    fi
  done

  # app.env.example
  example="${SRC_GH_APP}/app.env.example"
  if [[ -f "${example}" ]]; then
    cp "${example}" "${dst}/app.env.example"
    echo "  copied app.env.example"
  fi

  # app.env: copy the real one if it ships with the repo source, otherwise
  # create from example (fresh clone / CI) unless one already exists at the
  # destination (keep existing local config).
  if [[ -f "${SRC_GH_APP}/app.env" ]]; then
    cp "${SRC_GH_APP}/app.env" "${dst}/app.env"
    echo "  copied app.env"
  elif [[ ! -f "${dst}/app.env" ]]; then
    cp "${example}" "${dst}/app.env"
    echo "  created app.env from app.env.example (edit app.env values as needed)"
  fi
}

# 1. gh-app for the opencode plugin (config destination).
echo "Deploying gh-app to ${DST_GH_APP_CONFIG}"
deploy_gh_app "${DST_GH_APP_CONFIG}"

# 2. opencode plugin
mkdir -p "${DST_PLUGINS}"
plugin="gh-app-token.ts"
cp "${SRC_PLUGINS}/${plugin}" "${DST_PLUGINS}/${plugin}"
echo "  copied ${plugin}"

# 3. driver runtime beside the binary (gh-app + lib).
echo "Deploying gh-app to ${DST_GH_APP_BIN}"
deploy_gh_app "${DST_GH_APP_BIN}"
mkdir -p "${DST_LIB_BIN}"
for src in "${SRC_LIB}"/*.sh; do
  name="$(basename "${src}")"
  cp "${src}" "${DST_LIB_BIN}/${name}"
  echo "  copied lib/${name}"
done

# 4. conahcnuj binary
mkdir -p "${DST_BIN_DIR}"
bin_name="conahcnuj"
cp "${SRC_BIN}/conahcnuj.sh" "${DST_BIN_DIR}/${bin_name}"
chmod +x "${DST_BIN_DIR}/${bin_name}"
echo "  copied ${bin_name} to ${DST_BIN_DIR}"

echo ""
echo "Done. Restart opencode to load the plugin (plugins/*.ts is auto-loaded)."
echo "Add ${DST_BIN_DIR} to your PATH to use 'conahcnuj' command."
if [[ -f "${DST_GH_APP_CONFIG}/app.env" ]] && grep -q '^BASH_EXE="<your-bash-exe>"$' "${DST_GH_APP_CONFIG}/app.env"; then
  echo "BASH_EXE in app.env is still the placeholder: the platform default is used"
  echo "until you set it (Git for Windows under MSYS/MinGW, /bin/bash elsewhere)."
fi
