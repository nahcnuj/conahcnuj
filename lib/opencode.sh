#!/usr/bin/env bash
# opencode wrapper for conahcnuj
# Provides model enumeration and hands the same opencode session to the next
# model when the current model cannot complete the work. A failed round sets
# OPENCODE_ROUND_ENVIRONMENT, so the driver can tell "this provider is down"
# apart from "this model is not good enough". A round cut short by a provider
# rate limit sets OPENCODE_ROUND_RATE_LIMITED: opencode sits out its own
# retry backoff ("Rate limit exceeded. Please try again later.") with nothing
# on stdout, so the driver stops the process and moves on without waiting
# (#155).
#
# opencode's own output is a stream of JSON events; lib/opencode-render.sh
# turns it into the driver's run log, one context header per block. The stream
# is filtered as it arrives instead of being dumped at the end, so the SHA /
# branch / diff in every header describe the moment that block was produced.

set -euo pipefail

# Not HERE: bin/conahcnuj.sh owns that name and resolves ../gh-app with it, so
# overwriting it here would break the driver's api-commit.sh / setup-git.sh
# paths. Sourcing a lib must not clobber the caller's variables.
OPENCODE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENCODE_RENDER_SH="${OPENCODE_LIB_DIR}/opencode-render.sh"

# Whether the round that just finished died on an environment error: the
# provider is unreachable, its credentials were rejected, or the transport
# broke. Anything else (a model that cannot do the work) leaves this "false".
# opencode_run sets it for every round so the driver can tell "this provider
# is down" apart from "this model is not good enough" -- only the former says
# anything about the provider's other models (#149).
OPENCODE_ROUND_ENVIRONMENT="false"

# Whether the round that just finished died because the model itself is gone:
# the provider reports it as deprecated, removed, unavailable or otherwise
# unknown. Unlike an environment error this is specific to one model, so the
# driver remembers only that model as dead (never the whole provider) and skips
# it in later rounds (#209). opencode_run sets it for every round.
OPENCODE_ROUND_MODEL_GONE="false"

# Whether the round that just finished was cut short by a provider rate limit.
# opencode retries "Rate limit exceeded. Please try again later." with its own
# exponential backoff, emitting nothing usable on stdout for minutes, so the
# driver kills the process and tries the next model at once. Not an environment
# error: the provider works, its quota is simply exhausted for now, so its
# other models stay in the pool.
OPENCODE_ROUND_RATE_LIMITED="false"

# List available models, one per line. Test mode: $MOCK_OPENCODE_MODELS.
opencode_get_models() {
  if [[ "${OPENCODE_TEST_MODE:-0}" == "1" ]]; then
    printf '%s\n' "${MOCK_OPENCODE_MODELS:-}"
    return 0
  fi
  opencode models 2>/dev/null | grep -E '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
}

# What every round shares, whatever the model or the stage: the point of the run
# and who does what. This is deliberately one short paragraph. A model once read
# a long list of instructions (banned commands, warnings that a message is not a
# deliverable) as the task itself and answered with a commit message and a pull
# request title instead of writing code, so the paragraph states the division of
# labour and stops there: telling the coding agent how to work gets in its way.
opencode_agent_contract() {
  cat <<'EOF'
This run takes the issue (or the pull request being resumed) to the owner's approval. Your part is the change in the working tree: implement it and run the repository's own validation. The driver names the branch and creates the commit, the push, the pull request and the review request once you are done.
EOF
}

