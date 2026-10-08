#!/usr/bin/env bash
# opencode wrapper for conahcnuj
# Provides model enumeration and hands the same opencode session to the next
# model when the current model cannot complete the work. A failed round sets
# OPENCODE_ROUND_ENVIRONMENT, so the driver can tell "this provider is down"
# apart from "this model is not good enough".
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
opencode_round_is_environment() {
  local file="${1}"
  [[ -f "${file}" ]] || return 1
  grep -F '"type":"error"' "${file}" 2>/dev/null |
    grep -Eiq 'token refresh failed|invalid_grant|cannot connect to api|unable to connect|was there a typo in the url|transport error|fetch failed|endpoint is unavailable|upstream request failed|upstream error|service temporarily overloaded|socket connection|providerautherror|authenticationerror|unauthorized|enotfound|econnrefused|econnreset|etimedout|getaddrinfo'
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
    if [[ "${MOCK_OPENCODE_ERROR:-}" == "${model}" || "${OPENCODE_ROUND_ENVIRONMENT}" == "true" ]]; then
      if [[ -d "${workdir}" && -w "${workdir}" ]]; then
        printf 'partial change from %s\n' "${model}" >> "${workdir}/conahcnuj.mock"
      fi
      echo "opencode: mock error for ${model} (leaves an incomplete change)" >&2
      return 1
    fi
    if [[ -z "${MOCK_OPENCODE_NOOP:-}" || "${MOCK_OPENCODE_NOOP}" != "${model}" ]]; then
      if [[ -z "${MOCK_OPENCODE_MESSAGE_ONLY:-}" || "${MOCK_OPENCODE_MESSAGE_ONLY}" != "${model}" ]]; then
        if [[ -d "${workdir}" && -w "${workdir}" ]]; then
          printf 'mock change from %s\n' "${model}" >> "${workdir}/conahcnuj.mock"
          # Simulate the agent honouring the .commit-msg contract.
          printf 'mock commit from %s\n' "${model}" > "${workdir}/.commit-msg"
          # Simulate the agent's TODO.md lifecycle (rooted TODO.md is the
          # per-issue progress file; it is created at issue start and
          # deleted when the work completes).
          if [[ -n "${MOCK_OPENCODE_TODO:-}" ]]; then
            printf '# TODO\n\n- [ ] mock progress\n' > "${workdir}/TODO.md"
          fi
          if [[ -n "${MOCK_OPENCODE_TODO_DELETE:-}" ]]; then
            rm -f "${workdir}/TODO.md"
          fi
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

  local output_file status
  local -a args executable
  output_file="$(mktemp)"
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
  args+=("${prompt}")
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
  "${executable[@]}" "${args[@]}" | tee "${output_file}" | "${render[@]}" >&2 || status="${PIPESTATUS[0]}"
  # Only a failed round is classified: a round that ended fine may still carry
  # a retried-and-recovered error event, which says nothing about the provider.
  if [[ "${status}" != "0" ]] && opencode_round_is_environment "${output_file}"; then
    OPENCODE_ROUND_ENVIRONMENT="true"
  fi
  local detected_session
  detected_session="$(sed -n 's/.*"sessionID":"\([^"]*\)".*/\1/p' "${output_file}" | sed -n '1p')"
  if [[ "${detected_session}" =~ ^ses_[A-Za-z0-9_-]+$ ]]; then
    OPENCODE_SESSION_ID="${detected_session}"
    export OPENCODE_SESSION_ID
  fi
  rm -f "${output_file}"
  if [[ "${status}" == "124" ]]; then
    echo "opencode exceeded the remaining driver time budget; stopping this model." >&2
  fi
  return "${status}"
}
