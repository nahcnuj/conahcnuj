#!/usr/bin/env bash
set -euo pipefail
APP_ID=331119074
INSTALLATION_ID=162902772
PRIVATE_KEY_PATH="C:/Users/nahcnuj/.ssh/conahcnuj.2026-09-18.private-key.pem"

# shellcheck source=gh-app/app.env.example
# If app.env is missing, fall back to the committed example.
if [[ ! -f "gh-app/app.env" && -f "gh-app/app.env.example" ]]; then
  : # use example as fallback
fi

NOW="$(date +%s)"
IAT="${NOW}"
EXP="$((NOW + 540))"

b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

# 1) Build JWT header + payload
HEADER="$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)"
PAYLOAD="$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "${IAT}" "${EXP}" "${APP_ID}" | b64url)"
SIGNING_INPUT="${HEADER}.${PAYLOAD}"

# 2) Sign with the app private key (RS256)
SIG="$(printf '%s' "${SIGNING_INPUT}" | openssl dgst -sha256 -binary -sign "${PEM_PATH}" | b64url)"
JWT="${SIGNING_INPUT}.${SIG}"

# 3) Exchange JWT for an installation access token
RESP="$(curl -fsSL \
  -X POST \
  -H "Authorization: Bearer ${JWT}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/${INSTALLATION_ID}/access_tokens" 2>&1)"

TOKEN="$(printf '%s' "${RESP}" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
EXPIRES_AT="$(printf '%s' "${RESP}" | sed -n 's/.*"expires_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

if [[ -z "${TOKEN}" ]]; then
  echo "ERROR: failed to fetch installation access token" >&2
  exit 1
fi

# Cache until 10 min before expiry.
if [[ -n "${EXPIRES_AT}" ]]; then
  CACHE_EXPIRES="$(( $(date -d "${EXPIRES_AT}" +%s) - 600 ))"
else
  CACHE_EXPIRES="$((NOW + 3000))"
fi
printf '%s|%s' "${CACHE_EXPIRES}" "${TOKEN}" > "${HOME}/token.cache"
printf '%s' "${TOKEN}"