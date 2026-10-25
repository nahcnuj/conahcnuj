#!/usr/bin/env bash
# Print the bot account user ID (<slug>[bot]) for noreply email attribution.
# Order: BOT_USER_ID from app.env when set to a real value, then the
# persistent cache (bot IDs are immutable), then an authenticated lookup
# (GH_TOKEN / GITHUB_TOKEN, or an installation token minted from app.env),
# then the public GitHub API (no auth needed). Exits non-zero with guidance
# when none works.
# APP_ID is never a fallback: it is the App's own ID and never attributes
# commits to the bot account.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${DIR}/app.env"
if [[ ! -f "${ENV_FILE}" && -f "${DIR}/app.env.example" ]]; then
  ENV_FILE="${DIR}/app.env.example"
fi

set -a
# shellcheck source=gh-app/app.env.example
. "${ENV_FILE}"
set +a

API_BASE="${GH_APP_API_BASE:-https://api.github.com}"
CACHE_FILE="${DIR}/bot-id.cache"

ID="${BOT_USER_ID:-}"
if [[ -n "${ID}" && "${ID}" != "<"* ]]; then
  printf '%s' "${ID}"
  exit 0
fi

if [[ -f "${CACHE_FILE}" ]]; then
  CACHED="$(tr -d '\n \t\r' < "${CACHE_FILE}")"
  if [[ "${CACHED}" =~ ^[0-9]+$ ]]; then
    printf '%s' "${CACHED}"
    exit 0
  fi
fi

if [[ -z "${APP_SLUG:-}" || "${APP_SLUG}" == "<"* ]]; then
  echo "ERROR: BOT_USER_ID is not set and APP_SLUG is missing." >&2
  echo "Set BOT_USER_ID to the bot account user ID" >&2
  echo "(gh api users/<slug>%5Bbot%5D --jq .id), not APP_ID." >&2
  exit 1
fi

# Prefer an authenticated request (higher rate limit, avoids the shared-IP
# throttling that the unauthenticated endpoint hits in CI). GH_TOKEN and
# GITHUB_TOKEN win when present; otherwise mint an installation token from
# app.env, the same source the rest of the toolchain uses.
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [[ -z "${TOKEN}" ]]; then
  TOKEN="$(bash "${DIR}/get-token.sh" 2>/dev/null || true)"
fi

fetch_lookup() {
  local auth="${1:-}"
  if [[ -n "${auth}" ]]; then
    curl -fsSL \
      -H "Authorization: Bearer ${auth}" \
      -H "Accept: application/vnd.github+json" \
      "${API_BASE}/users/${APP_SLUG}%5Bbot%5D" 2>/dev/null || true
  else
    curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      "${API_BASE}/users/${APP_SLUG}%5Bbot%5D" 2>/dev/null || true
  fi
}

LOOKUP=""
if [[ -n "${TOKEN}" ]]; then
  LOOKUP="$(fetch_lookup "${TOKEN}")"
fi
if [[ -z "${LOOKUP}" ]]; then
  LOOKUP="$(fetch_lookup "")"
fi

ID="$(printf '%s' "${LOOKUP}" | tr -d '\n \t\r' | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
if [[ -z "${ID}" ]]; then
  echo "ERROR: cannot resolve bot user ID for ${APP_SLUG}[bot] (offline?)." >&2
  echo "Set BOT_USER_ID to the bot account user ID" >&2
  echo "(gh api users/${APP_SLUG}%5Bbot%5D --jq .id), not APP_ID." >&2
  exit 1
fi
printf '%s' "${ID}" > "${CACHE_FILE}" 2>/dev/null || true
printf '%s' "${ID}"
