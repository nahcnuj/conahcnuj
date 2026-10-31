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

# Bot user ID: app.env value wins, otherwise auto-resolved from the API.
# Resolution can fail (offline / rate-limited); that only affects the local
# git identity, which Verified commits do not depend on, so warn and continue
# rather than aborting the whole run (#736).
BOT_USER_ID=""
if BOT_USER_ID="$(bash "${HERE}/bot-user-id.sh" 2>/dev/null)"; then
  :
else
  BOT_USER_ID=""
fi
BOT_NAME="${APP_SLUG}[bot]"

HELPER="${HERE}/git-credential-helper.sh"
API_COMMIT="${HERE}/api-commit.sh"
BASH_EXE="${BASH_EXE:-C:/Program Files/Git/bin/bash.exe}"
HELPER_CMD="!\"${BASH_EXE}\" \"${HELPER//\\//}\""
API_COMMIT_CMD="!\"${BASH_EXE}\" \"${API_COMMIT//\\//}\""

SCOPE="--local"
if [[ ! -d .git ]] && ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "WARNING: not inside a git repository; applying to --global instead." >&2
  SCOPE="--global"
fi

git config "${SCOPE}" user.name "${BOT_NAME}"
if [[ -n "${BOT_USER_ID}" ]]; then
  BOT_EMAIL="${BOT_USER_ID}+${APP_SLUG}[bot]@users.noreply.github.com"
  git config "${SCOPE}" user.email "${BOT_EMAIL}"
else
  echo "WARNING: could not resolve bot user ID; skipping user.email." >&2
fi
git config "${SCOPE}" credential.helper "${HELPER_CMD}"
git config "${SCOPE}" commit.gpgsign false
# `git vc` is the verified-commit alias (see plugins/gh-app-token.ts). Mirror it
# into the (local or global) git config so it is available in every shell,
# not only inside an opencode session whose plugin injects it via GIT_CONFIG_*.
git config "${SCOPE}" alias.vc "${API_COMMIT_CMD}"

echo "Configured (${SCOPE}):"
git config ${SCOPE} --get-regexp "^(user\.(name|email)|credential\.helper|commit\.gpgsign|alias\.vc)$" 2>/dev/null || true
echo
echo "Test with: git ls-remote https://github.com/<owner>/<repo>.git HEAD"