# Build the implementation prompt for a single model run.
# Args: issue_title issue_body [extra_context] [collected_context]
# A fresh implementation round (no extra_context) also lets the agent choose
# the feature branch via .branch-name; follow-up rounds (fix constraints,
# review feedback) keep the existing branch, so the instruction is omitted.
# collected_context is what the driver gathered deterministically before this
# run (unresolved review threads of a resumed PR, README.md / AGENTS.md, ...)
# and is appended as plain data: the contract below stays the only place that
# says anything about how to work, so adding material must not read as another
# instruction.
opencode_build_prompt() {
  local issue_title="${1}" issue_body="${2}" extra_context="${3:-}" collected_context="${4:-}"
  local prompt
  prompt="Issue: ${issue_title}

${issue_body}"
  if [[ -n "${collected_context}" ]]; then
    prompt="${prompt}

Collected context:
${collected_context}"
  fi
  if [[ -n "${extra_context}" ]]; then
    prompt="${prompt}

Additional context:
${extra_context}"
  fi
  prompt="${prompt}

$(opencode_agent_contract)

Do NOT create any commits; just edit files in the working tree. The outer driver commits and pushes for you.

When you are done, write a short, descriptive commit message (one line, no more than 72 characters) to the file .commit-msg in the repository root. The driver uses that line as the commit message it makes for you."
  if [[ -z "${extra_context}" ]]; then
    prompt="${prompt}

If you want to choose the feature branch name, write your preferred branch name (one line, e.g. feature/my-work) to the file .branch-name in the repository root; if you leave the file absent, the driver picks a name for you."
  fi
  printf '%s\n' "${prompt}"
}

opencode_build_handoff_prompt() {
  local previous_model="${1}"
  printf 'You are taking over unfinished work from model %s because it could not complete the task. Continue this same session and preserve all work already present in the working tree. Inspect the current progress, finish every remaining requirement, and run the relevant validation. Do not restart from scratch, discard existing work, or create commits.\n\n%s\n\nWhen the work is complete, write a short descriptive commit message (one line, no more than 72 characters) to .commit-msg in the repository root.\n' "${previous_model}" "$(opencode_agent_contract)"
}

# True when the round's JSON event stream carries an environment error
# (provider unreachable, credentials rejected, transport broken).
# Matched against the raw error-event lines, message and error name together,
# so no JSON value extraction is needed: those messages embed quoted JSON of
# their own ("xAI token refresh failed (400): {\"error\":...}"), which a value
# extractor would cut at the first escaped quote. Text events are ignored on
# purpose -- a model that merely writes the words in its answer is not an
# environment failure.
# A model-level condition ("Model is unavailable", a model that has been
# deprecated or does not exist) is NOT an environment error: it says nothing
# about the provider's other models, so it must not drop the whole provider.
# Such lines are filtered out before the environment patterns are matched, so
# even a generic wrapper message ("Upstream request failed: Model is
# unavailable.") that embeds both reads as the model being the problem.
opencode_round_is_environment() {
  local file="${1}"
  [[ -f "${file}" ]] || return 1
  grep -F '"type":"error"' "${file}" 2>/dev/null |
    grep -Evi 'model .*is unavailable|has been deprecated|model not found|no such model|unknown model|does not exist' |
    grep -Eiq 'token refresh failed|invalid_grant|cannot connect to api|unable to connect|was there a typo in the url|transport error|fetch failed|endpoint is unavailable|upstream request failed|upstream error|service temporarily overloaded|socket connection|providerautherror|authenticationerror|unauthorized|enotfound|econnrefused|econnreset|etimedout|getaddrinfo'
}

# True when the round carries a provider rate limit: the exact message opencode
# retries for minutes ("Rate limit exceeded. Please try again later."), its
# providers' HTTP 429 wording, or the error-event lines on stdout. opencode
# swallows the rate limit into its own retry loop while --format json prints
# nothing, but the retry/error diagnostics go to opencode's own stderr, and
# --print-logs (always passed) streams that stderr into this process. Checking
# both keeps the early-abort working even when the error event only appears on
# stdout as the round finally gives up. Like opencode_round_is_environment,
# text events are ignored on purpose: a model that merely writes the words is
# not rate limited (#155).
opencode_round_is_rate_limited() {
  local output_file="${1}" err_file="${2:-}"
  local pattern='rate limit|rate_limit|too many requests|please try again later|retry-after|retry after|quota exceeded|usage limit|resource_exhausted|\b429\b'
  if [[ -f "${output_file}" ]] && grep -F '"type":"error"' "${output_file}" 2>/dev/null | grep -Eiq "${pattern}"; then
    return 0
  fi
  if [[ -n "${err_file}" && -f "${err_file}" ]] && grep -Eiq "${pattern}" "${err_file}" 2>/dev/null; then
    return 0
  fi
  return 1
}

