#!/usr/bin/env bash
# opencode wrapper for conahcnuj
# Provides model enumeration and hands the same opencode session to the next
# model when the current model cannot complete the work.
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

# List available models, one per line. Test mode: $MOCK_OPENCODE_MODELS.
opencode_get_models() {
  if [[ "${OPENCODE_TEST_MODE:-0}" == "1" ]]; then
    printf '%s\n' "${MOCK_OPENCODE_MODELS:-}"
    return 0
  fi
  opencode models 2>/dev/null | grep -E '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
}

# The contract every round shares, whatever the model or the stage: the change
# in the working tree is the deliverable, and everything that needs GitHub
# belongs to the driver. Models that read the .commit-msg instruction as the
# task itself answer with a message (and sometimes a pull request title) and
# change nothing, which the driver can only count as no work, so the deliverable
# and the driver's share are stated before any metadata instruction appears.
opencode_agent_contract() {
  cat <<'EOF'
You are the coding agent in a driver that takes this issue (or the pull request being resumed) all the way to the owner's approval. The deliverable is the change itself: implement the issue for real in the working tree, run the repository's own validation, and leave the branch in a state a reviewer can approve. An analysis, a plan, or a description of what you would change is not a deliverable.

Everything that needs GitHub is the driver's job once you finish: it names the branch, creates the commit, pushes it, opens the pull request with its title and description, and requests the review. So do not run git commit, git push, git vc, gh pr create or anything else that creates a commit, a branch or a pull request, and do not write a pull request title or body yourself.
EOF
}

# Build the implementation prompt for a single model run.
# Args: issue_title issue_body [extra_context]
# A fresh implementation round (no extra_context) also lets the agent choose
# the feature branch via .branch-name; follow-up rounds (fix constraints,
# review feedback) keep the existing branch, so the instruction is omitted.
opencode_build_prompt() {
  local issue_title="${1}" issue_body="${2}" extra_context="${3:-}"
  local prompt
  prompt="Issue: ${issue_title}

${issue_body}"
  if [[ -n "${extra_context}" ]]; then
    prompt="${prompt}

Additional context:
${extra_context}"
  fi
  prompt="${prompt}

$(opencode_agent_contract)

When the implementation is complete, write a short, descriptive commit message (one line, no more than 72 characters) to the file .commit-msg in the repository root, summarizing the changes you made. It is a one-line label the driver copies into the commit it makes for you, so it never stands in for the work: a round that only writes that file and leaves the working tree untouched counts as no work and is handed to the next model."
  if [[ -z "${extra_context}" ]]; then
    prompt="${prompt}

If you want to choose the feature branch name, write your preferred branch name (one line, e.g. feature/my-work) to the file .branch-name in the repository root; if you leave the file absent, the driver picks a name for you. Like .commit-msg it is metadata for the driver, not a substitute for the implementation."
  fi
  printf '%s\n' "${prompt}"
}

opencode_build_handoff_prompt() {
  local previous_model="${1}"
  printf 'You are taking over unfinished work from model %s because it could not complete the task. Continue this same session and preserve all work already present in the working tree. Inspect the current progress, finish every remaining requirement, and run the relevant validation. Do not restart from scratch or discard existing work.\n\n%s\n\nWhen the implementation is complete, write a short descriptive commit message (one line, no more than 72 characters) to .commit-msg in the repository root. It is a one-line label the driver copies into the commit it makes for you: until the working tree holds the finished change it is not the deliverable and counts as no work.\n' "${previous_model}" "$(opencode_agent_contract)"
}

# Run opencode with a specific model and publish its session ID in
# OPENCODE_SESSION_ID so a later model can continue the same conversation.
# Args: title body workdir model [extra_context] [session_id] [previous_model]
opencode_run() {
  local issue_title="${1}" issue_body="${2}" workdir="${3}" model="${4}" extra_context="${5:-}" session_id="${6:-}" previous_model="${7:-}"
  local prompt
  if [[ -n "${session_id}" ]]; then
    prompt="$(opencode_build_handoff_prompt "${previous_model:-unknown}")"
  else
    prompt="$(opencode_build_prompt "${issue_title}" "${issue_body}" "${extra_context}")"
    if [[ -n "${previous_model}" ]]; then
      prompt="${prompt}"$'\n\n'"Model ${previous_model} could not complete the work through its session (it may have failed, or answered with a commit message and no change). Continue from the current working tree without discarding existing changes."
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
    if [[ "${MOCK_OPENCODE_ERROR:-}" == "${model}" ]]; then
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
        fi
      else
        # The mistake the prompt text above is meant to prevent: the model
        # answers with a commit message and leaves the working tree untouched.
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

  # Private temp file (mkdtemp). The plugin writes the display name only
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
