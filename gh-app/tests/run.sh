#!/usr/bin/env bash
# Offline mock-test runner (no private key, no secrets, no network).
# Stages the scripts into a temp dir, then runs each concern file in this
# directory. CI executes this file (see .github/workflows/ci.yml).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_SCRIPTS="$(cd "${HERE}/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Stage a copy of the scripts under test, plus a minimalist app.env.
# The cache path returns before any JWT signing, so no real values are needed.
mkdir -p "${TMP}/gh-app"
cd "${REPO_SCRIPTS}" || exit 1
cp get-token.sh git-credential-helper.sh api-commit.sh bot-user-id.sh "${TMP}/gh-app/"
cd "${HERE}" || exit 1
cat > "${TMP}/gh-app/app.env" <<'EOF'
APP_ID=00000
INSTALLATION_ID=00000
APP_SLUG=conahcnuj
PRIVATE_KEY_PATH=/tmp/nonexistent.pem
BASH_EXE="C:/Program Files/Git/bin/bash.exe"
EOF

for t in "${HERE}/"*.sh; do
  if [[ "$(basename "${t}")" == "run.sh" ]]; then
    continue
  fi
  echo "--- $(basename "${t}")"
  bash "${t}" "${TMP}/gh-app"
done

echo "ALL MOCK TESTS PASSED"
