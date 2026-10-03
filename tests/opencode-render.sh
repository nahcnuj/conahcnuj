#!/usr/bin/env bash
# Offline tests for lib/opencode-render.sh: no opencode, no network, no remote
# required. The fixtures use the event shapes opencode actually emits
# (captured from `opencode run --format json --thinking`).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RENDER="${HERE}/../lib/opencode-render.sh"

# A work tree with one commit, one modified file and one new (untracked) file,
# so the header has a real SHA / branch / diff to report.
fixture_repo() {
  local dir="${1}"
  rm -rf "${dir}"
  mkdir -p "${dir}"
  git -C "${dir}" init -q -b main
  git -C "${dir}" config user.email "render@test"
  git -C "${dir}" config user.name "render"
  printf 'one\ntwo\n' > "${dir}/tracked.txt"
  git -C "${dir}" add -A
  git -C "${dir}" commit -qm init
  printf 'three\n' >> "${dir}/tracked.txt"
  printf 'new\n' > "${dir}/added.txt"
}

fail() {
  echo "FAIL: ${1}" >&2
  echo "--- rendered output ---" >&2
  printf '%s\n' "${2:-}" >&2
  exit 1
}

assert_contains() {
  local out="${1}" needle="${2}" msg="${3}"
  [[ "${out}" == *"${needle}"* ]] || fail "${msg}" "${out}"
}

assert_not_contains() {
  local out="${1}" needle="${2}" msg="${3}"
  [[ "${out}" != *"${needle}"* ]] || fail "${msg}" "${out}"
}

test_header_context() {
  local tmp out sha branch
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  sha="$(git -C "${tmp}/repo" rev-parse --short HEAD)"
  branch="$(git -C "${tmp}/repo" rev-parse --abbrev-ref HEAD)"
  out="$(printf '%s\n' '{"type":"text","part":{"type":"text","text":"hello"}}' |
    bash "${RENDER}" --model "opencode/some-model" --repo "owner/repo" --dir "${tmp}/repo")"
  # model@owner/repo:cwd, then SHA, branch and the working-tree diff.
  assert_contains "${out}" "opencode/some-model@owner/repo:." "header first column"
  assert_contains "${out}" "  hello" "text is indented"
  assert_contains "${out}" "${sha} [${branch}]" "header SHA/branch"
  assert_contains "${out}" "+1/-0" "header diff"
  # The untracked file is counted separately: a fresh implementation creates
  # files before staging them.
  assert_contains "${out}" "+1 new" "header counts untracked files"
  rm -rf "${tmp}"
  echo "render_header context passed"
}

test_header_repo_from_remote() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  git -C "${tmp}/repo" remote add origin "https://github.com/derived/repo.git"
  # No --repo: the header must fall back to the origin remote.
  out="$(printf '%s\n' '{"type":"text","part":{"type":"text","text":"x"}}' |
    bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" "m@derived/repo:." "repo taken from origin"
  rm -rf "${tmp}"
  echo "render_header repo from remote passed"
}

test_header_dir_subdirectory() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  mkdir -p "${tmp}/repo/lib/deep"
  # git and bash spell a Windows path differently (C:/x vs /c/x), so the cwd
  # column must come from git itself rather than a pwd/toplevel comparison.
  out="$(printf '%s\n' '{"type":"text","part":{"type":"text","text":"x"}}' |
    bash "${RENDER}" --model "m" --repo "o/r" --dir "${tmp}/repo/lib/deep")"
  assert_contains "${out}" "m@o/r:lib/deep" "cwd is relative to the work tree root"
  rm -rf "${tmp}"
  echo "render_header dir in subdirectory passed"
}

test_model_label_file_wins() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  printf 'Space Bunny (medium)\n' > "${tmp}/label.txt"
  out="$(printf '%s\n' '{"type":"text","part":{"type":"text","text":"x"}}' |
    CONAHCNUJ_MODEL_LABEL_FILE="${tmp}/label.txt" \
    bash "${RENDER}" --model "opencode/space-bunny-free" --dir "${tmp}/repo")"
  # The plugin's display name plus effort wins over the raw model id.
  assert_contains "${out}" "Space Bunny (medium)@" "plugin label used"
  assert_not_contains "${out}" "opencode/space-bunny-free@" "model id not used when a label exists"
  rm -rf "${tmp}"
  echo "render_model_label passed"
}

