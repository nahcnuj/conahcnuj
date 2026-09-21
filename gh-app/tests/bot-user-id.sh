#!/usr/bin/env bash
# bot-user-id.sh: app.env value wins (no network); unset ID with fake API
# base is not tested here (needs network) — lookup path is exercised live.
# Usage: bash bot-user-id.sh <staged gh-app dir>
set -euo pipefail

STAGE="${1:?staged gh-app dir required}"

# Staged env has no BOT_USER_ID: point the lookup at an unreachable base so
# it fails fast offline with guidance instead of hanging on DNS.
OUT="$(GH_APP_API_BASE="http://127.0.0.1:9" bash "${STAGE}/bot-user-id.sh" 2>&1 || true)"
if [[ "${OUT}" != *"BOT_USER_ID"* ]]; then
  echo "FAIL: unresolved ID should print guidance:" >&2
  echo "${OUT}" >&2
  exit 1
fi
echo "PASS bot-user-id.sh fails with guidance when unresolvable"

printf '\nBOT_USER_ID=12345\n' >> "${STAGE}/app.env"
OUT="$(bash "${STAGE}/bot-user-id.sh")"
if [[ "${OUT}" != "12345" ]]; then
  echo "FAIL: env value should win, got '${OUT}'" >&2
  exit 1
fi
echo "PASS bot-user-id.sh prefers app.env value (no network)"

# Seeded cache wins over the (unreachable) API without network.
sed -i '/^BOT_USER_ID=/d' "${STAGE}/app.env"
printf '777' > "${STAGE}/bot-id.cache"
OUT="$(GH_APP_API_BASE="http://127.0.0.1:9" bash "${STAGE}/bot-user-id.sh")"
if [[ "${OUT}" != "777" ]]; then
  echo "FAIL: cache should win, got '${OUT}'" >&2
  exit 1
fi
echo "PASS bot-user-id.sh prefers cache (no network)"
