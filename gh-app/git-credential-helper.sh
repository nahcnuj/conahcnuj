#!/usr/bin/env bash
set -euo pipefail

# Git credential helper for GitHub App installation tokens.
# Git invokes this as: <helper> get
# The helper must consume the request from stdin and answer on stdout.

OPERATION="${1:-get}"
if [[ "${OPERATION}" != "get" ]]; then
  # Consume stdin then exit; we have nothing to store/erase.
  cat > /dev/null || true
  exit 0
fi

# Consume the credential request that git sent on stdin.
cat > /dev/null || true

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOKEN="$(bash "${DIR}/get-token.sh")"

USERNAME="x-access-token"

printf 'username=%s\npassword=%s\n' "${USERNAME}" "${TOKEN}"