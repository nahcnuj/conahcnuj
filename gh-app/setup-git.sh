#!/usr/bin/env bash
# Configure the current git repository to operate as the GitHub App "conahcnuj".
# Run from inside the repository root.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${HERE}/git-credential-helper.sh"
BASH_EXE="C:/Program Files/Git/bin/bash.exe"
HELPER_CMD="!\"${BASH_EXE}\" \"${HELPER//\\//}\""

SCOPE="--local"
if [[ ! -d .git ]] && ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "WARNING: not inside a git repository; applying to --global instead." >&2
  SCOPE="--global"
fi

git config "${SCOPE}" user.name "conahcnuj[bot]"
git config "${SCOPE}" user.email "<your-app-id>+conahcnuj[bot]@users.noreply.github.com"
git config "${SCOPE}" credential.helper "${HELPER_CMD}"
git config "${SCOPE}" commit.gpgsign false

echo "Configured (${SCOPE}):"
git config --get-regexp "^(user\.(name|email)|credential\.helper|commit\.gpgsign)$" "${SCOPE}" 2>/dev/null || true
echo
echo "Test with: git ls-remote https://github.com/<owner>/<repo>.git HEAD"