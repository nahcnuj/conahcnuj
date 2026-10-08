#!/usr/bin/env bash
# Print the GitHub App slug (the prefix of the `<slug>[bot]` login).
# Order: APP_SLUG from app.env when set to a real value, then GET /app with
# a short-lived App JWT signed from APP_ID and the private key, which is the
# only source that cannot go stale.
#
# The slug is deliberately never read from Actions secrets. It is public
# information (the bot login, and for this repository also the repository
# name), and registering it as a secret made Actions mask every occurrence
# of it in the job log - pull request URLs included. Exits non-zero with
# guidance when neither source works.
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

SLUG="${APP_SLUG:-}"
if [[ -n "${SLUG}" && "${SLUG}" != "<"* ]]; then
  printf '%s' "${SLUG}"
  exit 0
fi

if ! JWT="$(bash "${DIR}/get-token.sh" --print-jwt)"; then
  echo "ERROR: cannot sign an App JWT to look the slug up (APP_ID / PRIVATE_KEY_PATH?)." >&2
  echo "Set APP_SLUG in gh-app/app.env (see app.env.example)." >&2
  exit 1
fi

LOOKUP="$(curl -fsSL \
  -H "Authorization: Bearer ${JWT}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "${API_BASE}/app" 2>/dev/null || true)"

# Compact the JSON first so the pattern does not depend on GitHub's
# spacing, and take the only "slug" key the app object carries.
SLUG="$(printf '%s' "${LOOKUP}" | tr -d '\n \t' | sed -n 's/.*"slug":"\([^"]*\)".*/\1/p')"
if [[ ! "${SLUG}" =~ ^[A-Za-z0-9-]+$ ]]; then
  echo "ERROR: cannot resolve the App slug from GET ${API_BASE}/app." >&2
  echo "Set APP_SLUG in gh-app/app.env (see app.env.example)." >&2
  exit 1
fi
printf '%s' "${SLUG}"
