#!/usr/bin/env bash
# E2E test script for opencode plugin
# Runs opencode with various models in parallel and asserts git vc
# surfaces with clean exits
set -euo pipefail

# Filesystem-safe slot name for a model id.
slot_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

# One model attempt. Every attempt runs in its own copy of the
# installed plugin tree (OPENCODE_CONFIG_DIR) and of the fixture
# repo, and writes its own output files: parallel opencode sessions
# must not share the fixture's git index (concurrent git vc runs
# would collide on index.lock) or the config dir.
run_e2e_model() {
  local model="$1"
  local slot home
  slot="$(slot_name "${model}")"
  home="${E2E_DIR}/${slot}"
  mkdir -p "${home}"
  # Guarantee a verdict even if this attempt dies unexpectedly
  # (set -e inside the subshell): the orchestrator polls these
  # files, so a missing one would stall the wait until the
  # deadline. An explicit verdict is never overwritten.
  trap '[ -f "${E2E_DIR}/results/${slot}.status" ] || echo fail > "${E2E_DIR}/results/${slot}.status"' EXIT
  cp -a "${RUNNER_TEMP}/e2e-inst" "${home}/inst"
  cp -a "${RUNNER_TEMP}/e2e-fixture" "${home}/fixture"

  OPENCODE_CONFIG_DIR="${home}/inst" \
    OPENCODE_DISABLE_AUTOUPDATE=true \
    OPENCODE_DISABLE_MODELS_FETCH=true \
    timeout 150 opencode run --format json --model "${model}" --dir "${home}/fixture" --title e2e \
    "Commit the staged changes with message e2e test. Execute the necessary commands." \
    > "${home}/out.jsonl" 2> "${home}/err.log" || true

  JSONL="$(grep -h '^{' "${home}/out.jsonl" || true)"
  TEXT="$(echo "${JSONL}" | jq -s -r '[.. | strings] | join("\n")')"
  echo "=== ${model}: last lines ==="
  echo "${TEXT}" | tail -5
  echo "=== ${model}: tool diagnostics ==="
  echo "${JSONL}" | jq -r 'select(.type=="tool_use") | "\(.part.tool) status=\(.part.state.status) exit=\(.part.state.metadata.exit // "-") :: \(.part.state.input.command // .part.state.input.filePath // "?")"'

  # Bad: a bash call that concluded with an unexplained failure -
  # neither success (0), nor the sandbox norm (2: no remote), nor a
  # git vc/api-commit.sh call failing due to missing remote/token
  # (exit 1 is expected). Calls with no exit (null) never concluded
  # and are benign: the model often interrupts a long command, and a
  # hook-blocked `git commit` likewise never executes.
  BAD="$(echo "${JSONL}" | jq -c 'select(.type=="tool_use" and .part.tool=="bash") | {cmd: .part.state.input.command, exit: .part.state.metadata.exit} | select(.exit != null and .exit != 0 and .exit != 2 and (.exit != 1 or ((.cmd // "") | contains("git vc") | not) and ((.cmd // "") | contains("api-commit.sh") | not))) | [.cmd, .exit] | @tsv' || true)"
  if echo "${TEXT}" | grep -q "git vc" && [ -z "${BAD}" ]; then
    echo ok > "${E2E_DIR}/results/${slot}.status"
    return 0
  fi
  echo "E2E model ${model} unsuitable (missing git vc or bad exit: ${BAD})"
  echo fail > "${E2E_DIR}/results/${slot}.status"
  return 1
}

MODELS="$(opencode models 2>/dev/null | grep -E '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || true)"
if [ -z "${MODELS}" ]; then MODELS="opencode/mimo-v2.5-free"; fi
echo "Available models:"
echo "${MODELS}"
# The first model is the explicit default (not "all models"); the
# rest are fallbacks. All attempts race in parallel and the first
# success wins, so a healthy default still decides the run while
# slow fallbacks no longer add up sequentially.
DEFAULT_MODEL="$(echo "${MODELS}" | head -1)"
echo "E2E default model: ${DEFAULT_MODEL}"

E2E_DIR="${RUNNER_TEMP}/e2e-parallel"
rm -rf "${E2E_DIR}"
mkdir -p "${E2E_DIR}/results"
trap 'rm -rf "${E2E_DIR}"' EXIT

mapfile -t E2E_MODELS <<< "${MODELS}"
declare -A E2E_PIDS=()
for m in "${E2E_MODELS[@]}"; do
  slot="$(slot_name "${m}")"
  run_e2e_model "${m}" > "${E2E_DIR}/${slot}.log" 2>&1 &
  E2E_PIDS[$!]="${m}"
done

# Fail fast: stop the remaining attempts once any model surfaces
# `git vc`. Every attempt is bounded by its own `timeout 150`; the
# deadline is the hard safety net for a wedged attempt.
E2E_SUCCESS=""
E2E_DEADLINE=$((SECONDS + 300))
while [ ${#E2E_PIDS[@]} -gt 0 ] && [ "${SECONDS}" -lt "${E2E_DEADLINE}" ]; do
  for pid in "${!E2E_PIDS[@]}"; do
    slot="$(slot_name "${E2E_PIDS[${pid}]}")"
    if [ -f "${E2E_DIR}/results/${slot}.status" ]; then
      if [ "$(cat "${E2E_DIR}/results/${slot}.status")" = "ok" ]; then
        E2E_SUCCESS="${E2E_PIDS[${pid}]}"
      fi
      unset "E2E_PIDS[${pid}]"
    fi
  done
  if [ -n "${E2E_SUCCESS}" ]; then
    break
  fi
  sleep 2
done

# Diagnostics for every attempt (the CI log is the run's only
# record), then the verdict.
for m in "${E2E_MODELS[@]}"; do
  slot="$(slot_name "${m}")"
  if [ -f "${E2E_DIR}/${slot}.log" ]; then
    cat "${E2E_DIR}/${slot}.log"
  fi
done

if [ -n "${E2E_SUCCESS}" ]; then
  for pid in "${!E2E_PIDS[@]}"; do
    kill "${pid}" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  echo "E2E OK: 'git vc' surfaced naturally in a real opencode session (${E2E_SUCCESS})"
  exit 0
fi

if [ ${#E2E_PIDS[@]} -gt 0 ]; then
  for pid in "${!E2E_PIDS[@]}"; do
    kill "${pid}" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  echo "E2E FAIL: timed out waiting for model attempts" >&2
  exit 1
fi

echo "E2E FAIL: no model surfaced 'git vc' with clean exits" >&2
exit 1
