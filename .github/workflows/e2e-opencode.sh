#!/usr/bin/env bash
# E2E test script for opencode plugin
# Runs opencode with various models and asserts git vc surfaces with clean exits
set -euo pipefail

run_e2e_model() {
  local model="$1"
  OPENCODE_CONFIG_DIR="${RUNNER_TEMP}/e2e-inst" \
    OPENCODE_DISABLE_AUTOUPDATE=true \
    OPENCODE_DISABLE_MODELS_FETCH=true \
    timeout 150 opencode run --format json --model "${model}" --dir "${RUNNER_TEMP}/e2e-fixture" --title e2e \
    "Commit the staged changes with message e2e test. Execute the necessary commands." \
    > "${RUNNER_TEMP}/e2e-out.jsonl" 2>"${RUNNER_TEMP}/e2e-err.log" || true

  JSONL="$(grep -h '^{' "${RUNNER_TEMP}/e2e-out.jsonl" || true)"
  TEXT="$(echo "${JSONL}" | jq -s -r '[.. | strings] | join("\n")')"
  echo "${TEXT}" | tail -5
  echo "=== tool diagnostics ==="
  echo "${JSONL}" | jq -r 'select(.type=="tool_use") | "\(.part.tool) status=\(.part.state.status) exit=\(.part.state.metadata.exit // "-") :: \(.part.state.input.command // .part.state.input.filePath // "?")"'

  # Bad: a bash call that neither succeeded (0), nor failed the
  # sandbox way (2: no remote), nor was hook-blocked (git commit
  # never executes: no exit at all), nor is git vc/api-commit.sh
  # failing due to missing remote/token (exit 1 is expected).
  BAD="$(echo "${JSONL}" | jq -c 'select(.type=="tool_use" and .part.tool=="bash") | {cmd: .part.state.input.command, exit: .part.state.metadata.exit} | select(.exit != 0 and .exit != 2 and (.exit != 1 or ((.cmd // "") | contains("git vc") | not) and ((.cmd // "") | contains("api-commit.sh") | not)) and (.exit != null or ((.cmd // "") | contains("git commit") | not))) | [.cmd, .exit] | @tsv' || true)"
  if echo "${TEXT}" | grep -q "git vc" && [ -z "${BAD}" ]; then
    return 0
  fi
  echo "E2E model ${model} unsuitable (missing git vc or bad exit: ${BAD})"
  return 1
}

MODELS="$(opencode models 2>/dev/null | grep -E '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || true)"
if [ -z "${MODELS}" ]; then MODELS="opencode/mimo-v2.5-free"; fi
echo "Available models:"
echo "${MODELS}"

# First model is the "default" - try it explicitly
DEFAULT_MODEL="$(echo "${MODELS}" | head -1)"
echo "E2E trying default model: ${DEFAULT_MODEL}"
if run_e2e_model "${DEFAULT_MODEL}"; then
  echo "E2E OK: 'git vc' surfaced naturally in a real opencode session"
  exit 0
fi

# Fall back to remaining models if default failed
for m in $(echo "${MODELS}" | tail -n +2); do
  echo "E2E trying fallback model: ${m}"
  if run_e2e_model "${m}"; then
    echo "E2E OK: 'git vc' surfaced naturally in a real opencode session"
    exit 0
  fi
done

echo "E2E FAIL: no model surfaced 'git vc' with clean exits" >&2
exit 1