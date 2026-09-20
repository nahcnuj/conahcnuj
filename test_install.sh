#!/usr/bin/env bash
APP_ID=331119074
INSTALLATION_ID=162902772
PRIVATE_KEY_PATH="C:/Users/nahcnuj/.ssh/conahcnuj.2026-09-18.private-key.pem"

NOW=$(date +%s)
IAT=$NOW
EXP=$((NOW + 540))

b64url() { openssl base64 -A | tr "+/" "-_" | tr -d "="; }

HEADER=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
PAYLOAD=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$IAT" "$EXP" "$APP_ID" | b64url)
SIGNING_INPUT="${HEADER}.${PAYLOAD}"
SIG=$(printf "%s" "$SIGNING_INPUT" | openssl dgst -sha256 -binary -sign "$PRIVATE_KEY_PATH" | b64url)
JWT="${SIGNING_INPUT}.${SIG}"

curl -v -X POST \
  -H "Authorization: Bearer $JWT" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/$INSTALLATION_ID/access_tokens" 2>&1