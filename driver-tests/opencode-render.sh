#!/usr/bin/env bash
# Offline tests for lib/opencode-render.sh: no opencode, no network, no remote
# required. The fixtures use the event shapes opencode actually emits
# (captured from `opencode run --format json --thinking`).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RENDER="${HERE}/../lib/opencode-render.sh"

# A wrapping agent session (the conahcnuj opencode plugin) exports these for
# the real runs; the fixture expectations below must not see them.
unset CONAHCNUJ_MODEL_LABEL_FILE CONAHCNUJ_RENDER_MAX_LINES CONAHCNUJ_RENDER_MAX_COLS

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
  printf 'opencode/space-bunny-free (medium)\n' > "${tmp}/label.txt"
  out="$(printf '%s\n' '{"type":"text","part":{"type":"text","text":"x"}}' |
    CONAHCNUJ_MODEL_LABEL_FILE="${tmp}/label.txt" \
    bash "${RENDER}" --model "opencode/space-bunny-free" --dir "${tmp}/repo")"
  # The plugin's attribution label wins over the raw model id.
  assert_contains "${out}" "opencode/space-bunny-free (medium)@" "plugin label used"
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
  assert_contains "${out}" ".oO⎜ first thought" "reasoning rendered"
  assert_contains "${out}" "   ⎜ second thought" "second reasoning line"
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
    GITHUB_ACTIONS='' bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" '$ cat tracked.txt' "command line rendered"
  assert_contains "${out}" "  three" "tool output rendered"
  assert_not_contains "${out}" "✅" "command success is silent"
  assert_not_contains "${out}" "exit " "no exit code on success"
  # The verdict is printed (visible outside any collapsed group).
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
  assert_contains "${out}" "exit 1" "failure verdict with exit code"
  rm -rf "${tmp}"
  echo "render tool failure passed"
}

test_tool_timeout_is_failure() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  # opencode kills a command at its timeout and reports the call as completed
  # with no exit code; the <shell_metadata> block it appends to the output is
  # the only tell. A timed-out command is not a success (#420).
  out="$(cat <<'EOF' |
{"type":"tool_use","part":{"type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"bash driver-tests/run.sh"},"output":"(no output)\n\n<shell_metadata>\nshell tool terminated command after exceeding timeout 120000 ms. If this command is expected to take longer and is not waiting for interactive input, retry with a larger timeout value in milliseconds.\n</shell_metadata>\n","metadata":{"output":"(no output)\n\n<shell_metadata>\nshell tool terminated command after exceeding timeout 120000 ms. If this command is expected to take longer and is not waiting for interactive input, retry with a larger timeout value in milliseconds.\n</shell_metadata>\n","truncated":false},"title":"bash driver-tests/run.sh"}}}
EOF
    bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" "shell tool terminated command after exceeding timeout" "timeout reason kept in the feed"
  assert_contains "${out}" "(timed out)" "timed-out command is a failure"
  assert_not_contains "${out}" "✅" "timed-out command is not a success"
  rm -rf "${tmp}"
  echo "render tool timeout passed"
}

test_tool_no_output_sentinel_suppressed() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  out="$(printf '%s\n' '{"type":"tool_use","part":{"type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"true"},"output":"(no output)","metadata":{"exit":0},"title":"true"}}}' |
    GITHUB_ACTIONS='' bash "${RENDER}" --model "m" --dir "${tmp}/repo}")"
  assert_not_contains "${out}" "(no output)" "sentinel is not a real no-op output"
  assert_not_contains "${out}" "✅" "empty command is silent on success"
  rm -rf "${tmp}"
  echo "render tool no-output sentinel passed"
}

test_tool_no_output_real_print_kept() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  out="$(printf '%s\n' '{"type":"tool_use","part":{"type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"echo"},"output":"(no output)\n","metadata":{"exit":0},"title":"echo"}}}' |
    bash "${RENDER}" --model "m" --dir "${tmp}/repo}")"
  assert_contains "${out}" "  (no output)" "real (no output) print is kept"
  rm -rf "${tmp}"
  echo "render tool real no-output kept"
}