# True when the round's error stream says the model itself is permanently gone:
# the provider reports it as deprecated, removed, unavailable or otherwise
# unknown. These are exactly the model-level lines opencode_round_is_environment
# filters out, so a gone model never drops its whole provider. The driver uses
# this to remember just that model as dead and skip it in later rounds (#209).
opencode_round_is_model_gone() {
  local file="${1}"
  [[ -f "${file}" ]] || return 1
  grep -F '"type":"error"' "${file}" 2>/dev/null |
    grep -Eiq 'model .*is unavailable|has been deprecated|is deprecated|no longer supported|model not found|no such model|unknown model|does not exist'
}

# Run opencode with a specific model and publish its session ID in
# OPENCODE_SESSION_ID so a later model can continue the same conversation.
# Args: title body workdir model [extra_context] [session_id] [previous_model] [collected_context]
# A session handoff reuses the conversation the first prompt already carried
# the collected context in, so only the fresh-prompt branch below gets it.
opencode_run() {
  local issue_title="${1}" issue_body="${2}" workdir="${3}" model="${4}" extra_context="${5:-}" session_id="${6:-}" previous_model="${7:-}" collected_context="${8:-}"
  local prompt
  OPENCODE_ROUND_ENVIRONMENT="false"
  OPENCODE_ROUND_MODEL_GONE="false"
  OPENCODE_ROUND_RATE_LIMITED="false"
  if [[ -n "${session_id}" ]]; then
    prompt="$(opencode_build_handoff_prompt "${previous_model:-unknown}")"
  else
    prompt="$(opencode_build_prompt "${issue_title}" "${issue_body}" "${extra_context}" "${collected_context}")"
    if [[ -n "${previous_model}" ]]; then
      prompt="${prompt}"$'\n\n'"Model ${previous_model} did not finish this work through its session. Continue from the current working tree without discarding existing changes."
    fi
  fi

  echo "opencode: trying model ${model}" >&2

  if [[ "${OPENCODE_TEST_MODE:-0}" == "1" ]]; then
    if [[ -n "${session_id}" ]]; then
      printf 'opencode run --format json --model %s --dir %s --session %s %s\n' "${model}" "${workdir}" "${session_id}" "${prompt}"
    else
      printf 'opencode run --format json --model %s --dir %s --title conahcnuj %s\n' "${model}" "${workdir}" "${prompt}"
    fi
    OPENCODE_SESSION_ID="${MOCK_OPENCODE_SESSION_ID:-ses_mock}"
    export OPENCODE_SESSION_ID
    # MOCK_OPENCODE_ENV_ERROR lists the models whose round dies on an
    # environment error (it implies MOCK_OPENCODE_ERROR for those models).
    if [[ " ${MOCK_OPENCODE_ENV_ERROR:-} " == *" ${model} "* ]]; then
      OPENCODE_ROUND_ENVIRONMENT="true"
    fi
    # MOCK_OPENCODE_DEPRECATED lists the models whose round dies because the
    # model itself is gone (deprecated / removed / unavailable). It implies
    # MOCK_OPENCODE_ERROR for those models, but is a model-level, not an
    # environment, failure: only that model is remembered as dead.
    if [[ " ${MOCK_OPENCODE_DEPRECATED:-} " == *" ${model} "* ]]; then
      OPENCODE_ROUND_MODEL_GONE="true"
    fi
    # MOCK_OPENCODE_RATE_LIMIT lists the models whose round is cut short by a
    # provider rate limit, as the watchdog does in real mode.
    if [[ " ${MOCK_OPENCODE_RATE_LIMIT:-} " == *" ${model} "* ]]; then
      OPENCODE_ROUND_RATE_LIMITED="true"
    fi
    if [[ "${MOCK_OPENCODE_ERROR:-}" == "${model}" || "${OPENCODE_ROUND_ENVIRONMENT}" == "true" || "${OPENCODE_ROUND_MODEL_GONE}" == "true" || "${OPENCODE_ROUND_RATE_LIMITED}" == "true" ]]; then
      if [[ -d "${workdir}" && -w "${workdir}" ]]; then
        printf 'partial change from %s\n' "${model}" >> "${workdir}/conahcnuj.mock"
      fi
      if [[ "${OPENCODE_ROUND_RATE_LIMITED}" == "true" ]]; then
        echo "opencode: mock rate limit for ${model} (round stops immediately)" >&2
      elif [[ "${OPENCODE_ROUND_ENVIRONMENT}" == "true" ]]; then
        echo "opencode: mock environment error for ${model} (leaves an incomplete change)" >&2
      else
        echo "opencode: mock error for ${model} (leaves an incomplete change)" >&2
      fi
      return 1
    fi
    if [[ -z "${MOCK_OPENCODE_NOOP:-}" || "${MOCK_OPENCODE_NOOP}" != "${model}" ]]; then
      if [[ -z "${MOCK_OPENCODE_MESSAGE_ONLY:-}" || "${MOCK_OPENCODE_MESSAGE_ONLY}" != "${model}" ]]; then
        if [[ -d "${workdir}" && -w "${workdir}" ]]; then
          printf 'mock change from %s\n' "${model}" >> "${workdir}/conahcnuj.mock"
          # Simulate the agent honouring the .commit-msg contract.
          printf 'mock commit from %s\n' "${model}" > "${workdir}/.commit-msg"
        fi
      else
        # A model that answered with a message instead of doing the work.
        if [[ -d "${workdir}" && -w "${workdir}" ]]; then
          printf 'mock commit from %s\n' "${model}" > "${workdir}/.commit-msg"
        fi
        echo "opencode: mock message-only round for ${model} (message, no code change)" >&2
      fi
    else
      echo "opencode: mock no-op for ${model} (produces no changes)" >&2
    fi
    return 0
  fi

  # Private temp file (mkdtemp). The plugin writes the trailer value only
  # when the path stays inside Node's temp directory. A side model is
  # ignored when CONAHCNUJ_SESSION_MODEL is the model this run selected.
  local label_file
  label_file="$(node -e 'const fs=require("fs");const os=require("os");const path=require("path");const dir=fs.mkdtempSync(path.join(os.tmpdir(),"conahcnuj-"));const file=path.join(dir,"label.txt");fs.writeFileSync(file,"");process.stdout.write(file);' 2>/dev/null || true)"
  if [[ -n "${label_file}" ]]; then
    CONAHCNUJ_MODEL_LABEL_FILE="${label_file}"
    export CONAHCNUJ_MODEL_LABEL_FILE
  fi
  CONAHCNUJ_SESSION_MODEL="${model}"
  export CONAHCNUJ_SESSION_MODEL

  local output_file prompt_file status
  local -a args executable
  output_file="$(mktemp)"
  # The prompt carries the issue body plus every collected file (README.md /
  # AGENTS.md), so it can outgrow the OS argument-list limit (E2BIG:
  # "Argument list too long" from exec). opencode reads the message from stdin
  # when no positional argument is given, so deliver it there and keep argv
  # small. The redirect below is on the executable, not the whole pipeline, so
  # $PIPESTATUS stays aligned with opencode.
  prompt_file="$(mktemp)"
  printf '%s\n' "${prompt}" > "${prompt_file}"
  executable=(opencode)
  if [[ -n "${CONAHCNUJ_RUN_TIMEOUT_SECONDS:-}" ]]; then
    executable=(timeout --signal=TERM --kill-after=30s "${CONAHCNUJ_RUN_TIMEOUT_SECONDS}s" opencode)
  fi
  # --thinking makes opencode emit its reasoning parts as JSON events; without
  # it the log shows only tool calls and final answers.
  args=(run --print-logs --thinking --format json --model "${model}" --dir "${workdir}")
  # --print-logs defaults to INFO, which is ~30 lines of boot/permission
  # chatter per model and buries the rendered log. WARN keeps the diagnostics
  # that matter without the noise; override to DEBUG when hunting a problem.
  args+=(--log-level "${CONAHCNUJ_OPENCODE_LOG_LEVEL:-WARN}")
  if [[ -n "${session_id}" ]]; then
    args+=(--session "${session_id}")
  else
    args+=(--title conahcnuj)
  fi
  status=0
  # tee keeps the raw stream for the session id, the renderer prints the log to
  # stderr as the run proceeds (the header's SHA / diff only mean anything
  # live, and stderr is what the driver captures into its bug-report log).
  # The renderer's own exit status is deliberately ignored: a log filter must
  # never change the outcome of a run.
  local -a render
  render=(--model "${model}" --dir "${workdir}")
  if [[ -n "${CONAHCNUJ_REPO:-}" ]]; then
    render+=(--repo "${CONAHCNUJ_REPO}")
  fi
  if [[ -f "${OPENCODE_RENDER_SH}" ]]; then
    render=(bash "${OPENCODE_RENDER_SH}" "${render[@]}")
  else
    echo "WARNING: ${OPENCODE_RENDER_SH} is missing; printing the raw opencode output." >&2
    render=(cat)
  fi

  # opencode sits out a rate limit for minutes (its own retry backoff, nothing
  # useful on stdout) before the --format json error event finally appears.
  # To cut a round short the moment the limit shows up, opencode runs against
  # two FIFOs: a consumer tees stdout for the renderer and the session id, a
  # second keeps opencode's own log (--print-logs -> stderr, where the retry
  # diagnostics actually land) in a file, and a tiny watchdog kills the process
  # as soon as either shows the rate-limit tell (#155). The consumers read a
  # FIFO, so they exit on EOF the moment opencode closes it -- no orphans, no
  # extra pids to chase. When FIFOs are unavailable the plain tee pipeline is
  # kept and the rate limit is only detected at the end of the round.
  local out_fifo err_fifo err_file consumer_pid err_pid rate_aborted
  out_fifo="${output_file}.out"
  err_fifo="${output_file}.errfifo"
  err_file="${output_file}.err"
  rate_aborted="false"
  if mkfifo "${out_fifo}" "${err_fifo}" 2>/dev/null; then
    "${executable[@]}" "${args[@]}" < "${prompt_file}" >"${out_fifo}" 2>"${err_fifo}" &
    local opencode_pid=$!
    ( tee "${output_file}" <"${out_fifo}" | "${render[@]}" >&2 ) &
    consumer_pid=$!
    ( cat <"${err_fifo}" | tee "${err_file}" >&2 ) &
    err_pid=$!
    while kill -0 "${opencode_pid}" 2>/dev/null; do
      if opencode_round_is_rate_limited "${output_file}" "${err_file}"; then
        rate_aborted="true"
        echo "opencode: ${model} hit a rate limit; stopping its retry loop." >&2
        kill -TERM "${opencode_pid}" 2>/dev/null || true
        break
      fi
      sleep "${CONAHCNUJ_RATE_LIMIT_WATCH_SECONDS:-1}"
    done
    wait "${opencode_pid}" 2>/dev/null || status=$?
    # The FIFO consumers exit once opencode's write ends close; reap them so
    # the session-id extraction below sees the whole stream.
    wait "${consumer_pid}" "${err_pid}" 2>/dev/null || true
    rm -f "${out_fifo}" "${err_fifo}"
  else
    "${executable[@]}" "${args[@]}" < "${prompt_file}" | tee "${output_file}" | "${render[@]}" >&2 || status="${PIPESTATUS[0]}"
  fi

  # Only a failed round is classified: a round that ended fine may still carry
  # a retried-and-recovered error event, which says nothing about the provider.
  # A model that is gone is classified first; it is a model-level condition, so
  # it must not be read as the provider being down.
  if [[ "${status}" != "0" ]] && opencode_round_is_model_gone "${output_file}"; then
    OPENCODE_ROUND_MODEL_GONE="true"
  fi
  if [[ "${status}" != "0" ]]; then
    if opencode_round_is_environment "${output_file}"; then
      OPENCODE_ROUND_ENVIRONMENT="true"
    fi
    if [[ "${rate_aborted}" == "true" ]] || opencode_round_is_rate_limited "${output_file}"; then
      OPENCODE_ROUND_RATE_LIMITED="true"
    fi
  fi
  local detected_session
  detected_session="$(sed -n 's/.*"sessionID":"\([^"]*\)".*/\1/p' "${output_file}" | sed -n '1p')"
  if [[ "${detected_session}" =~ ^ses_[A-Za-z0-9_-]+$ ]]; then
    OPENCODE_SESSION_ID="${detected_session}"
    export OPENCODE_SESSION_ID
  fi
  rm -f "${output_file}" "${prompt_file}"
  if [[ "${status}" == "124" ]]; then
    echo "opencode exceeded the remaining driver time budget; stopping this model." >&2
  fi
  return "${status}"
}
