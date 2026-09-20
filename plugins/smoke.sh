#!/usr/bin/env bash
# Plugin runtime smoke test: compile the plugin, load it against a fake
# gh-app dir (fake app.env, unreachable BASH_EXE so no token/key is needed),
# and assert the shell.env contract + git-commit redirect via smoke-run.js.
# Needs node + npm (typescript comes from plugins/package.json). No secrets,
# no GitHub network.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
STAGE="${HERE}/.smoke"
trap 'rm -rf "${TMP}" "${STAGE}"' EXIT

# NOTE: no `npm --prefix` here: native npm on Windows ignores an msys-style
# absolute prefix, so run inside the dir instead.
(cd "${HERE}" && npm install --no-audit --no-fund)

mkdir -p "${TMP}/smoke/plugins" "${TMP}/smoke/gh-app"
cp "${HERE}/gh-app-token.ts" "${HERE}/plugin-stub.d.ts" "${TMP}/smoke/plugins/"
cat > "${TMP}/smoke/plugins/tsconfig.json" <<'EOF'
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
cat > "${TMP}/smoke/gh-app/app.env" <<'EOF'
APP_ID=00000
BOT_USER_ID=999
INSTALLATION_ID=00000
APP_SLUG=smokeapp
PRIVATE_KEY_PATH=/tmp/nonexistent.pem
BASH_EXE=/nonexistent-bash
EOF

# @types/node must resolve for the compile: tsc walks up from the tsconfig
# dir looking for node_modules/@types, so stage a copy at $TMP root.
mkdir -p "${TMP}/node_modules"
cp -r "${HERE}/node_modules/@types" "${TMP}/node_modules/"
(cd "${HERE}" && npm exec -- tsc -p "${TMP}/smoke/plugins")
# Stage artifact + fake gh-app at a fixed literal path with the same relative
# layout (so __dirname resolution finds the fake app.env). smoke-run.js must
# not require() an argv-provided path (CodeQL path-injection).
mkdir -p "${STAGE}"
cp -r "${TMP}/smoke/out" "${TMP}/smoke/gh-app" "${STAGE}/"
node "${HERE}/smoke-run.js" 999
