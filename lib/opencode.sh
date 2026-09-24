#!/usr/bin/env bash
# opencode wrapper for conahcnuj
# Provides model enumeration and hands the same opencode session to the next
# model when the current model cannot complete the work.

set -euo pipefail

# List available models, one per line. Test mode: $MOCK_OPENCODE_MODELS.
opencode_get_models() {
  if [[ "${OPENCODE_TEST_MODE:-0}" == "1" ]]; then
    printf '%s\n' "${MOCK_OPENCODE_MODELS:-}"
    return 0
  fi
  opencode models 2>/dev/null | grep -E '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
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

Implement the changes needed to resolve this issue. Do NOT create any commits; just edit files in the working tree. The outer driver commits and pushes for you.

When you are done, write a short, descriptive commit message (one line, no more than 72 characters) to the file .commit-msg in the repository root. This message should summarize the changes you made."
  if [[ -z "${extra_context}" ]]; then
    prompt="${prompt}

If you want to choose the feature branch name, write your preferred branch name (one line, e.g. feature/my-work) to the file .branch-name in the repository root; if you leave the file absent, the driver picks a name for you."
  fi
  printf '%s\n' "${prompt}"
}

opencode_build_handoff_prompt() {
  local previous_model="${1}"
  printf 'You are taking over unfinished work from model %s because it could not complete the task. Continue this same session and preserve all work already present in the working tree. Inspect the current progress, finish every remaining requirement, and run the relevant validation. Do not restart from scratch, discard existing work, or create commits. When the work is complete, write a short descriptive commit message (one line, no more than 72 characters) to .commit-msg in the repository root.\n' "${previous_model}"
}

# Run opencode with a specific model and publish its session ID in
# OPENCODE_SESSION_ID so a later model can continue the same conversation.
# Args: title body workdir model [extra_context] [session_id] [previous_model]
opencode_run() {
  local issue_title="${1}" issue_body="${2}" workdir="${3}" model="${4}" extra_context="${5:-}"
  local session_id="${6:-}" previous_model="${7:-}"
  local prompt
  if [[ -n "${session_id}" ]]; then
    prompt="$(opencode_build_handoff_prompt "${previous_model:-unknown}")"
  else
    prompt="$(opencode_build_prompt "${issue_title}" "${issue_body}" "${extra_context}")"
    if [[ -n "${previous_model}" ]]; then
      prompt="${prompt}"$'\n\n'"Model ${previous_model} failed before this work could be handed off through its session. Continue from the current working tree without discarding existing changes."
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
      if [[ -d "${workdir}" && -w "${workdir}" ]]; then
        printf 'mock change from %s\n' "${model}" >> "${workdir}/conahcnuj.mock"
        # Simulate the agent honouring the .commit-msg contract.
        printf 'mock commit from %s\n' "${model}" > "${workdir}/.commit-msg"
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
  local -a args
  output_file="$(mktemp)"
  args=(run --print-logs --format json --model "${model}" --dir "${workdir}")
  if [[ -n "${session_id}" ]]; then
    args+=(--session "${session_id}")
  else
    args+=(--title conahcnuj)
  fi
  args+=("${prompt}")
  status=0
  opencode "${args[@]}" > "${output_file}" || status=$?
  cat "${output_file}"
  local detected_session
  detected_session="$(sed -n 's/.*"sessionID":"\([^"]*\)".*/\1/p' "${output_file}" | sed -n '1p')"
  if [[ "${detected_session}" =~ ^ses_[A-Za-z0-9_-]+$ ]]; then
    OPENCODE_SESSION_ID="${detected_session}"
    export OPENCODE_SESSION_ID
  fi
  rm -f "${output_file}"
  return "${status}"
}
