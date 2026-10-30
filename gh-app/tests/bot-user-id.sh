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

# Authenticated lookup: when get-token.sh can issue a token, the user lookup
# carries it (the authenticated rate limit is far higher than the public one)
# and the resolved ID is cached. Stubbed curl/token keep this offline.
WORK="$(dirname "${STAGE}")/bot-user-id-work"
mkdir -p "${WORK}/bin"
cp "${STAGE}/bot-user-id.sh" "${WORK}/"
cat > "${WORK}/get-token.sh" <<'TOKEN_EOF'
#!/usr/bin/env bash
printf 'lookup-token'
TOKEN_EOF
cat > "${WORK}/app.env" <<'ENV_EOF'
APP_ID=12345
INSTALLATION_ID=67890
APP_SLUG=conahcnuj
PRIVATE_KEY_PATH=/tmp/unused.pem
BASH_EXE="bash"
ENV_EOF
CURL_LOG="${WORK}/curl.log"
cat > "${WORK}/bin/curl" <<'CURL_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CURL_LOG}"
if [[ "$*" == *"Authorization: Bearer lookup-token"* ]]; then
  printf '{"id": 424242}'
  exit 0
fi
exit 22
CURL_EOF
chmod +x "${WORK}/bin/curl"
OUT="$(CURL_LOG="${CURL_LOG}" PATH="${WORK}/bin:${PATH}" bash "${WORK}/bot-user-id.sh")"
if [[ "${OUT}" != "424242" ]]; then
  echo "FAIL: authenticated lookup returned '${OUT}', expected '424242'" >&2
  exit 1
fi
if ! grep -q "Authorization: Bearer lookup-token" "${CURL_LOG}"; then
  echo "FAIL: authenticated lookup did not send the installation token" >&2
  cat "${CURL_LOG}" >&2
  exit 1
fi
if [[ "$(cat "${WORK}/bot-id.cache")" != "424242" ]]; then
  echo "FAIL: authenticated lookup did not cache the resolved ID" >&2
  exit 1
fi
echo "PASS bot-user-id.sh uses an authenticated lookup and caches the ID"

# If the token cannot be issued, the public lookup is still tried.
rm -f "${WORK}/bot-id.cache" "${CURL_LOG}"
cat > "${WORK}/get-token.sh" <<'TOKEN_EOF'
#!/usr/bin/env bash
exit 1
TOKEN_EOF
cat > "${WORK}/bin/curl" <<'CURL_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CURL_LOG}"
if [[ "$*" == *"Authorization:"* ]]; then
  exit 22
fi
printf '{"id": 555555}'
CURL_EOF
OUT="$(CURL_LOG="${CURL_LOG}" PATH="${WORK}/bin:${PATH}" bash "${WORK}/bot-user-id.sh")"
if [[ "${OUT}" != "555555" ]]; then
  echo "FAIL: public fallback returned '${OUT}', expected '555555'" >&2
  exit 1
fi
echo "PASS bot-user-id.sh falls back to the public lookup without a token"