test_tool_no_output_after_real_output_kept() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  # "(no output)" as the final line of real multi-line output (no trailing
  # newline) is not the sentinel: only the first line can be, so it must stay.
  out="$(printf '%s\n' '{"type":"tool_use","part":{"type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"printf"},"output":"one\n(no output)","metadata":{"exit":0},"title":"printf"}}}' |
    bash "${RENDER}" --model "m" --dir "${tmp}/repo}")"
  assert_contains "${out}" "  one" "real output before (no output) kept"
  assert_contains "${out}" "  (no output)" "real trailing (no output) kept"
  rm -rf "${tmp}"
  echo "render tool no-output after real output passed"
}

test_tool_error_status() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  out="$(printf '%s\n' '{"type":"tool_use","part":{"type":"tool","tool":"bash","state":{"status":"error","input":{"command":"nope"},"error":"permission denied","title":"nope"}}}' |
    bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" "  ERROR: permission denied" "tool error message rendered"
  assert_contains "${out}" "❌️" "error verdict"
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
    GITHUB_ACTIONS='' bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" '$ make check' "falls back to the command"
  assert_not_contains "${out}" "✅" "command success is silent"
  # A tool that is not a command execution is not a prompt: no `$` line at all,
  # the tool name carries the verdict line by itself (issue #375).
  out="$(printf '%s\n' '{"type":"tool_use","part":{"type":"tool","tool":"todowrite","state":{"status":"completed","input":{},"output":"","metadata":{}}}}' |
    bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" "✅ Todowrite" "verdict line uses the tool name"
  rm -rf "${tmp}"
  echo "render tool title fallback passed"
}

test_tool_read_reports_in_one_line() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  # A successful read names the file it read and stops there (#375): not a
  # `$ read` prompt line, no whole-file dump in the log.
  out="$(printf '%s\n' '{"type":"tool_use","part":{"type":"tool","tool":"read","state":{"status":"completed","input":{"filePath":"tracked.txt"},"output":"one\ntwo\nthree\n","metadata":{},"title":"tracked.txt"}}}' |
    bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" "✅ Read tracked.txt" "read verdict line with the file"
  rm -rf "${tmp}"
  echo "render read one-line passed"
}

test_tool_read_failure() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  # The shape that opened the issue: a read with invalid arguments. The
  # reason it failed is the only thing worth recording, under a ❌️ line that
  # is a tool call, not a prompt.
  out="$(cat <<'EOF' |
{"type":"tool_use","part":{"type":"tool","tool":"read","state":{"status":"error","input":{},"error":"The read tool was called with invalid arguments: SchemaError(Missing key\n    at [\"filePath\"]).\n  Please rewrite the input so it satisfies the expected schema."}}}
EOF
    bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" "❌️ Read" "read failure verdict line"
  assert_contains "${out}" "  ERROR: The read tool was called with invalid arguments" "failure reason shown"
  assert_contains "${out}" "    at [\"filePath\"]" "multi-line error kept whole"
  rm -rf "${tmp}"
  echo "render read failure passed"
}

test_tool_edit_diff() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  # A successful edit shows what it rewrote: the diff the tool reported in its
  # metadata.
  out="$(printf '%s\n' '{"type":"tool_use","part":{"type":"tool","tool":"edit","state":{"status":"completed","input":{"filePath":"tracked.txt","oldString":"one","newString":"ONE"},"output":"edited","metadata":{"diff":"@ -1 +1 @@\n-one\n+ONE"}}}}' |
    bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" "✅ Edit tracked.txt" "edit verdict line with the file"
  # The diff is not indented: it stays at column 0 so it reads (and copies) as
  # a real diff instead of being nudged right by the block indent.
  assert_contains "${out}" $'✅ Edit tracked.txt\n@ -1 +1 @@' "the diff starts unindented under the verdict line"
  assert_contains "${out}" $'\n-one\n' "removed line in the diff"
  assert_contains "${out}" $'\n+ONE' "added line in the diff"
  assert_not_contains "${out}" "  @ -1 +1 @@" "the diff is not indented"
  assert_not_contains "${out}" "  -one" "removed line is not indented"
  assert_not_contains "${out}" "  +ONE" "added line is not indented"
  rm -rf "${tmp}"
  echo "render edit diff passed"
}

