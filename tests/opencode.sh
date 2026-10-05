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
  [[ "${prompt}" == *"Implement the changes needed to resolve this issue in the working tree"* ]] || { echo "FAIL: the prompt does not ask for the change"; exit 1; }
  [[ "${prompt}" == *"Do NOT create any commits"* ]]
  # The prompt asks for the change and for nothing else. A commit message (or a
  # pull request title) asked for beside it is a second, smaller deliverable,
  # and a model that finishes that one instead has changed nothing: issue #146.
  [[ "${prompt}" != *".commit-msg"* ]] || { echo "FAIL: the prompt still asks the agent for a commit message"; exit 1; }
  [[ "${prompt}" != *"pull request title"* ]] || { echo "FAIL: the prompt still asks the agent for a pull request title"; exit 1; }
  # Follow-up rounds keep the existing branch: no branch-name instruction.
  [[ "${prompt}" != *".branch-name"* ]]
  echo "opencode_build_prompt passed"
}

test_opencode_build_prompt_fresh() {
  local prompt
  prompt="$(opencode_build_prompt "Issue title" "Issue body")"
  # A fresh implementation round lets the agent choose the feature branch.
  [[ "${prompt}" == *".branch-name"* ]] || { echo "FAIL: the branch-name offer is missing"; exit 1; }
  # The branch name is the one thing asked for besides the change, and it stays
  # an offer: the driver names the branch when the round leaves none.
  [[ "${prompt}" == *"if you leave the file absent, the driver picks a name for you"* ]] || { echo "FAIL: the branch-name offer is not optional"; exit 1; }
  [[ "${prompt}" != *".commit-msg"* ]] || { echo "FAIL: the prompt still asks the agent for a commit message"; exit 1; }
  echo "opencode_build_prompt (fresh round, branch-name offered) passed"
}

test_opencode_build_handoff_prompt() {
  local prompt
  prompt="$(opencode_build_handoff_prompt "opencode/dead-model")"
  [[ "${prompt}" == *"taking over unfinished work from model opencode/dead-model"* ]]
  [[ "${prompt}" == *"Continue this same session"* ]]
  [[ "${prompt}" == *"preserve all work already present"* ]]
  [[ "${prompt}" == *"or create commits; the outer driver commits and pushes for you"* ]] || { echo "FAIL: the handoff prompt lets the takeover model commit"; exit 1; }
  # A takeover round is asked for the rest of the change and nothing else.
  [[ "${prompt}" != *".commit-msg"* ]] || { echo "FAIL: the handoff prompt still asks the agent for a commit message"; exit 1; }
  [[ "${prompt}" != *"pull request title"* ]] || { echo "FAIL: the handoff prompt still asks the agent for a pull request title"; exit 1; }
  echo "opencode_build_handoff_prompt passed"
}

test_opencode_run_message_only() {
  export OPENCODE_TEST_MODE=1
  export MOCK_OPENCODE_MESSAGE_ONLY="opencode/talker"
  local tmp log out
  tmp="$(mktemp -d)"
  log="$(mktemp)"
  # A round the driver has to survive: the model answered with a commit message
  # and left the working tree alone.
  opencode_run "Issue" "Body" "${tmp}" "opencode/talker" >/dev/null 2>"${log}"
  [[ -s "${tmp}/.commit-msg" ]] || { echo "FAIL: the mock message-only round wrote no message"; cat "${log}" >&2; exit 1; }
  [[ ! -e "${tmp}/conahcnuj.mock" ]] || { echo "FAIL: the mock message-only round touched the tree"; exit 1; }
  # The next model is handed the same session and asked to finish the work.
  out="$(opencode_run "Issue" "Body" "${tmp}" "opencode/second" "" "${OPENCODE_SESSION_ID}" "opencode/talker")"
  [[ "${out}" == *"--session ses_mock"* ]]
  [[ -f "${tmp}/conahcnuj.mock" ]]
  rm -f "${log}"
  rm -rf "${tmp}"
  unset OPENCODE_TEST_MODE MOCK_OPENCODE_MESSAGE_ONLY OPENCODE_SESSION_ID
  echo "opencode_run (message-only round) passed"
}

