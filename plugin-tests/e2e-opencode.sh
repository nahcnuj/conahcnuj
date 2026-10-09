#!/usr/bin/env bash
# E2E test script for opencode plugin
# Runs opencode with various models in parallel and asserts git vc
# surfaces with clean exits
set -euo pipefail

# Filesystem-safe slot name for a model id.
slot_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

# One model attempt within a round. Every attempt runs in its own copy
# of the installed plugin tree (OPENCODE_CONFIG_DIR) and of the fixture
# repo, and writes its own output files: parallel opencode sessions
# must not share the fixture's git index (concurrent git vc runs
# would collide on index.lock) or the config dir.
run_e2e_model() {
  local model="$1" round="$2"
  local slot slot_dir status_file opid rc=0
  slot="$(slot_name "${model}")"
  slot_dir="${E2E_DIR}/r${round}-${slot}"
  status_file="${E2E_DIR}/results/r${round}-${slot}.status"
  mkdir -p "${slot_dir}"
  # Guarantee a verdict even if this attempt dies unexpectedly
  # (set -e inside the subshell): the orchestrator polls these files,
  # so a missing one would stall the wait until the deadline. The path
  # is expanded here, while `slot` is still in scope — the EXIT trap
  # runs after this function's locals are gone. An explicit verdict is
  # never overwritten.
  # shellcheck disable=SC2064  # expand $status_file now; it is unset at EXIT
  trap "[ -f '${status_file}' ] || echo fail > '${status_file}'" EXIT
  cp -a "${RUNNER_TEMP}/e2e-inst" "${slot_dir}/inst"
  cp -a "${RUNNER_TEMP}/e2e-fixture" "${slot_dir}/fixture"

  OPENCODE_CONFIG_DIR="${slot_dir}/inst" \
    OPENCODE_DISABLE_AUTOUPDATE=true \
    OPENCODE_DISABLE_MODELS_FETCH=true \
    timeout "${E2E_ATTEMPT_TIMEOUT}" opencode run --format json --model "${model}" --dir "${slot_dir}/fixture" --title e2e \
    "Commit the staged changes with message e2e test. Execute the necessary commands." \
    > "${slot_dir}/out.jsonl" 2> "${slot_dir}/err.log" &
  opid=$!
  # The orchestrator stops this attempt with a signal once another model
  # already surfaced `git vc`. A foreground `timeout`/opencode would ignore
  # that signal and outlive the subshell, holding the fixture directory open;
  # on Windows the EXIT trap's `rm -rf` then fails with "Device or resource
  # busy" and, under `set -e`, turns the passing run into exit 1. Running the
  # attempt in the background lets the TERM/INT trap kill opencode (timeout
  # forwards the signal) so the fixture is released.
  # shellcheck disable=SC2064  # expand $opid now; it is local to this call
  trap "kill '${opid}' 2>/dev/null || true" TERM INT
  wait "${opid}" || rc=$?

  JSONL="$(grep -h '^{' "${slot_dir}/out.jsonl" || true)"
  TEXT="$(echo "${JSONL}" | jq -s -r '[.. | strings] | join("\n")')"
  echo "=== ${model}: last lines ==="
  echo "${TEXT}" | tail -5
  echo "=== ${model}: tool diagnostics ==="
  echo "${JSONL}" | jq -r 'select(.type=="tool_use") | "\(.part.tool) status=\(.part.state.status) exit=\(.part.state.metadata.exit // "-") :: \(.part.state.input.command // .part.state.input.filePath // "?")"'
  echo "=== ${model}: opencode rc=${rc}$( [ "${rc}" = 124 ] && echo " (timeout: exceeded ${E2E_ATTEMPT_TIMEOUT}s)" ) ==="
  echo "=== ${model}: stderr ==="
  cat "${slot_dir}/err.log" || true

  # Bad: a bash call that concluded with an unexplained failure -
  # neither success (0), nor the sandbox norm (2: no remote), nor a
  # git vc/api-commit.sh call failing due to missing remote/token
  # (exit 1 is expected). Calls with no exit (null) never concluded
  # and are benign: the model often interrupts a long command, and a
  # hook-blocked `git commit` likewise never executes.
  BAD="$(echo "${JSONL}" | jq -c 'select(.type=="tool_use" and .part.tool=="bash") | {cmd: .part.state.input.command, exit: .part.state.metadata.exit} | select(.exit != null and .exit != 0 and .exit != 2 and (.exit != 1 or ((.cmd // "") | contains("git vc") | not) and ((.cmd // "") | contains("api-commit.sh") | not))) | [.cmd, .exit] | @tsv' || true)"
  if echo "${TEXT}" | grep -q "git vc" && [ -z "${BAD}" ]; then
    echo ok > "${status_file}"
    return 0
  fi
  echo "E2E model ${model} unsuitable (missing git vc or bad exit: ${BAD})"
  echo fail > "${status_file}"
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
# Cleanup is best-effort: a lingering opencode process can keep a fixture
# directory busy on Windows, and a failing trap must not flip the script's
# verdict (under `set -e` it would override the explicit exit status).
trap 'rm -rf "${E2E_DIR}" 2>/dev/null || true' EXIT

mapfile -t E2E_MODELS <<< "${MODELS}"

# The free models are a shared service that can be briefly unavailable
# or rate-limit every parallel attempt for a long stretch (empty output,
# opencode rc=124). A session also needs several model turns and, under
# load, a turn can take tens of seconds, so the old 150s budget kept
# SIGTERMing attempts that were still running their first commands. One
# retry round separates a transient outage from a real regression: a
# broken plugin fails both rounds, a passing round ends the test at once.
E2E_ATTEMPT_TIMEOUT=300
E2E_MAX_ROUNDS=2
E2E_SUCCESS=""
for ((round = 1; round <= E2E_MAX_ROUNDS; round++)); do
  echo "E2E round ${round}/${E2E_MAX_ROUNDS}"
  declare -A E2E_PIDS=()
  for m in "${E2E_MODELS[@]}"; do
    slot="$(slot_name "${m}")"
    run_e2e_model "${m}" "${round}" > "${E2E_DIR}/r${round}-${slot}.log" 2>&1 &
    E2E_PIDS[$!]="${m}"
  done

  # Fail fast: stop the remaining attempts once any model surfaces
  # `git vc`. Every attempt is bounded by E2E_ATTEMPT_TIMEOUT; the
  # deadline is the hard safety net for a wedged attempt, with a minute
  # of slack past that timeout.
  E2E_DEADLINE=$((SECONDS + E2E_ATTEMPT_TIMEOUT + 60))
  while [ ${#E2E_PIDS[@]} -gt 0 ] && [ "${SECONDS}" -lt "${E2E_DEADLINE}" ]; do
    for pid in "${!E2E_PIDS[@]}"; do
      slot="$(slot_name "${E2E_PIDS[${pid}]}")"
      status="${E2E_DIR}/results/r${round}-${slot}.status"
      if [ -f "${status}" ]; then
        if [ "$(cat "${status}")" = "ok" ]; then
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

  # Diagnostics for every attempt of this round (the CI log is the
  # run's only record), then the round verdict.
  for m in "${E2E_MODELS[@]}"; do
    slot="$(slot_name "${m}")"
    log="${E2E_DIR}/r${round}-${slot}.log"
    if [ -f "${log}" ]; then
      cat "${log}"
    fi
  done

  if [ -n "${E2E_SUCCESS}" ]; then
    break
  fi

  # Drop stragglers before the next round so a wedged attempt's
  # timeout does not stack up behind the retry.
  for pid in "${!E2E_PIDS[@]}"; do
    kill "${pid}" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  if [ "${round}" -lt "${E2E_MAX_ROUNDS}" ]; then
    echo "E2E round ${round} surfaced no 'git vc'; retrying"
    sleep 10
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

echo "E2E FAIL: no model surfaced 'git vc' with clean exits" >&2
exit 1
