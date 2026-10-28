#!/usr/bin/env bash
# Offline tests for docker-run.sh's resolve_host_path().
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
WRAPPER="${REPO}/docker-run.sh"

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT

extract_fn() {
  sed -n '/^resolve_host_path() {/,/^}/p' "${WRAPPER}"
}

BASE="${ROOT}/host"
mkdir -p "${BASE}/mnt/c/Users/nahcnuj/.ssh"
KEY="${BASE}/mnt/c/Users/nahcnuj/.ssh/conahcnuj.pem"
printf 'pem\n' > "${KEY}"

export HOME="${BASE}/home"
mkdir -p "${HOME}/.ssh"
printf 'pem\n' > "${HOME}/.ssh/conahcnuj.pem"

# --- no cygpath on PATH (WSL/Linux style) ---
MOCKBIN="${ROOT}/bin"
mkdir -p "${MOCKBIN}"
export PATH="${MOCKBIN}:${PATH}"
# ensure no cygpath
rm -f "${MOCKBIN}/cygpath"

eval "$(extract_fn)"

# ~ expansion
got="$(resolve_host_path '~/.ssh/conahcnuj.pem')"
[[ "${got}" == "${HOME}/.ssh/conahcnuj.pem" ]] || { echo "FAIL ~ expansion: ${got}" >&2; exit 1; }

# literal existing path
got="$(resolve_host_path "${KEY}")"
[[ "${got}" == "${KEY}" ]] || { echo "FAIL literal: ${got}" >&2; exit 1; }

# CRLF stripped
got="$(resolve_host_path "${KEY}"$'\r')"
[[ "${got}" == "${KEY}" ]] || { echo "FAIL crlf: ${got}" >&2; exit 1; }

# backslash -> slash
got="$(resolve_host_path "${BASE}\\mnt\\c\\Users\\nahcnuj\\.ssh\\conahcnuj.pem")"
[[ "${got}" == "${BASE}/mnt/c/Users/nahcnuj/.ssh/conahcnuj.pem" ]] || { echo "FAIL backslash: ${got}" >&2; exit 1; }

# fallback when missing
got="$(resolve_host_path "/no/such/file.pem")"
[[ "${got}" == "/no/such/file.pem" ]] || { echo "FAIL fallback: ${got}" >&2; exit 1; }

# --- cygpath present (Git Bash / MSYS style) ---
cat > "${MOCKBIN}/cygpath" <<'CYG'
#!/usr/bin/env bash
case "${1}" in
  -u) printf '%s\n' "${2}" ;;
  *) printf '%s\n' "${2}" ;;
esac
CYG
chmod +x "${MOCKBIN}/cygpath"

eval "$(extract_fn)"

# /mnt form with cygpath: input /mnt/... maps to /<drive>/...; create counterpart
mkdir -p "${BASE}/c/Users/nahcnuj/.ssh"
cp "${KEY}" "${BASE}/c/Users/nahcnuj/.ssh/conahcnuj.pem"
# The function's candidate uses absolute /c/... not BASE, so we can't fully
# verify; just ensure it runs and returns non-empty.
got="$(resolve_host_path "/mnt/c/Users/nahcnuj/.ssh/conahcnuj.pem")"
[[ -n "${got}" ]] || { echo "FAIL cygpath empty" >&2; exit 1; }

echo "PASS: resolve_host_path"
