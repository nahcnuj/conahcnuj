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

test_opencode_build_handoff_prompt() {
  local prompt
  prompt="$(opencode_build_handoff_prompt "opencode/dead-model")"
  [[ "${prompt}" == *"taking over unfinished work from model opencode/dead-model"* ]]
  [[ "${prompt}" == *"Continue this same session"* ]]
  [[ "${prompt}" == *"preserve all work already present"* ]]
  [[ "${prompt}" == *".commit-msg"* ]]
  echo "opencode_build_handoff_prompt passed"
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
  [[ "${OPENCODE_SESSION_ID}" == "ses_mock" ]]
  [[ ! -f "${tmp}/conahcnuj.mock" ]]
  [[ ! -f "${tmp}/.commit-msg" ]]
  local out
  out="$(opencode_run "Issue" "Body" "${tmp}" "opencode/live-model" "" "${OPENCODE_SESSION_ID}" "opencode/dead-model")"
  [[ "${out}" == *"--session ses_mock"* ]]
  [[ "${out}" == *"taking over unfinished work from model opencode/dead-model"* ]]
  [[ -f "${tmp}/conahcnuj.mock" ]]
  [[ -f "${tmp}/.commit-msg" ]]
  rm -rf "${tmp}"
  unset OPENCODE_TEST_MODE MOCK_OPENCODE_NOOP OPENCODE_SESSION_ID
  echo "opencode_run (no-op model) passed"
}

test_opencode_run_session_handoff() {
  local tmp old_path rc args
  tmp="$(mktemp -d)"
  old_path="${PATH}"
  mkdir -p "${tmp}/bin"
  cat > "${tmp}/bin/opencode" <<'EOF'
#!/usr/bin/env bash
printf '{"type":"step_start","sessionID":"ses_parsed"}\n'
printf '%s\n' "$*" > "${OPENCODE_ARGS_FILE}"
exit "${FAKE_OPENCODE_EXIT:-0}"
EOF
  chmod +x "${tmp}/bin/opencode"
  PATH="${tmp}/bin:${PATH}"
  export PATH
  OPENCODE_ARGS_FILE="${tmp}/args.txt"
  export OPENCODE_ARGS_FILE
  FAKE_OPENCODE_EXIT=7
  export FAKE_OPENCODE_EXIT
  rc=0
  opencode_run "Issue" "Body" "${tmp}" "opencode/first" >/dev/null || rc=$?
  [[ "${rc}" -eq 7 ]]
  [[ "${OPENCODE_SESSION_ID:-}" == "ses_parsed" ]]
  args="$(cat "${OPENCODE_ARGS_FILE}")"
  [[ "${args}" == *"--model opencode/first"* ]]
  [[ "${args}" != *"--session"* ]]
  rc=0
  opencode_run "Issue" "Body" "${tmp}" "opencode/second" "" "${OPENCODE_SESSION_ID}" "opencode/first" >/dev/null || rc=$?
  [[ "${rc}" -eq 7 ]]
  args="$(cat "${OPENCODE_ARGS_FILE}")"
  [[ "${args}" == *"--model opencode/second"* ]]
  [[ "${args}" == *"--session ses_parsed"* ]]
  PATH="${old_path}"
  rm -rf "${tmp}"
  unset OPENCODE_ARGS_FILE FAKE_OPENCODE_EXIT OPENCODE_SESSION_ID
}

test_opencode_get_models
test_opencode_build_prompt
test_opencode_build_prompt_fresh
test_opencode_build_handoff_prompt
test_opencode_run
test_opencode_run_noop_models
test_opencode_run_session_handoff

echo "All opencode tests passed"
