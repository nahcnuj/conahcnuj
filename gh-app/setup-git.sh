#!/usr/bin/env bash
# Configure the current git repository to operate as the GitHub App.
# Settings (APP_ID, APP_SLUG, BASH_EXE, ...) are read from app.env.
# Run from inside the repository root.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${HERE}/app.env"

# Real config wins; fall back to the committed example (e.g. fresh clone / CI).
if [[ ! -f "${ENV_FILE}" && -f "${HERE}/app.env.example" ]]; then
  ENV_FILE="${HERE}/app.env.example"
fi

set -a
# shellcheck source=gh-app/app.env.example
. "${ENV_FILE}"
set +a

BOT_NAME="${APP_SLUG}[bot]"
BOT_EMAIL="${APP_ID}+${APP_SLUG}[bot]@users.noreply.github.com"

HELPER="${HERE}/git-credential-helper.sh"
BASH_EXE="${BASH_EXE:-C:/Program Files/Git/bin/bash.exe}"
# shellcheck disable=SC2086
HELPER_CMD="!\"${BASH_EXE}\" \"${HELPER//\\//}\""

SCOPE="--local"
if [[ ! -d .git ]] && ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "WARNING: not inside a git repository; applying to --global instead." >&2
  SCOPE="--global"
fi

git config "${SCOPE}" user.name "${BOT_NAME}"
git config "${SCOPE}" user.email "${BOT_EMAIL}"
git config "${SCOPE}" credential.helper "${HELPER_CMD}"
git config "${SCOPE}" commit.gpgsign true

echo "Configured (${SCOPE}):"
git config --get-regexp "^(user\.(name|email)|credential\.helper|commit\.gpgsign)$" "${SCOPE}" 2>/dev/null || true
echo
echo "Test with: git ls-remote https://github.com/<owner>/<repo>.git HEAD"