test_text_and_reasoning() {
  local tmp out headers
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  out="$(cat <<'EOF' |
{"type":"reasoning","part":{"type":"reasoning","text":"first thought\nsecond thought"}}
{"type":"step_start","part":{"type":"step-start"}}
{"type":"text","part":{"type":"text","text":"final answer"}}
{"type":"step_finish","part":{"type":"step-finish","reason":"stop"}}
EOF
    bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" "  first thought" "reasoning rendered"
  assert_contains "${out}" "  second thought" "second reasoning line"
  assert_contains "${out}" "  final answer" "text rendered"
  # Only the two content events open a block: step_start / step_finish carry no
  # content and must not produce a header.
  headers="$(printf '%s\n' "${out}" | grep -c '\[main\]' || true)"
  [[ "${headers}" == "2" ]] || fail "step events rendered a header (${headers} headers)" "${out}"
  rm -rf "${tmp}"
  echo "render text/reasoning passed"
}

test_tool_success() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  out="$(cat <<'EOF' |
{"type":"tool_use","part":{"type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"cat tracked.txt"},"output":"one\ntwo\nthree\n","metadata":{"output":"one\ntwo\nthree\n","exit":0,"truncated":false},"title":"cat tracked.txt"}}}
EOF
    bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" '$ cat tracked.txt' "command line rendered"
  assert_contains "${out}" "  three" "tool output rendered"
  assert_contains "${out}" "✅ cat tracked.txt" "success verdict"
  assert_not_contains "${out}" "exit " "no exit code on success"
  # Exactly one blank line after the output, then the verdict.
  [[ "${out}" == *$'\n\n✅ cat tracked.txt'* ]] || fail "blank line before verdict" "${out}"
  rm -rf "${tmp}"
  echo "render tool success passed"
}

test_tool_failure_exit_code() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  # opencode reports a non-zero command as a completed call with an exit code.
  out="$(printf '%s\n' '{"type":"tool_use","part":{"type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"false"},"output":"boom\n","metadata":{"exit":1,"truncated":false},"title":"false"}}}' |
    bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" '$ false' "command line rendered"
  assert_contains "${out}" "  boom" "tool output rendered"
  assert_contains "${out}" "❌️ false (exit 1)" "failure verdict with exit code"
  rm -rf "${tmp}"
  echo "render tool failure passed"
}

test_tool_error_status() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  out="$(printf '%s\n' '{"type":"tool_use","part":{"type":"tool","tool":"bash","state":{"status":"error","input":{"command":"nope"},"error":"permission denied","title":"nope"}}}' |
    bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" "  ERROR: permission denied" "tool error message rendered"
  assert_contains "${out}" "❌️ nope" "error verdict"
  assert_not_contains "${out}" "(exit " "no exit code without metadata"
  rm -rf "${tmp}"
  echo "render tool error status passed"
}

test_tool_title_fallback() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  # No title: fall back to the command line, then to the tool name.
  out="$(printf '%s\n' '{"type":"tool_use","part":{"type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"make check"},"output":"","metadata":{"exit":0}}}}' |
    bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" '$ make check' "falls back to the command"
  assert_contains "${out}" "✅ make check" "verdict uses the command"
  out="$(printf '%s\n' '{"type":"tool_use","part":{"type":"tool","tool":"todowrite","state":{"status":"completed","input":{},"output":"","metadata":{}}}}' |
    bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" '$ todowrite' "falls back to the tool name"
  rm -rf "${tmp}"
  echo "render tool title fallback passed"
}

test_tool_input_does_not_shadow_state() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  # A tool is free to take its own output/title arguments; the renderer must
  # read state.output / state.title, not the argument object.
  out="$(printf '%s\n' '{"type":"tool_use","part":{"type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"echo hi","output":"decoy output","title":"decoy title"},"output":"real output\n","metadata":{"exit":0},"title":"echo hi"}}}' |
    bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" "  real output" "state.output wins over the tool argument"
  assert_not_contains "${out}" "decoy output" "tool argument output ignored"
  assert_contains "${out}" "✅ echo hi" "state.title wins over the tool argument"
  assert_not_contains "${out}" "decoy title" "tool argument title ignored"
  rm -rf "${tmp}"
  echo "render tool input does not shadow state passed"
}

