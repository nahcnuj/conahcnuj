#!/usr/bin/env bash
# Plugin runtime smoke test, end to end from install.ps1:
# install to a temp dir, stage the INSTALLED files (not the repo files),
# compile the installed plugin, load it against the installed gh-app dir
# (fake app.env overlaid), and assert the shell.env contract (GIT_CONFIG
# identity + alias.vc) plus the git-commit redirect via smoke-run.js.
# Needs node/npm (typescript from plugins/package.json) and pwsh/powershell
# for install.ps1. No secrets, no GitHub network.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
TMP="$(mktemp -d)"
STAGE="${HERE}/.smoke"
trap 'rm -rf "${TMP}" "${STAGE}"' EXIT

if command -v pwsh >/dev/null 2>&1; then
  PS=pwsh
elif command -v powershell >/dev/null 2>&1; then
  PS=powershell
else
  echo "ERROR: pwsh/powershell not found (needed to run install.ps1)" >&2
  exit 1
fi

# 1) Install exactly like a user would, into a temp dir.
"${PS}" -NoProfile -NonInteractive -ExecutionPolicy Bypass \
  -File "${REPO}/install.ps1" -Destination "${TMP}/inst" >/dev/null
INST="${TMP}/inst"

(cd "${HERE}" && npm ci --no-audit --no-fund)

# 2) Stage the INSTALLED files under a fixed literal path with the same
#    relative layout (so __dirname resolution finds the staged gh-app dir).
#    smoke-run.js must not require() an argv-provided path (CodeQL
#    path-injection), hence the fixed ./.smoke/ location.
mkdir -p "${STAGE}/src" "${STAGE}/gh-app"
cp "${INST}/plugins/gh-app-token.ts" "${STAGE}/src/"
cp "${HERE}/plugin-stub.d.ts" "${STAGE}/src/"
cp "${INST}/gh-app/"*.sh "${STAGE}/gh-app/"
# Fake app.env over the staged copy. The bot ID is auto-resolved from the
# public API (APP_SLUG must be real); bogus BASH_EXE keeps get-token.sh from
# running: no key, no token issuance. APP_ID etc. come from the environment
# when provided (CI secrets), else self-explanatory fakes.
cat > "${STAGE}/gh-app/app.env" <<EOF
APP_ID=${APP_ID:-00000}
INSTALLATION_ID=${INSTALLATION_ID:-00000}
APP_SLUG=conahcnuj
PRIVATE_KEY_PATH=/tmp/nonexistent.pem
BASH_EXE=/nonexistent-bash
EOF
cat > "${STAGE}/src/tsconfig.json" <<'EOF'
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "CommonJS",
    "moduleResolution": "Node",
    "esModuleInterop": true,
    "strict": true,
    "skipLibCheck": true,
    "noEmit": false,
    "outDir": "../out",
    "types": ["node"],
    "baseUrl": ".",
    "paths": { "@opencode-ai/plugin": ["./plugin-stub.d.ts"] }
  },
  "include": ["gh-app-token.ts", "plugin-stub.d.ts"]
}
EOF

# 3) @types/node resolves by walking up from the tsconfig dir to the repo's
#    node_modules (installed above).
"${HERE}/node_modules/.bin/tsc" -p "${STAGE}/src"

node "${HERE}/smoke-run.js" conahcnuj
