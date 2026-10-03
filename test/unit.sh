#!/usr/bin/env bash
# Unit tests for the opencode plugin internals: compile plugins/gh-app-token.ts
# into a throwaway stage (fake gh-app dir next to it, so __dirname-based config
# loading works offline), then run unit-run.js against it.
# No secrets, no network beyond npm, no pwsh: the installed-file runtime path
# is covered separately by test/smoke.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
PLUGINS_DIR="${REPO}/plugins"
STAGE="${HERE}/.unit"
trap 'rm -rf "${STAGE}"' EXIT

(cd "${PLUGINS_DIR}" && npm ci --no-audit --no-fund)

# The test build is the plugin source plus a re-export of the internals.
# opencode's loader treats every module export as a plugin, so the shipped file
# must export GhAppTokenPlugin and nothing else; re-exporting here keeps that
# invariant intact. A renamed or dropped internal fails the compile below, it
# never silently weakens the suite.
mkdir -p "${STAGE}/src" "${STAGE}/gh-app"
cp "${PLUGINS_DIR}/gh-app-token.ts" "${STAGE}/src/gh-app-token.ts"
cat >> "${STAGE}/src/gh-app-token.ts" <<'EOF'

// Appended by test/unit.sh only.
export const __unit = {
  parseAppEnv,
  resolveBashExe,
  b64url,
  readBotIdCache,
  readTokenCache,
  parseBashCommand,
  isGitCommitCommand,
  commandWords,
  basename,
  executedCommands,
  isGitCommitInvocation,
  isDirectApiCommitCommand,
  formatModelLabel,
  matchesSessionModel,
  redirectToVerifiedCommit,
  COMMIT_RULES,
  VC_USAGE,
}
EOF

# Fake app.env: APP_SLUG must be present (the only required key), bogus
# BASH_EXE keeps get-token.sh from running (no key, no token issuance).
cat > "${STAGE}/gh-app/app.env" <<EOF
APP_ID=00000
INSTALLATION_ID=00000
APP_SLUG=conahcnuj
PRIVATE_KEY_PATH=/tmp/nonexistent.pem
BASH_EXE=/nonexistent-bash
EOF
# Seed the bot-ID cache so the plugin factory resolves the identity without
# touching the network (the public lookup shares runner IPs and gets
# rate-limited). Same offline trick as test/smoke.sh.
printf '331119074' > "${STAGE}/gh-app/bot-id.cache"
cat > "${STAGE}/src/tsconfig.json" <<'EOF'
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "esModuleInterop": true,
    "strict": true,
    "skipLibCheck": true,
    "noEmit": false,
    "outDir": "../out",
    "types": ["node"]
  },
  "include": ["gh-app-token.ts"]
}
EOF

# @types/node and @opencode-ai/plugin must resolve from inside the stage tree
# (tsc walks up from the tsconfig dir, which no longer reaches plugins/node_modules).
mkdir -p "${STAGE}/node_modules"
cp -r "${PLUGINS_DIR}/node_modules/@types" "${STAGE}/node_modules/"
cp -r "${PLUGINS_DIR}/node_modules/@opencode-ai" "${STAGE}/node_modules/"
"${PLUGINS_DIR}/node_modules/.bin/tsc" -p "${STAGE}/src"

node "${HERE}/unit-run.js"