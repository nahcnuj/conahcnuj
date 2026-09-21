#!/usr/bin/env bash
# opencode wrapper for conahcnuj
# Provides model enumeration and one opencode session per model so the
# driver can fall through every available model until one produces changes.

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

Implement the changes needed to resolve this issue. Do NOT create any commits; just edit files in the working tree. The outer driver commits and pushes for you."
  printf '%s\n' "${prompt}"
}

# Run one opencode session with a specific model.
# Args: title body workdir model [extra_context]
# Returns 0 even when a model produced nothing; callers detect changes
# themselves via the working tree.
opencode_run() {
  local issue_title="${1}" issue_body="${2}" workdir="${3}" model="${4}" extra_context="${5:-}"
  local prompt
  prompt="$(opencode_build_prompt "${issue_title}" "${issue_body}" "${extra_context}")"

  echo "opencode: trying model ${model}" >&2

  if [[ "${OPENCODE_TEST_MODE:-0}" == "1" ]]; then
    printf 'opencode run --format json --model %s --dir %s --title conahcnuj %s\n' "${model}" "${workdir}" "${prompt}"
    if [[ -z "${MOCK_OPENCODE_NOOP:-}" || "${MOCK_OPENCODE_NOOP}" != "${model}" ]]; then
      if [[ -d "${workdir}" && -w "${workdir}" ]]; then
        printf 'mock change from %s\n' "${model}" >> "${workdir}/conahcnuj.mock"
      fi
    else
      echo "opencode: mock no-op for ${model} (produces no changes)" >&2
    fi
    return 0
  fi

  opencode run -y --format json --model "${model}" --dir "${workdir}" --title conahcnuj "${prompt}" || return 1
}