#!/usr/bin/env bash
# Print the bot account user ID (<slug>[bot]) for noreply email attribution.
# Uses BOT_USER_ID from app.env when set to a real value; otherwise looks it
# up via the public GitHub API (no auth needed). Exits non-zero with guidance
# when neither works (e.g. offline).
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

ID="${BOT_USER_ID:-}"
if [[ -n "${ID}" && "${ID}" != "<"* ]]; then
  printf '%s' "${ID}"
  exit 0
fi

if [[ -z "${APP_SLUG:-}" || "${APP_SLUG}" == "<"* ]]; then
  echo "ERROR: BOT_USER_ID is not set and APP_SLUG is missing." >&2
  echo "Set BOT_USER_ID to the bot account user ID" >&2
  echo "(gh api users/<slug>%5Bbot%5D --jq .id), not APP_ID." >&2
  exit 1
fi

LOOKUP="$(curl -fsSL "${API_BASE}/users/${APP_SLUG}%5Bbot%5D" 2>/dev/null || true)"
ID="$(printf '%s' "${LOOKUP}" | tr -d '\n \t' | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')"
if [[ -z "${ID}" ]]; then
  echo "ERROR: cannot resolve bot user ID for ${APP_SLUG}[bot] (offline?)." >&2
  echo "Set BOT_USER_ID to the bot account user ID" >&2
  echo "(gh api users/${APP_SLUG}%5Bbot%5D --jq .id), not APP_ID." >&2
  exit 1
fi
printf '%s' "${ID}"
