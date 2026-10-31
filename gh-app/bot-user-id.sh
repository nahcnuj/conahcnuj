#!/usr/bin/env bash
# Print the bot account user ID (<slug>[bot]) for noreply email attribution.
# Order: BOT_USER_ID from app.env when set to a real value, then the
# persistent cache (bot IDs are immutable), then the public GitHub API
# (no auth needed, but an installation token is used when available to
# avoid unauthenticated rate limits). Exits non-zero with guidance when none
# works.
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

# Prefer an installation token when one is obtainable: the unauthenticated
# endpoint is subject to the shared 60/hour rate limit on api.github.com.
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [[ -z "${TOKEN}" ]]; then
  TOKEN="$(bash "${DIR}/get-token.sh" 2>/dev/null || true)"
fi

AUTH_ARGS=()
if [[ -n "${TOKEN}" ]]; then
  AUTH_ARGS=(-H "Authorization: Bearer ${TOKEN}")
fi

if [[ ${#AUTH_ARGS[@]} -gt 0 ]]; then
  LOOKUP="$(curl -fsSL "${AUTH_ARGS[@]}" \
    -H "Accept: application/vnd.github+json" \
    "${API_BASE}/users/${APP_SLUG}%5Bbot%5D" 2>/dev/null || true)"
else
  LOOKUP="$(curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    "${API_BASE}/users/${APP_SLUG}%5Bbot%5D" 2>/dev/null || true)"
fi

# REST answers pretty-printed, so read with optional whitespace (issue #136).
ID="$(printf '%s' "${LOOKUP}" |
  grep -oE '"id"[[:space:]]*:[[:space:]]*[0-9]+' |
  head -n 1 |
  grep -oE '[0-9]+$' || true)"

if [[ -z "${ID}" ]]; then
  echo "ERROR: cannot resolve bot user ID for ${APP_SLUG}[bot] (offline?)." >&2
  echo "Set BOT_USER_ID to the bot account user ID" >&2
  echo "(gh api users/${APP_SLUG}%5Bbot%5D --jq .id), not APP_ID." >&2
  exit 1
fi
printf '%s' "${ID}" > "${CACHE_FILE}" 2>/dev/null || true
printf '%s' "${ID}"
