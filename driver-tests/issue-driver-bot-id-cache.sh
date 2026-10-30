#!/usr/bin/env bash
# issue-driver.yml must resolve and cache the bot user ID while the App key is
# available. The unauthenticated public lookup shares runner IPs and is
# rate-limited, and leaving it to setup-git.sh on the run path made the driver
# exit before it could start (failed to resolve the issue).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
WF="${REPO}/.github/workflows/issue-driver.yml"

[[ -f "${WF}" ]] || { echo "FAIL: missing ${WF}"; exit 1; }

if ! grep -Fq 'BOT_USER_ID=' "${WF}" || ! grep -Fq 'bash gh-app/bot-user-id.sh' "${WF}"; then
  echo "FAIL: issue-driver.yml must resolve the bot user ID during staging" >&2
  exit 1
fi

if ! grep -Fq 'gh-app/bot-id.cache' "${WF}"; then
  echo "FAIL: issue-driver.yml must cache the resolved bot user ID" >&2
  exit 1
fi

echo "issue-driver bot-ID cache test passed"