test_tool_edit_stitched_diff() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  # No metadata diff: an edit is still legible from its own arguments.
  out="$(printf '%s\n' '{"type":"tool_use","part":{"type":"tool","tool":"edit","state":{"status":"completed","input":{"filePath":"tracked.txt","oldString":"two","newString":"TWO\nmore"},"output":"edited","metadata":{"exit":0}}}}' |
    bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" "✅ Edit tracked.txt" "edit verdict line"
  assert_contains "${out}" $'\n- two\n' "the old text shows as removed, unindented"
  assert_contains "${out}" $'\n+ TWO\n' "the new text shows as added, unindented"
  assert_contains "${out}" $'\n+ more' "the second line of the new text"
  assert_not_contains "${out}" "  - two" "the stitched diff is not indented"
  assert_not_contains "${out}" "  + TWO" "the stitched added line is not indented"
  rm -rf "${tmp}"
  echo "render edit stitched diff passed"
}

test_tool_glob_reports_pattern_and_results() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  # A glob is a search, not a command: no `$ glob` prompt line, the pattern is
  # named on a 🔎 line and the matches are shown below it (#375).
  out="$(printf '%s\n' '{"type":"tool_use","part":{"type":"tool","tool":"glob","state":{"status":"completed","input":{"pattern":"*.txt"},"output":"/tmp/x/a.txt\n/tmp/x/b.txt\n","metadata":{"count":2,"truncated":false},"title":"tmp/x"}}}' |
    bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_not_contains "${out}" '$ glob' "glob is not rendered as a prompt"
  assert_contains "${out}" "🔎 Glob *.txt" "glob verdict line with the pattern"
  assert_contains "${out}" "  /tmp/x/a.txt" "glob results shown"
  assert_contains "${out}" "  /tmp/x/b.txt" "glob results shown"
  rm -rf "${tmp}"
  echo "render glob passed"
}

