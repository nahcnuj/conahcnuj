#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${DIR}/app.env"
CACHE_FILE="${DIR}/token.cache"

# Real config wins; fall back to the committed example (e.g. fresh clone / CI).
if [[ ! -f "${ENV_FILE}" && -f "${DIR}/app.env.example" ]]; then
  ENV_FILE="${DIR}/app.env.example"
fi

set -a
. "${ENV_FILE}"
set +a

PEM_PATH="${PRIVATE_KEY_PATH/#\~/${HOME}}"
API_BASE="${GH_APP_API_BASE:-https://api.github.com}"

# Return cached token if still valid (installation tokens live ~1h).
if [[ -f "${CACHE_FILE}" ]]; then
  CACHE_EXPIRES="$(sed -n '1{s/^\([0-9][0-9]*\)|.*$/\1/p}' "${CACHE_FILE}")"
  CACHE_TOKEN="$(sed -n '1{s/^[0-9][0-9]*|//p}' "${CACHE_FILE}")"
  if [[ -n "${CACHE_EXPIRES}" && -n "${CACHE_TOKEN}" && "$(date +%s)" -lt "${CACHE_EXPIRES}" ]]; then
    printf '%s' "${CACHE_TOKEN}"
    exit 0
  fi
fi

# 1) Build JWT header + payload
NOW="$(date +%s)"
IAT="${NOW}"
EXP="$((NOW + 540))"  # max 10 min

b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

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
  "${API_BASE}/app/installations/${INSTALLATION_ID}/access_tokens")"

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
printf '%s|%s' "${CACHE_EXPIRES}" "${TOKEN}" > "${CACHE_FILE}"

printf '%s' "${TOKEN}"