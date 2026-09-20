#!/usr/bin/env bash
# End-to-end test: install.ps1 -> real `opencode run` -> `git vc` appears.
#
# Flow (no secrets, no GitHub network, no real LLM):
#   1. install.ps1 into a temp dir (exactly like a user install).
#   2. Overlay a fake app.env (BOT_USER_ID wins over auto-resolve; bogus
#      BASH_EXE keeps get-token.sh from running).
#   3. Start a scripted OpenAI-compatible stub model (e2e/stub.js) that makes
#      exactly one tool call: bash `git commit -m "e2e test"`.
#   4. Run real `opencode run` with OPENCODE_CONFIG_DIR pointed at the temp
#      install, in a fixture repo (no AGENTS.md) with a staged change.
#   5. Assert the output contains `git vc`. That string can only originate
#      from the REAL plugin hook blocking `git commit`, proving install ->
#      load -> env -> hook works end to end in a real session.
#
# Needs: opencode binary, node, pwsh/powershell, git. The stub model makes
# this fully deterministic (no LLM flakiness).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"; kill "${SRV_PID:-}" 2>/dev/null || true' EXIT

for cmd in opencode node git; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "ERROR: ${cmd} not found on PATH" >&2
    exit 1
  fi
done
if command -v pwsh >/dev/null 2>&1; then
  PS=pwsh
elif command -v powershell >/dev/null 2>&1; then
  PS=powershell
else
  echo "ERROR: pwsh/powershell not found (needed to run install.ps1)" >&2
  exit 1
fi

# 1) Install exactly like a user would.
"${PS}" -NoProfile -NonInteractive -ExecutionPolicy Bypass \
  -File "${REPO}/install.ps1" -Destination "${TMP}/inst" >/dev/null
INST="${TMP}/inst"
test -f "${INST}/plugins/gh-app-token.ts"
test -f "${INST}/gh-app/api-commit.sh"

# 2) Fake app.env over the installed copy.
cat > "${INST}/gh-app/app.env" <<'EOF'
APP_ID=00000
BOT_USER_ID=999
INSTALLATION_ID=00000
APP_SLUG=smokeapp
PRIVATE_KEY_PATH=/tmp/nonexistent.pem
BASH_EXE=/nonexistent-bash
EOF

# opencode.json with the stub provider (v1 schema; literal dummy key: the
# stub accepts anything and runs locally).
PORT=18081
cat > "${INST}/opencode.json" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "stub/e2e-stub",
  "provider": {
    "stub": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "e2e stub (local)",
      "options": { "baseURL": "http://127.0.0.1:${PORT}/v1", "apiKey": "dummy" },
      "models": { "e2e-stub": { "name": "e2e stub" } }
    }
  }
}
EOF

# 3) Fixture repo (no AGENTS.md): the agent can only discover `git vc`
#    through the plugin hook, not repo docs.
FIX="${TMP}/fixture"
mkdir -p "${FIX}"
git -C "${FIX}" init -q
git -C "${FIX}" config user.email "e2e@test"
git -C "${FIX}" config user.name "e2e"
printf 'hello\n' > "${FIX}/file.txt"
git -C "${FIX}" add -A
git -C "${FIX}" commit -qm init
printf 'change\n' >> "${FIX}/file.txt"
git -C "${FIX}" add file.txt

# 4) Stub model + real opencode run.
node "${HERE}/stub.js" "${PORT}" >/dev/null 2>&1 &
SRV_PID=$!
for ((i = 0; i < 30; i++)); do
  if (echo > /dev/tcp/127.0.0.1/${PORT}) >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
OUT="$(OPENCODE_CONFIG_DIR="${INST}" \
  OPENCODE_DISABLE_AUTOUPDATE=true \
  OPENCODE_DISABLE_MODELS_FETCH=true \
  timeout 240 opencode run --dir "${FIX}" --title e2e \
  "Commit the staged changes with message e2e test" 2>&1 || true)"
echo "${OUT}" | tail -15

# 5) Assert.
if [[ "${OUT}" != *"git vc"* ]]; then
  echo "E2E FAIL: 'git vc' not found in opencode output" >&2
  exit 1
fi
echo "E2E OK: 'git vc' surfaced naturally in a real opencode session"