test_command_streams_as_it_prints() {
  local tmp out ones headers
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  # A command that prints as it runs: partial output while it is running (no
  # verdict yet), the tail and the verdict once it is done (#375).
  out="$(cat <<'EOF' |
{"type":"tool_use","part":{"id":"prt_s1","type":"tool","tool":"bash","state":{"status":"running","input":{"command":"cat tracked.txt"},"output":"one\ntwo\n"},"title":"cat tracked.txt"}}
{"type":"tool_use","part":{"id":"prt_s1","type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"cat tracked.txt"},"output":"one\ntwo\nthree\n","metadata":{"exit":0},"title":"cat tracked.txt"}}}
EOF
    GITHUB_ACTIONS='' bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" '$ cat tracked.txt' "the command line opens the block"
  assert_contains "${out}" "  one" "the first chunk is on the log"
  assert_contains "${out}" "  three" "the tail is appended"
  ones="$(printf '%s\n' "${out}" | grep -c '  one' || true)"
  [[ "${ones}" == "1" ]] || fail "running output printed again (${ones} copies)" "${out}"
  [[ "$(printf '%s\n' "${out}" | grep -c '✅')" == "0" ]] || fail "command success is silent" "${out}"
  headers="$(printf '%s\n' "${out}" | grep -c '\[main\]' || true)"
  [[ "${headers}" == "1" ]] || fail "a streaming tool block re-opened (${headers} headers)" "${out}"
  rm -rf "${tmp}"
  echo "render command streaming passed"
}

test_command_running_has_no_verdict_yet() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  # A command still in flight must not read as finished.
  out="$(printf '%s\n' '{"type":"tool_use","part":{"id":"prt_r1","type":"tool","tool":"bash","state":{"status":"running","input":{"command":"slow build"},"output":"compiling"},"title":"slow build"}}' |
    bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" "  compiling" "its partial output is on the log"
  rm -rf "${tmp}"
  echo "render running verdict passed"
}

test_command_grouped_in_github_actions() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  # On GitHub Actions every command block is wrapped in a collapsible log
  # group: the caption keeps its leading `$` (consistent with local runs)
  # and `::endgroup::` closes it once the command finishes.
  out="$(cat <<'EOF' |
{"type":"tool_use","part":{"id":"prt_g1","type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"cat tracked.txt"},"output":"one\ntwo\nthree\n","metadata":{"exit":0},"title":"cat tracked.txt"}}}
EOF
    GITHUB_ACTIONS=true bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" "::group::\$ cat tracked.txt" "group marker prefixes the caption"
  assert_contains "${out}" "::endgroup::" "group is closed at the verdict"
  rm -rf "${tmp}"
  echo "render command grouped in github actions passed"
}

test_command_grouped_streaming_in_github_actions() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  # A command that streams under GitHub Actions: the group opens on the first
  # sighting (running) and closes once the command finishes, so the partial
  # output and the verdict stay inside the collapsible group.
  out="$(cat <<'EOF' |
{"type":"tool_use","part":{"id":"prt_gs","type":"tool","tool":"bash","state":{"status":"running","input":{"command":"cat tracked.txt"},"output":"one\ntwo\n"},"title":"cat tracked.txt"}}
{"type":"tool_use","part":{"id":"prt_gs","type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"cat tracked.txt"},"output":"one\ntwo\nthree\n","metadata":{"exit":0},"title":"cat tracked.txt"}}}
EOF
    GITHUB_ACTIONS=true bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" "::group::\$ cat tracked.txt" "group marker opens on first sighting"
  assert_contains "${out}" "  one" "partial output is inside the group"
  assert_contains "${out}" "  three" "tail is inside the group"
  assert_contains "${out}" "::endgroup::" "group is closed at the verdict"
  [[ "$(printf '%s\n' "${out}" | grep -c '::group::')" == "1" ]] || fail "group opened more than once" "${out}"
  rm -rf "${tmp}"
  echo "render command grouped streaming in github actions passed"
}

test_command_group_closed_at_eof_in_github_actions() {
  local tmp out groups endgroups
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  # A command still running when the event stream ends (the round was cut off,
  # opencode exited mid-command, ...) must not leave its log group open: an
  # unclosed `::group::` makes GitHub Actions hide everything after it, which
  # is how the trailing ✅/❌️ lines went missing (#491).
  out="$(printf '%s\n' '{"type":"tool_use","part":{"id":"prt_ge","type":"tool","tool":"bash","state":{"status":"running","input":{"command":"slow build"},"output":"compiling"},"title":"slow build"}}' |
    GITHUB_ACTIONS=true bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" "::group::\$ slow build" "the unterminated command opens its group"
  assert_contains "${out}" "  compiling" "its partial output is on the log"
  assert_contains "${out}" "::endgroup::" "the dangling group is closed at end of stream"
  groups="$(printf '%s\n' "${out}" | grep -c '::group::' || true)"
  endgroups="$(printf '%s\n' "${out}" | grep -c '::endgroup::' || true)"
  [[ "${groups}" == "${endgroups}" ]] || fail "group not balanced (${groups} open / ${endgroups} close)" "${out}"
  # The end marker has to stand on its own log line; glued to partial output
  # GitHub Actions does not recognise it.
  [[ "$(printf '%s\n' "${out}" | tail -n 1)" == "::endgroup::" ]] || fail "::endgroup:: is not the last line" "${out}"
  rm -rf "${tmp}"
  echo "render command group closed at eof in github actions passed"
}

test_command_not_grouped_outside_github_actions() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  # Outside GitHub Actions the plain `$ <command>` caption is used and no
  # group markers are emitted.
  out="$(cat <<'EOF' |
{"type":"tool_use","part":{"id":"prt_g2","type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"cat tracked.txt"},"output":"one\ntwo\nthree\n","metadata":{"exit":0},"title":"cat tracked.txt"}}}
EOF
    GITHUB_ACTIONS='' bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" "\$ cat tracked.txt" "plain caption is used"
  assert_not_contains "${out}" "::group::" "no group marker outside GHA"
  assert_not_contains "${out}" "::endgroup::" "no endgroup marker outside GHA"
  rm -rf "${tmp}"
  echo "render command not grouped outside github actions passed"
}

test_command_grouped_in_github_actions_with_one() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  # `GITHUB_ACTIONS=1` is the other documented truthy spelling and must group
  # exactly like `GITHUB_ACTIONS=true`.
  out="$(cat <<'EOF' |
{"type":"tool_use","part":{"id":"prt_g3","type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"cat tracked.txt"},"output":"one\ntwo\nthree\n","metadata":{"exit":0},"title":"cat tracked.txt"}}}
EOF
    GITHUB_ACTIONS=1 bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" "::group::\$ cat tracked.txt" "group marker prefixes the caption with =1"
  assert_contains "${out}" "::endgroup::" "group is closed at the verdict with =1"
  rm -rf "${tmp}"
  echo "render command grouped in github actions with =1 passed"
}

test_command_not_grouped_with_unrecognized_github_actions() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  # Only `true` and `1` count as GitHub Actions; any other value (including
  # `false` and `0`) keeps the plain caption and no group markers.
  out="$(cat <<'EOF' |
{"type":"tool_use","part":{"id":"prt_g4","type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"cat tracked.txt"},"output":"one\ntwo\nthree\n","metadata":{"exit":0},"title":"cat tracked.txt"}}}
EOF
    GITHUB_ACTIONS=0 bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" "\$ cat tracked.txt" "plain caption is used for =0"
  assert_not_contains "${out}" "::group::" "no group marker for =0"
  assert_not_contains "${out}" "::endgroup::" "no endgroup marker for =0"
  rm -rf "${tmp}"
  echo "render command not grouped for unrecognized github actions passed"
}

test_streamed_text_prints_only_the_tail() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  # An answer streaming in chunks is appended to its block, not printed over
  # from the top every chunk (#375).
  out="$(cat <<'EOF' |
{"type":"text","part":{"id":"prt_t1","type":"text","text":"hello world"}}
{"type":"text","part":{"id":"prt_t1","type":"text","text":"hello world\nsecond line"}}
{"type":"text","part":{"id":"prt_t1","type":"text","text":"hello world\nsecond line\nthird line"}}
EOF
    bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  for needle in "hello world" "second line" "third line"; do
    [[ "$(printf '%s\n' "${out}" | grep -c "  ${needle}")" == "1" ]] || fail "${needle} printed twice" "${out}"
  done
  headers="$(printf '%s\n' "${out}" | grep -c '\[main\]' || true)"
  [[ "${headers}" == "1" ]] || fail "a streamed text block re-opened (${headers} headers)" "${out}"
  rm -rf "${tmp}"
  echo "render streamed text passed"
}

test_stream_snapshot_older_than_printed() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  # A resumed session replays parts, sometimes as older, shorter snapshots:
  # what is already printed must not print again.
  out="$(cat <<'EOF' |
{"type":"reasoning","part":{"id":"prt_o1","type":"reasoning","text":"thought\nmore thought"}}
{"type":"reasoning","part":{"id":"prt_o1","type":"reasoning","text":"thought"}}
EOF
    bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  [[ "$(printf '%s\n' "${out}" | grep -c 'thought')" == "2" ]] || fail "stale snapshot reprinted lines" "${out}"
  headers="$(printf '%s\n' "${out}" | grep -c '\[main\]' || true)"
  [[ "${headers}" == "1" ]] || fail "a stale snapshot re-opened the block (${headers} headers)" "${out}"
  rm -rf "${tmp}"
  echo "render stale snapshot passed"
}

test_tool_input_does_not_shadow_state() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  # A tool is free to take its own output/title arguments; the renderer must
  # read state.output / state.title, not the argument object.
  out="$(printf '%s\n' '{"type":"tool_use","part":{"type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"echo hi","output":"decoy output","title":"decoy title"},"output":"real output\n","metadata":{"exit":0},"title":"echo hi"}}}' |
    GITHUB_ACTIONS='' bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" "  real output" "state.output wins over the tool argument"
  assert_not_contains "${out}" "decoy output" "tool argument output ignored"
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

