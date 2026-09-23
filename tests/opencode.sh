#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${HERE}/../lib/opencode.sh"

# shellcheck source=lib/opencode.sh
. "${LIB}"

test_opencode_get_models() {
  export OPENCODE_TEST_MODE=1
  export MOCK_OPENCODE_MODELS
  MOCK_OPENCODE_MODELS="$(printf 'opencode/mimo-v2.5-free\nopencode/other-model\n')"
  local out
  out="$(opencode_get_models)"
  [[ "${out}" == *"opencode/mimo-v2.5-free"* ]]
  [[ "${out}" == *"opencode/other-model"* ]]
  local count
  count="$(printf '%s\n' "${out}" | sed '/^$/d' | wc -l)"
  [[ "${count}" == "2" ]]
  unset OPENCODE_TEST_MODE MOCK_OPENCODE_MODELS
  echo "opencode_get_models passed"
}

test_opencode_build_prompt() {
  local prompt
  prompt="$(opencode_build_prompt "Issue title" "Issue body" "extra ctx")"
  [[ "${prompt}" == *"Issue: Issue title"* ]]
  [[ "${prompt}" == *"Issue body"* ]]
  [[ "${prompt}" == *"extra ctx"* ]]
  [[ "${prompt}" == *"Do NOT create any commits"* ]]
  [[ "${prompt}" == *".commit-msg"* ]]
  # Follow-up rounds keep the existing branch: no branch-name instruction.
  [[ "${prompt}" != *".branch-name"* ]]
  echo "opencode_build_prompt passed"
}

test_opencode_build_prompt_fresh() {
  local prompt
  prompt="$(opencode_build_prompt "Issue title" "Issue body")"
  # A fresh implementation round lets the agent choose the feature branch.
  [[ "${prompt}" == *".branch-name"* ]]
  echo "opencode_build_prompt (fresh round, branch-name offered) passed"
}

test_opencode_run() {
  export OPENCODE_TEST_MODE=1
  local tmp
  tmp="$(mktemp -d)"
  local out
  out="$(opencode_run "Test Issue" "Test body" "${tmp}" "opencode/mimo-v2.5-free" "more ctx")"
  [[ "${out}" == *"opencode run --format json --model opencode/mimo-v2.5-free"* ]]
  [[ "${out}" == *"--dir ${tmp}"* ]]
  [[ "${out}" == *"Test Issue"* ]]
  [[ "${out}" == *"more ctx"* ]]
  # A mock change file is written (the driver relies on working-tree changes),
  # and the mock honours the .commit-msg contract.
  [[ -f "${tmp}/conahcnuj.mock" ]]
  [[ -f "${tmp}/.commit-msg" ]]
  rm -rf "${tmp}"
  unset OPENCODE_TEST_MODE
  echo "opencode_run passed"
}

test_opencode_run_noop_models() {
  export OPENCODE_TEST_MODE=1
  export MOCK_OPENCODE_NOOP="opencode/dead-model"
  local tmp
  tmp="$(mktemp -d)"
  opencode_run "Issue" "Body" "${tmp}" "opencode/dead-model" >/dev/null
  [[ ! -f "${tmp}/conahcnuj.mock" ]]
  [[ ! -f "${tmp}/.commit-msg" ]]
  opencode_run "Issue" "Body" "${tmp}" "opencode/live-model" >/dev/null
  [[ -f "${tmp}/conahcnuj.mock" ]]
  [[ -f "${tmp}/.commit-msg" ]]
  rm -rf "${tmp}"
  unset OPENCODE_TEST_MODE MOCK_OPENCODE_NOOP
  echo "opencode_run (no-op model) passed"
}

test_opencode_get_models
test_opencode_build_prompt
test_opencode_build_prompt_fresh
test_opencode_run
test_opencode_run_noop_models

echo "All opencode tests passed"