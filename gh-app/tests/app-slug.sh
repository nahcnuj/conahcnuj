#!/usr/bin/env bash
# app-slug.sh: app.env value wins (no key/network); a placeholder is never
# returned, and a slug that cannot be resolved fails with guidance.
# Usage: bash app-slug.sh <staged gh-app dir>
set -euo pipefail

STAGE="${1:?staged gh-app dir required}"

# The shared fixture sets APP_SLUG=conahcnuj: it must come back as-is,
# without signing a JWT or reaching the network (neither exists here).
OUT="$(bash "${STAGE}/app-slug.sh")"
if [[ "${OUT}" != "conahcnuj" ]]; then
  echo "FAIL: app-slug.sh returned '${OUT}', expected 'conahcnuj'" >&2
  exit 1
fi
echo "PASS app-slug.sh prefers the app.env value (no key / no network)"

# The cases below rewrite app.env, and the tests that run after this one
# read the shared staged copy: work on a private copy of the scripts.
WORK="$(dirname "${STAGE}")/app-slug-work"
mkdir -p "${WORK}"
cp "${STAGE}/app-slug.sh" "${STAGE}/get-token.sh" "${WORK}/"

# A placeholder is not a value: fall through to the lookup, which has no
# key to sign a JWT with, and fail with guidance instead of printing it.
cat > "${WORK}/app.env" <<'EOF'
APP_ID=00000
INSTALLATION_ID=00000
APP_SLUG="<your-app-name>"
PRIVATE_KEY_PATH=/tmp/nonexistent-conahcnuj-key.pem
BASH_EXE="bash"
EOF
OUT="$(bash "${WORK}/app-slug.sh" 2>&1 || true)"
if [[ "${OUT}" != *"Set APP_SLUG in gh-app/app.env"* ]]; then
  echo "FAIL: unresolvable slug should print guidance:" >&2
  echo "${OUT}" >&2
  exit 1
fi
echo "PASS app-slug.sh refuses to return a placeholder (no key)"

# With a key the lookup goes out to the API: offline it must report the
# failure rather than hang or hand back something unusable.
if command -v openssl >/dev/null 2>&1; then
  openssl genrsa -out "${WORK}/key.pem" 2048 2>/dev/null
  cat > "${WORK}/app.env" <<EOF
APP_ID=12345
INSTALLATION_ID=67890
APP_SLUG="<your-app-name>"
PRIVATE_KEY_PATH="${WORK}/key.pem"
BASH_EXE="bash"
EOF
  OUT="$(GH_APP_API_BASE="http://127.0.0.1:9" bash "${WORK}/app-slug.sh" 2>&1 || true)"
  if [[ "${OUT}" != *"cannot resolve the App slug"* ]]; then
    echo "FAIL: offline lookup should report the failure:" >&2
    echo "${OUT}" >&2
    exit 1
  fi
  echo "PASS app-slug.sh reports an unresolvable lookup"

  # The extraction itself, offline: a canned /app body over file://.
  printf '{"id":1,"slug":"lookup-slug","name":"x"}' > "${WORK}/app"
  if curl -fsSL -H "Accept: application/vnd.github+json" "file://${WORK}/app" >/dev/null 2>&1; then
    OUT="$(GH_APP_API_BASE="file://${WORK}" bash "${WORK}/app-slug.sh")"
    if [[ "${OUT}" != "lookup-slug" ]]; then
      echo "FAIL: lookup returned '${OUT}', expected 'lookup-slug'" >&2
      exit 1
    fi
    echo "PASS app-slug.sh returns the slug resolved from the API"
  else
    echo "SKIP app-slug.sh lookup (curl has no file:// support)"
  fi
else
  echo "SKIP app-slug.sh lookup (openssl unavailable)"
fi