test_session_error() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  out="$(printf '%s\n' '{"type":"error","error":{"name":"ProviderAuthError","data":{"message":"401 unauthorized"}}}' |
    bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" "  ❌️ 401 unauthorized" "session error message"
  # The error name alone is still shown when there is no message.
  out="$(printf '%s\n' '{"type":"error","error":{"name":"ProviderAuthError"}}' |
    bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" "  ❌️ ProviderAuthError" "session error name"
  rm -rf "${tmp}"
  echo "render session error passed"
}

test_escapes_are_decoded() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  out="$(printf '%s\n' '{"type":"tool_use","part":{"type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"echo"},"output":"say \"hi\"\nC:\\tmp\\x\ttab\n","metadata":{"exit":0},"title":"echo"}}}' |
    bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" '  say "hi"' "escaped quotes decoded"
  # A JSON-escaped backslash must not become a tab or a newline.
  assert_contains "${out}" '  C:\tmp\x	tab' "escaped backslash kept, \\t became a tab"
  rm -rf "${tmp}"
  echo "render escapes passed"
}

test_non_json_passthrough() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  # Anything that is not a JSON object on stdout is passed through untouched.
  out="$(printf '%s\n%s\n' 'timestamp=2026-01-01T00:00:00Z level=INFO message=hello' '{"type":"text","part":{"type":"text","text":"body"}}' |
    bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" "level=INFO message=hello" "non-JSON line passed through"
  assert_contains "${out}" "  body" "JSON event still rendered"
  rm -rf "${tmp}"
  echo "render non-JSON passthrough passed"
}

test_truncation_is_announced() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  out="$(printf '%s\n' '{"type":"tool_use","part":{"type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"big"},"output":"line0001\nline0002\nline0003\nline0004\nline0005","metadata":{"exit":0},"title":"big"}}}' |
    CONAHCNUJ_RENDER_MAX_LINES=2 CONAHCNUJ_RENDER_MAX_COLS=6 \
    bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" "  line00 ...[+2 cols]" "line kept and clipped"
  assert_not_contains "${out}" "line0003" "lines past the cap dropped"
  assert_contains "${out}" "3 more lines truncated" "dropped line count announced"
  rm -rf "${tmp}"
  echo "render truncation passed"
}

test_outside_git_tree() {
  local tmp out
  tmp="$(mktemp -d)"
  # No git repo at all: the header degrades instead of failing.
  out="$(printf '%s\n' '{"type":"text","part":{"type":"text","text":"x"}}' |
    bash "${RENDER}" --model "m" --repo "o/r" --dir "${tmp}")"
  assert_contains "${out}" "m@o/r:${tmp}" "cwd shown as given"
  assert_contains "${out}" "- [detached] +0/-0" "git state degrades"
  assert_contains "${out}" "  x" "block still rendered"
  rm -rf "${tmp}"
  echo "render outside a git tree passed"
}

test_empty_and_unknown_events() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  # Blank lines and events with no content must not break the stream.
  out="$(printf '\n\n{"type":"step_start","part":{"type":"step-start"}}\n{"type":"something_new","part":{"type":"x"}}\n' |
    bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  [[ -z "${out}" ]] || fail "contentless events rendered output" "${out}"
  rm -rf "${tmp}"
  echo "render empty/unknown events passed"
}

test_header_context
test_header_repo_from_remote
test_header_dir_subdirectory
test_model_label_file_wins
test_text_and_reasoning
test_tool_success
test_tool_failure_exit_code
test_tool_error_status
test_tool_title_fallback
test_tool_input_does_not_shadow_state
test_session_error
test_escapes_are_decoded
test_non_json_passthrough
test_truncation_is_announced
test_outside_git_tree
test_empty_and_unknown_events

echo "All opencode-render tests passed"