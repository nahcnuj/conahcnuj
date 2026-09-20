#!/usr/bin/env bash
set -euo pipefail
cd /c/Users/nahcnuj/conahcnuj
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${DIR}/gh-app/app.env"
if [[ ! -f "${ENV_FILE}" && -f "${DIR}/gh-app/app.env.example" ]]; then
  ENV_FILE="${DIR}/gh-app/app.env.example"
fi
set -a
# shellcheck source=gh-app/app.env.example
. "${ENV_FILE}"
set +a
bash "${DIR}/../gh-app/api-commit.sh" nahcnuj/conahcnuj fix/docs-verified-commit-limitation \
  -m "fix: restore README markdown formatting and add mock tests for Python date fallback" \
  --file "README.md=@README.md" \
  --file "gh-app/mock-test.sh=@gh-app/mock-test.sh"