test_opencode_run_no_message() {
  export OPENCODE_TEST_MODE=1
  export MOCK_OPENCODE_NO_MESSAGE="opencode/quiet"
  local tmp out
  tmp="$(mktemp -d)"
  # The normal round now: the prompt asks for the change and nothing else, so
  # the agent leaves no .commit-msg and the driver labels the commit itself.
  out="$(opencode_run "Issue" "Body" "${tmp}" "opencode/quiet")"
  [[ "${out}" == *"opencode/quiet"* ]]
  [[ -f "${tmp}/conahcnuj.mock" ]] || { echo "FAIL: the round produced no change"; exit 1; }
  [[ ! -e "${tmp}/.commit-msg" ]] || { echo "FAIL: the mock wrote a commit message anyway"; exit 1; }
  rm -rf "${tmp}"
  unset OPENCODE_TEST_MODE MOCK_OPENCODE_NO_MESSAGE OPENCODE_SESSION_ID
  echo "opencode_run (no commit message) passed"
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
  # and the mock also leaves the .commit-msg some repositories' own agent
  # instructions ask for.
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
  # Thinking and a quiet log level are part of a readable log: --thinking makes
  # the model show its reasoning, --log-level WARN drops the INFO boot chatter.
  [[ "${args}" == *"--thinking"* ]]
  [[ "${args}" == *"--log-level WARN"* ]]
  CONAHCNUJ_OPENCODE_LOG_LEVEL=DEBUG opencode_run "Issue" "Body" "${tmp}" "opencode/third" >/dev/null || rc=$?
  args="$(cat "${OPENCODE_ARGS_FILE}")"
  [[ "${args}" == *"--log-level DEBUG"* ]]
  PATH="${old_path}"
  rm -rf "${tmp}"
  unset OPENCODE_ARGS_FILE FAKE_OPENCODE_EXIT OPENCODE_SESSION_ID
}

test_opencode_run_renders_log() {
  local tmp old_path log
  tmp="$(mktemp -d)"
  old_path="${PATH}"
  mkdir -p "${tmp}/bin"
  # A fake opencode that emits the event shapes a real run produces.
  cat > "${tmp}/bin/opencode" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"type":"reasoning","part":{"type":"reasoning","text":"thinking about it"}}
{"type":"tool_use","part":{"type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"make check"},"output":"ok\n","metadata":{"exit":0},"title":"make check"}}}
{"type":"tool_use","part":{"type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"make broken"},"output":"nope\n","metadata":{"exit":2},"title":"make broken"}}}
{"type":"text","part":{"type":"text","text":"all done"}}
JSON
exit "${FAKE_OPENCODE_EXIT:-0}"
EOF
  chmod +x "${tmp}/bin/opencode"
  PATH="${tmp}/bin:${PATH}"
  export PATH
  # The rendered log goes to stderr; stdout stays empty.
  log="$(mktemp)"
  opencode_run "Issue" "Body" "${tmp}" "opencode/first" >"${tmp}/stdout" 2>"${log}"
  [[ ! -s "${tmp}/stdout" ]] || {
    cat "${tmp}/stdout" >&2
    echo "FAIL: the raw JSON stream must not reach stdout" >&2
    exit 1
  }
  local out
  out="$(cat "${log}")"
  [[ "${out}" == *"opencode/first@"* ]] || { echo "FAIL: no model header"; echo "${out}" >&2; exit 1; }
  [[ "${out}" == *"  thinking about it"* ]] || { echo "FAIL: reasoning not rendered"; echo "${out}" >&2; exit 1; }
  [[ "${out}" == *'$ make check'* ]] || { echo "FAIL: command not rendered"; echo "${out}" >&2; exit 1; }
  [[ "${out}" == *'✅ make check'* ]] || { echo "FAIL: success verdict missing"; echo "${out}" >&2; exit 1; }
  [[ "${out}" == *'❌️ make broken (exit 2)'* ]] || { echo "FAIL: failure verdict missing"; echo "${out}" >&2; exit 1; }
  [[ "${out}" == *"  all done"* ]] || { echo "FAIL: final text not rendered"; echo "${out}" >&2; exit 1; }
  # The raw stream is still kept well enough to recover the session id.
  [[ "${OPENCODE_SESSION_ID:-}" =~ ^ses_ ]] || echo "note: no session id in the fake stream"
  rm -f "${log}"
  PATH="${old_path}"
  rm -rf "${tmp}"
  unset FAKE_OPENCODE_EXIT
  echo "opencode_run renders the log passed"
}

test_opencode_run_timeout() {
  local tmp old_path rc
  tmp="$(mktemp -d)"
  old_path="${PATH}"
  mkdir -p "${tmp}/bin"
  cat > "${tmp}/bin/opencode" <<'EOF'
#!/usr/bin/env bash
sleep 5
EOF
  chmod +x "${tmp}/bin/opencode"
  PATH="${tmp}/bin:${PATH}"
  export PATH
  rc=0
  CONAHCNUJ_RUN_TIMEOUT_SECONDS=0.1 opencode_run "Issue" "Body" "${tmp}" "opencode/hanging" >/dev/null 2>&1 || rc=$?
  [[ "${rc}" -eq 124 ]]
  PATH="${old_path}"
  rm -rf "${tmp}"
  echo "opencode_run timeout passed"
}

test_opencode_get_models
test_opencode_build_prompt
test_opencode_build_prompt_fresh
test_opencode_build_handoff_prompt
test_opencode_run
test_opencode_run_message_only
test_opencode_run_no_message
test_opencode_run_noop_models
test_opencode_run_session_handoff
test_opencode_run_renders_log
test_opencode_run_timeout

echo "All opencode tests passed"