test_nothing_is_truncated() {
  local tmp out long i
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  long="$(printf 'word%.0s' $(seq 1 200))"
  # Neither half of a block is clipped: a model's own prose wraps far past any
  # line, and a command can print a long line or a very long log, but the run
  # log is the only record of the run and a shortened block is indistinguishable
  # from something the model never said (issue #111).
  out="$(cat <<EOF | bash "${RENDER}" --model "m" --dir "${tmp}/repo"
{"type":"reasoning","part":{"type":"reasoning","text":"${long}\nsecond thought"}}
{"type":"text","part":{"type":"text","text":"first answer\nsecond answer\nthird answer"}}
{"type":"tool_use","part":{"type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"big"},"output":"${long}\nline0001\nline0002\nline0003\nline0004\nline0005","metadata":{"exit":0},"title":"big"}}}
EOF
  )"
  assert_contains "${out}" "  ${long}" "long line kept in full"
  assert_contains "${out}" "   ⎜ second thought" "reasoning paragraph not cut short"
  assert_contains "${out}" "  third answer" "text block not cut short"
  assert_contains "${out}" "  line0005" "last line of the tool output kept"
  for ((i = 1; i <= 5; i++)); do
    assert_contains "${out}" "  line000${i}" "tool output line ${i} kept"
  done
  assert_not_contains "${out}" "cols]" "no column truncation"
  assert_not_contains "${out}" "truncated" "no line truncation"
  rm -rf "${tmp}"
  echo "render nothing truncated passed"
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

test_replayed_part_rendered_once() {
  local tmp out headers
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  # The same part (same id, identical payload) arriving again -- session
  # replay / stream reconnect -- must not print a second copy of the block,
  # or a handoff chain prints the whole session once per round.
  out="$(cat <<'EOF' |
{"type":"text","part":{"id":"prt_a1","type":"text","text":"hello once"}}
{"type":"text","part":{"id":"prt_a1","type":"text","text":"hello once"}}
{"type":"tool_use","part":{"id":"prt_b2","type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"pwd"},"output":"/x\n","metadata":{"exit":0},"title":"pwd"}}}
{"type":"tool_use","part":{"id":"prt_b2","type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"pwd"},"output":"/x\n","metadata":{"exit":0},"title":"pwd"}}}
EOF
    GITHUB_ACTIONS='' bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  headers="$(printf '%s\n' "${out}" | grep -c '\[main\]' || true)"
  [[ "${headers}" == "2" ]] || fail "replayed part printed again (${headers} headers)" "${out}"
  [[ "$(printf '%s\n' "${out}" | grep -c 'hello once')" == "1" ]] || fail "text duplicated" "${out}"
  [[ "$(printf '%s\n' "${out}" | grep -c '\$ pwd')" == "1" ]] || fail "tool duplicated" "${out}"
  rm -rf "${tmp}"
  echo "render replayed part once passed"
}

test_distinct_parts_and_updates_still_render() {
  local tmp out
  tmp="$(mktemp -d)"
  fixture_repo "${tmp}/repo"
  # Same content under a *different* part id is a real new event, and the
  # same id carrying *changed* content is a real update: neither is a replay.
  # An update to a part that streams prints inside its block (the part grew),
  # so only the genuinely new part opens a new header.
  out="$(cat <<'EOF' |
{"type":"text","part":{"id":"prt_c1","type":"text","text":"same words"}}
{"type":"text","part":{"id":"prt_c2","type":"text","text":"same words"}}
{"type":"text","part":{"id":"prt_c1","type":"text","text":"same words but revised"}}
EOF
    bash "${RENDER}" --model "m" --dir "${tmp}/repo")"
  assert_contains "${out}" "  same words but revised" "updated content rendered"
  rm -rf "${tmp}"
  echo "render distinct parts and updates passed"
}

test_header_context
test_header_repo_from_remote
test_header_dir_subdirectory
test_model_label_file_wins
test_text_and_reasoning
test_tool_success
test_tool_failure_exit_code
test_tool_timeout_is_failure
test_tool_no_output_sentinel_suppressed
test_tool_no_output_real_print_kept
test_tool_no_output_after_real_output_kept
test_tool_error_status
test_tool_title_fallback
test_tool_read_reports_in_one_line
test_tool_read_failure
test_tool_edit_diff
test_tool_edit_stitched_diff
test_tool_glob_reports_pattern_and_results
test_command_streams_as_it_prints
test_command_running_has_no_verdict_yet
test_command_grouped_in_github_actions
test_command_grouped_streaming_in_github_actions
test_command_group_closed_at_eof_in_github_actions
test_command_not_grouped_outside_github_actions
test_command_grouped_in_github_actions_with_one
test_command_not_grouped_with_unrecognized_github_actions
test_streamed_text_prints_only_the_tail
test_stream_snapshot_older_than_printed
test_tool_input_does_not_shadow_state
test_session_error
test_escapes_are_decoded
test_non_json_passthrough
test_nothing_is_truncated
test_outside_git_tree
test_empty_and_unknown_events
test_replayed_part_rendered_once
test_distinct_parts_and_updates_still_render

echo "All opencode-render tests passed"