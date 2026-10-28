#!/usr/bin/env bash
# opencode-render - turn the raw `opencode run --format json` event stream into
# the driver's own run log.
#
# Usage:
#   bash lib/opencode-render.sh [--model provider/model] [--repo owner/repo]
#                              [--dir <work tree>] < events.jsonl > log
#
# opencode writes one JSON event per line. Raw, it says nothing about what
# happened, so every content-bearing event (assistant text, reasoning, a tool
# call, a session error) becomes a block introduced by a single context header:
#
#   Space Bunny (medium)@owner/repo:.  1a2b3c4 [main] +12/-3 +2 new
#   $ git status --short
#
#     M lib/opencode.sh
#
#   ✅ git status --short
#
# What the model does without executing a command is not typed at a prompt, so
# it never renders as one: a `read` / `edit` / ... tool call reports in a single
# verdict line, ✅ Read <filepath> / ❌️ Read <filepath>, and a successful edit
# puts the diff it produced below the line (an editor rewrote the file, so show
# the rewrite).
#
# Blocks stream as the events arrive: text, reasoning and the output of a
# command line are printed as they are produced -- a part that grows (a
# streaming answer, a command feeding its stdout) prints only the lines it has
# not printed yet, and a command's verdict appears only when the command is
# over, never as an early pass while it is still running. A part replaying an
# older snapshot (session resumes, stream reconnects) prints nothing again.
#
# The header is re-read per block (SHA / branch / diff are queried again), so it
# always describes the moment the block was produced. That only means anything
# while the driver streams: render from a live pipe, not from a dump taken
# after the run finished.
#
# This is a log formatter and must never break a run: no `set -e` here, unknown
# events are dropped, and lines that are not JSON pass through verbatim. Its
# exit status is ignored by the caller for the same reason.
#
# Nothing is ever clipped: there is no line cap, no column cap and no "...[+N
# cols]" marker, neither for the agent's own text and reasoning nor for what a
# command printed. This log is the run's only record of what happened -- an
# abnormal exit files its tail as a bug report -- so a shortened block would be
# a hole in the evidence that nobody could tell apart from something the model
# never said.

set -uo pipefail

export LC_ALL=C
export LANG=C

GROUP_DEPTH=0

close_open_groups() {
  if [[ "${GITHUB_ACTIONS:-}" == "true" || "${GITHUB_ACTIONS:-}" == "1" ]]; then
    while [[ "${GROUP_DEPTH}" -gt 0 ]]; do
      close_line
      echo '::endgroup::'
      GROUP_DEPTH=$((GROUP_DEPTH - 1))
    done
  fi
}

INDENT="  "
SEP=$'\x1f'

MODEL=""
REPO=""
DIR="${PWD}"

while [[ $# -gt 0 ]]; do
  case "${1}" in
    --model)
      MODEL="${2:-}"
      shift 2
      ;;
    --repo)
      REPO="${2:-}"
      shift 2
      ;;
    --dir)
      DIR="${2:-}"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

# --- awk extractor ----------------------------------------------------------
#
# One awk pass per event pulls every field the renderer needs out of the line.
# Values are printed as "<tag><SEP><line>" (one output line per line of the
# value) so multi-line payloads survive the trip through bash, and JSON string
# escapes are decoded on the way out.
#
# Deliberately a scanner, not a JSON parser: the event shapes come from
# opencode's own serializer (type / timestamp / sessionID / part, keys in
# insertion order), so resolving a key by looking it up in the enclosing object
# is exact here and far smaller than a parser. Nesting from part down is what
# keeps a tool input of {"command":"…","output":"…"} from shadowing the real
# state.output.
# \uXXXX escapes are decoded into their UTF-8 characters so the terminal
# shows the text the model/API actually produced instead of a literal escape.
IFS= read -r -d '' RENDER_AWK <<'AWK' || true
function val_end(s, i,  c, j, depth) {
  c = substr(s, i, 1)
  if (c == "\"") {
    j = i + 1
    while (j <= length(s)) {
      c = substr(s, j, 1)
      if (c == "\\") {
        j += 2
        continue
      }
      if (c == "\"") return j
      j++
    }
    return length(s)
  }
  if (c != "{" && c != "[") {
    j = i
    while (j <= length(s)) {
      c = substr(s, j, 1)
      if (c == "," || c == "}" || c == "]") break
      j++
    }
    return j - 1
  }
  depth = 0
  j = i
  while (j <= length(s)) {
    c = substr(s, j, 1)
    if (c == "\"") {
      j = val_end(s, j) + 1
      continue
    }
    if (c == "{" || c == "[") {
      depth++
    } else if (c == "}" || c == "]") {
      depth--
      if (depth == 0) return j
    }
    j++
  }
  return length(s)
}
function field(s, key, start,  re, i, off) {
  # start (1-based) lets a caller skip an object it has already read, so a key
  # nested inside that object can never shadow the real one.
  off = start ? start - 1 : 0
  re = "\"" key "\"[ \t]*:[ \t]*"
  if (!match(substr(s, off + 1), re)) return ""
  i = off + RSTART + RLENGTH
  return substr(s, i, val_end(s, i) - i + 1)
}
function field_end(s, key,  re) {
  re = "\"" key "\"[ \t]*:[ \t]*"
  if (!match(s, re)) return 0
  return val_end(s, RSTART + RLENGTH)
}
function hexval(ch,  v) {
  if (ch >= "0" && ch <= "9") v = index("0123456789", ch) - 1
  else if (ch >= "a" && ch <= "f") v = index("abcdef", ch) + 9
  else if (ch >= "A" && ch <= "F") v = index("ABCDEF", ch) + 9
  else v = 0
  return v
}
function ishex(ch) {
  return (ch >= "0" && ch <= "9") || (ch >= "a" && ch <= "f") || (ch >= "A" && ch <= "F")
}
function codepoint(s, i,  j, cp, ch, valid) {
  # decode a single \uXXXX at position i (1-based, pointing at 'u' is not
  # needed; caller passes index of the backslash). Returns the code point,
  # or -1 when the escape is not a valid \uXXXX (so the caller can leave
  # it untouched instead of fabricating a code point from non-hex digits).
  valid = 1
  cp = 0
  for (j = 0; j < 4; j++) {
    ch = substr(s, i + 2 + j, 1)
    if (!ishex(ch)) { valid = 0; break }
    cp = cp * 16 + hexval(ch)
  }
  if (!valid) return -1
  return cp
}
function utf8(cp,  out, b1, b2, b3, b4) {
  # Encode a code point as UTF-8 bytes (awk prints bytes under LC_ALL=C).
  if (cp < 128) {
    out = sprintf("%c", cp)
  } else if (cp < 2048) {
    b1 = 192 + int(cp / 64)
    b2 = 128 + (cp % 64)
    out = sprintf("%c%c", b1, b2)
  } else if (cp < 65536) {
    b1 = 224 + int(cp / 4096)
    b2 = 128 + int((cp % 4096) / 64)
    b3 = 128 + (cp % 64)
    out = sprintf("%c%c%c", b1, b2, b3)
  } else {
    b1 = 240 + int(cp / 262144)
    b2 = 128 + int((cp % 262144) / 4096)
    b3 = 128 + int((cp % 4096) / 64)
    b4 = 128 + (cp % 64)
    out = sprintf("%c%c%c%c", b1, b2, b3, b4)
  }
  return out
}
function unescape(s,  out, i, n, c, e, cp, low) {
  if (substr(s, 1, 1) != "\"") return s
  s = substr(s, 2, length(s) - 2)
  out = ""
  i = 1
  n = length(s)
  while (i <= n) {
    c = substr(s, i, 1)
    if (c != "\\") {
      out = out c
      i++
      continue
    }
    e = substr(s, i + 1, 1)
    if (e == "n") { out = out "\n"; i += 2; continue }
    else if (e == "t") { out = out "\t"; i += 2; continue }
    else if (e == "r") { out = out "\r"; i += 2; continue }
    else if (e == "b") { out = out "\b"; i += 2; continue }
    else if (e == "f") { out = out "\f"; i += 2; continue }
    else if (e == "/") { out = out "/"; i += 2; continue }
    else if (e == "u") {
      cp = codepoint(s, i)
      # Not a real escape: keep the backslash and the 'u' verbatim and let the
      # following characters be processed normally.
      if (cp < 0) {
        out = out "\\u"
        i += 2
        continue
      }
      # surrogate pair
      if (cp >= 55296 && cp <= 56319 && i + 11 <= n && substr(s, i + 6, 2) == "\\u") {
        low = codepoint(s, i + 6)
        if (low >= 56320 && low <= 57343) {
          cp = 65536 + (cp - 55296) * 1024 + (low - 56320)
          i += 6
        }
      }
      # A lone surrogate, NUL, an out-of-range code point, or any other
      # control character (C0 except the whitespace escapes handled above,
      # DEL and the C1 controls) cannot be safely rendered to a terminal:
      # keep the escape so the terminal never receives a raw control byte.
      if ((cp >= 55296 && cp <= 57343) || cp == 0 || (cp >= 1 && cp <= 31 && cp != 8 && cp != 9 && cp != 10 && cp != 12 && cp != 13) || cp == 127 || (cp >= 128 && cp <= 159) || cp > 1114111) {
        out = out "\\u" substr(s, i + 2, 4)
        i += 6
        continue
      }
      out = out utf8(cp)
      i += 6
      continue
    }
    else { out = out e; i += 2; continue }
  }
  return out
}
function emit(tag, raw,  v, n, a, i, ends_nl) {
  v = unescape(raw)
  ends_nl = (length(v) > 0 && substr(v, length(v), 1) == "\n")
  n = split(v, a, "\n")
  # A payload that ends with a newline splits into a trailing empty element;
  # print() adds the newline back, so dropping it keeps one trailing blank
  # line from being invented. But the newline is information too -- a part
  # that streams glues its next chunk onto a line that did not end -- so an
  # additional (empty) element remembers the break for the shell side.
  if (n > 0 && a[n] == "") n--
  for (i = 1; i <= n; i++) printf "%s%s%s\n", tag, sep, a[i]
  if (ends_nl) printf "%s%s\n", tag, sep
}
{
  p = field($0, "part")
  s = field(p, "state")
  i = field(s, "input")
  # state.input can carry its own "output" / "title" / "metadata" arguments, so
  # everything the serializer writes after "input" is looked up from there on
  # and never inside the tool's own arguments.
  after = field_end(s, "input") + 1
  e = field($0, "error")
  emit("type", field($0, "type"))
  emit("tool", field(p, "tool"))
  emit("status", field(s, "status"))
  emit("title", field(s, "title", after))
  emit("command", field(i, "command"))
  # The file-oriented arguments the tool-specific captions name (✅ Read
  # <path>); the field() start argument keeps state.output / state.title /
  # state.metadata from being shadowed by the tool's own argument object.
  emit("filepath", field(i, "filePath"))
  emit("pattern", field(i, "pattern"))
  emit("oldstr", field(i, "oldString"))
  emit("newstr", field(i, "newString"))
  emit("output", field(s, "output", after))
  emit("exit", field(field(s, "metadata", after), "exit"))
  # The diff an edit tool reports in its metadata, so a successful edit can
  # show what it rewrote.
  emit("diff", field(field(s, "metadata", after), "diff"))
  emit("toolerror", field(s, "error", after))
  emit("errmsg", field(field(e, "data"), "message"))
  emit("errname", field(e, "name"))
  emit("text", field(p, "text"))
  # opencode puts the part id at the top level for tool_use events and
  # inside part for text/reasoning events, so read both.
  _topid = field($0, "id")
  if (_topid == "") _topid = field(p, "id")
  emit("id", _topid)
}
AWK

# --- field extraction -------------------------------------------------------

# Per-event field bag, filled by render_fields. Every key is pre-created so a
# missing field reads as empty under `set -u`, and a separate SEEN set tells an
# absent field apart from one whose first line is blank.
declare -A F=(
  [type]="" [tool]="" [status]="" [title]="" [command]=""
  [filepath]="" [pattern]="" [oldstr]="" [newstr]=""
  [output]="" [exit]="" [diff]="" [toolerror]="" [errmsg]="" [errname]="" [text]=""
  [id]=""
)
declare -A SEEN=()
# Part ids already rendered, mapped to their content fingerprint. opencode can
# replay parts (session resumes, stream reconnects), and the same part must
# never be printed twice in the run log or troubleshooting drowns in copies.
declare -A SEEN_PARTS=()
# What each part has already put in the log, so a part that streams (an answer
# growing chunk by chunk, a command feeding its stdout) prints only what is
# new instead of printing its block over from the top. Keyed by part id; an
# event without one keeps the stateless one-shot rendering.
declare -A PART_TEXT=()   # text / reasoning streamed so far
declare -A PART_OUT=()    # command output streamed so far
declare -A PART_ERR=()    # tool error message streamed so far
declare -A PART_MODE=()   # tool shape: "true" executes commands, "false" does not
declare -A PART_STATE=()  # the verdict has been printed for this part
declare -A PART_FED=()    # the feed (output / error) has started for this part

# Whether the log's last line is half-written: streamed parts keep growing one
# and glue their continuation onto it instead of starting a new line.
OPENLINE=0
# A command that has started (running) but not yet completed: while one is
# open, subsequent blocks are buffered so the command's result lands before
# the next model name (header) instead of after it.
OPEN_CMD_PID=""
declare -a BUFFERED_EVENTS=()
FLUSHING="false"

render_fields() {
  local tag value nl=$'\n'
  local -a keys=(
    type tool status title command filepath pattern oldstr newstr output exit diff
    toolerror errmsg errname text id
  )
  local key
  for key in "${keys[@]}"; do
    F["${key}"]=""
    unset 'SEEN[$key]'
  done
  while IFS="${SEP}" read -r tag value; do
    [[ -n "${tag}" ]] || continue
    if [[ -n "${SEEN[${tag}]:-}" ]]; then
      F["${tag}"]="${F[${tag}]}${nl}${value}"
    else
      F["${tag}"]="${value}"
      SEEN["${tag}"]=1
    fi
  done < <(printf '%s\n' "${1}" | LC_ALL=C awk -v sep="${SEP}" "${RENDER_AWK}" 2>/dev/null)
  # opencode's "(no output)" sentinel is not a real command output: drop it (and
  # any blank lines it leaves behind) so a command that printed nothing shows
  # nothing. Only the first line can be the sentinel -- either the whole output
  # (no trailing newline) or the opener of a timed-out command's
  # <shell_metadata> block. A genuine "(no output)" -- printed with its own
  # trailing newline, or appearing after other real output -- is kept.
  local _raw="${F[output]}" _result="" _line _first=1
  local -a _lines=() _keep=()
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    _lines+=("${_line}")
  done <<< "${_raw}"
  local _n="${#_lines[@]}" _i _j
  for ((_i = 0; _i < _n; _i++)); do
    if [[ "${_i}" -eq 0 && "${_lines[$_i]}" == "(no output)" ]]; then
      _j=$((_i + 1))
      while ((_j < _n)) && [[ -z "${_lines[$_j]// }" ]]; do
        _j=$((_j + 1))
      done
      if ((_j >= _n)); then
        # Sentinel only if "(no output)" is the final line (no trailing newline).
        if ((_i == _n - 1)); then
          continue
        fi
      elif [[ "${_lines[$_j]}" == "<shell_metadata>"* ]]; then
        continue
      fi
    fi
    _keep+=("${_lines[$_i]}")
  done
  _first=1
  for _line in "${_keep[@]}"; do
    if [[ "${_first}" == "1" ]]; then
      _result="${_line}"
      _first=0
    else
      _result="${_result}"$'\n'"${_line}"
    fi
  done
  while [[ "${_result}" == $'\n'* ]]; do
    _result="${_result#?}"
  done
  if [[ -z "${_result//[$'\n' ]/}" ]]; then
    _result=""
  fi
  F["output"]="${_result}"
}

# --- context header ---------------------------------------------------------

# Model label: the plugin writes the session's attribution
# (provider (model/effort)) into CONAHCNUJ_MODEL_LABEL_FILE while the run is
# in flight, so read it live and fall back to the model id the driver asked
# for.
render_model_label() {
  local label=""
  if [[ -n "${CONAHCNUJ_MODEL_LABEL_FILE:-}" && -s "${CONAHCNUJ_MODEL_LABEL_FILE}" ]]; then
    label="$(head -n 1 "${CONAHCNUJ_MODEL_LABEL_FILE}" 2>/dev/null | tr -d '\r')"
  fi
  [[ -n "${label}" ]] || label="${MODEL}"
  [[ -n "${label}" ]] || label="opencode"
  printf '%s' "${label}"
}

# owner/repo: explicit --repo wins, else the origin remote, else nothing.
render_repo() {
  local url
  if [[ -n "${REPO}" ]]; then
    printf '%s' "${REPO}"
    return 0
  fi
  url="$(git -C "${DIR}" remote get-url origin 2>/dev/null || true)"
  [[ -n "${url}" ]] || return 0
  # owner/repo only: a URL that carries a path beyond it (…/repo/tree/main)
  # still names the same repository.
  printf '%s' "${url}" | sed -E 's#.*github\.com[:/]##; s#\.git$##' | cut -d/ -f1,2
}

# Directory as seen from the repository root ("." at the root, a relative path
# in a subdirectory), falling back to the path itself outside a work tree.
# --show-prefix is asked for rather than comparing pwd against --show-toplevel
# because the two spell a Windows path differently (git says C:/x, bash says
# /c/x), which would make every Windows header fall back to the full path.
render_dir() {
  local prefix
  prefix="$(git -C "${DIR}" rev-parse --show-prefix 2>/dev/null || true)"
  if [[ -z "${prefix}" ]]; then
    # Empty means the work tree root; a non-empty result is the relative path
    # with git's trailing slash.
    if git -C "${DIR}" rev-parse --show-toplevel >/dev/null 2>&1; then
      printf '.'
    else
      printf '%s' "${DIR}"
    fi
    return 0
  fi
  printf '%s' "${prefix%/}"
}

# Working-tree state: short SHA, branch, and the diff so far. Untracked files
# are counted separately (+N new) because a fresh implementation creates files
# before staging them and a plain diff would read as "no work yet".
render_sha() {
  git -C "${DIR}" rev-parse --verify --short HEAD 2>/dev/null || printf '%s' "-"
}

render_branch() {
  local name
  name="$(git -C "${DIR}" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  [[ -n "${name}" ]] || name="detached"
  printf '%s' "${name}"
}

render_diff() {
  # The third numstat column (the path) is discarded: only the two counters
  # matter for the header.
  local add del stat="" adds=0 dels=0 new
  while IFS=$'\t' read -r add del _; do
    [[ "${add}" =~ ^[0-9]+$ ]] || add=0
    [[ "${del}" =~ ^[0-9]+$ ]] || del=0
    adds=$((adds + add))
    dels=$((dels + del))
  done < <(git -C "${DIR}" diff --numstat HEAD 2>/dev/null || true)
  stat="+${adds}/-${dels}"
  new="$(git -C "${DIR}" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d '[:space:]')"
  if [[ "${new}" =~ ^[0-9]+$ ]] && [[ "${new}" -gt 0 ]]; then
    stat="${stat} +${new} new"
  fi
  printf '%s' "${stat}"
}

# Close a half-written line only when there is one, without inventing a blank.
close_line() {
  [[ "${OPENLINE}" == "1" ]] || return 0
  print_newline
}

render_header() {
  # A part that streams can leave its last line half-written; a header starts
  # a new line of the log, so close the open one first.
  close_line
  # If a command block is still open (its command has not verdicted yet) when a
  # new block starts, close that group first so the previous command's result
  # precedes this block's header (the model name) instead of swallowing it in
  # GitHub Actions' collapsed log.
  if [[ "${GITHUB_ACTIONS:-}" == "true" || "${GITHUB_ACTIONS:-}" == "1" ]]; then
    while [[ "${GROUP_DEPTH}" -gt 0 ]]; do
      echo '::endgroup::'
      GROUP_DEPTH=$((GROUP_DEPTH - 1))
    done
  fi
  printf '%-*s  %s [%s] %s\n' 44 \
    "$(render_model_label)@$(render_repo):$(render_dir)" \
    "$(render_sha)" "$(render_branch)" "$(render_diff)"
}

# Start a fresh line of the log, closing a part's half-written line first.
# Use this for the spacing the blocks put between their feed and their verdict
# -- when the last line is half-written the closure doubles as the break.
print_newline() {
  printf '\n'
  OPENLINE=0
}

# --- block bodies -----------------------------------------------------------

# Print text indented under its block, line by line, exactly as it was
# produced: every line the model wrote or the command printed comes out whole,
# and a blank line stays a blank line.
render_indent() {
  local value="${1:-}"
  local line
  [[ -n "${value}" ]] || return 0
  while IFS= read -r line; do
    printf '%s%s\n' "${INDENT}" "${line}"
  done <<< "${value}"
}

# Append a streaming part's next chunk to the log, keeping what has been
# written so far exactly where it is. The first segment glues onto a
# half-written line (a streamed answer grows token by token, mid-line); a
# fresh line starts with the indent; the optional prefix is glued to the
# first whole line, for the "ERROR: " the tool errors carry. A trailing chunk
# without a newline leaves the line half-written for the next chunk (the
# global OPENLINE tracks that).
render_stream() {
  local value="${1:-}" prefix="${2:-}" line rest first=1 more=0
  local had_nl=1
  [[ -n "${value}" ]] || return 0
  if [[ "${value}" == *$'\n' ]]; then
    value="${value%$'\n'}"
  else
    had_nl=0
  fi
  while :; do
    line="${value%%$'\n'*}"
    rest=""
    more=0
    if [[ "${value}" == *$'\n'* ]]; then
      rest="${value#*$'\n'}"
      more=1
    fi
    if [[ "${OPENLINE}" == "1" ]]; then
      printf '%s' "${line}"
      OPENLINE=0
      prefix=""
    elif [[ "${first}" == "1" ]]; then
      printf '%s%s%s' "${INDENT}" "${prefix}" "${line}"
    else
      printf '%s%s' "${INDENT}" "${line}"
    fi
    if [[ "${more}" == "1" || "${had_nl}" == "1" ]]; then
      printf '\n'
    fi
    first=0
    [[ "${more}" == "0" ]] && break
    value="${rest}"
  done
  if [[ "${had_nl}" == "0" ]]; then
    OPENLINE=1
  else
    OPENLINE=0
  fi
  return 0
}

# Print text indented, every line under a one-character marker ("-" / "+"),
# for the diff fragments the renderer has to stitch itself.
render_marked() {
  local value="${1:-}" marker="${2:-}" line
  [[ -n "${value}" ]] || return 0
  while IFS= read -r line; do
    printf '%s %s\n' "${marker}" "${line}"
  done <<< "${value}"
}

# Tell a streamed part's next snapshot apart from what was already printed,
# and put the result in STREAM_KIND with the new text in STREAM_TAIL:
#   append -- the snapshot grew past the printed text; STREAM_TAIL is the tail
#   stale  -- the snapshot is an older, shorter copy of what was already shown
#             (a replay from a resumed session), so nothing prints
#   revise -- the content changed in place; the caller reprints it whole
STREAM_KIND=""
STREAM_TAIL=""
stream_delta() {
  local prev="${1:-}" next="${2:-}"
  STREAM_KIND="append"
  STREAM_TAIL=""
  if [[ "${next}" == "${prev}"* ]]; then
    STREAM_TAIL="${next#"${prev}"}"
    return 0
  fi
  if [[ "${prev}" == "${next}"* ]]; then
    STREAM_KIND="stale"
    return 0
  fi
  STREAM_KIND="revise"
}

# Assistant text and reasoning read the same way: the header says which step
# this is, the body is just the model's words, printed in full -- and, for a
# part id that streams, printed only as the words arrive.
render_block_text() {
  local pid="${F[id]}" prev
  if [[ -z "${pid}" ]]; then
    render_header
    render_stream "${F[text]}"
    return 0
  fi
  prev="${PART_TEXT[${pid}]:-}"
  if [[ -z "${prev}" ]]; then
    [[ -n "${F[text]}" ]] || return 0
    render_header
    render_stream "${F[text]}"
    PART_TEXT[${pid}]="${F[text]}"
    return 0
  fi
  stream_delta "${prev}" "${F[text]}"
  case "${STREAM_KIND}" in
    append) render_stream "${STREAM_TAIL}" ;;
    stale) return 0 ;;
    revise)
      # A revision reprints under a fresh header: the first lines already
      # shown are in the log, and staying silent would drop what changed.
      render_header
      render_stream "${F[text]}"
      ;;
  esac
  PART_TEXT[${pid}]="${F[text]}"
}

# A tool call. Command execution keeps the `$ <command>` shape and streams
# whatever the command printed as it is produced; the verdict comes once the
# command is over (a "running" update must never read as an early pass), and
# a non-zero exit is still the failure, not state.status alone.
#
# Everything else is not something typed at a prompt, so it does not get one:
# a read / edit / ... call reports in a single verdict line, ✅ Read <filepath>
# / ❌️ Read <filepath> -- the reason it failed printed under the line -- and a
# successful edit puts the diff it produced below its own line. The file path
# and the diff come from the tool's own arguments (filePath) and metadata
# (diff); an edit that reported neither is stitched from its oldString /
# newString arguments.
render_block_tool() {
  local pid="${F[id]}" tool="${F[tool]}" code is_cmd=false label
  local prev_out="" prev_err="" prev_verdict="false" prev_fed="false" fed="false"
  [[ -z "${tool:-}" ]] && tool="tool"
  [[ "${tool}" == "bash" || -n "${F[command]}" ]] && is_cmd="true"
  local status="${F[status]}"
  code="${F[exit]}"
  case "${code}" in
    ''|*[!0-9]*) code="" ;;
  esac
  # opencode kills a command that hits its timeout and still reports the call as
  # "completed" with no exit code: the only tell is the <shell_metadata> block
  # it appends to the output ("shell tool terminated command after exceeding
  # timeout ..."). A timed-out command did not succeed, so it must not get a ✅
  # (#420).
  local timed_out="false"
  case "${F[output]}${F[toolerror]}" in
    *"terminated command after exceeding timeout"*) timed_out="true" ;;
  esac
  if [[ -n "${pid}" ]]; then
    prev_out="${PART_OUT[${pid}]:-}"
    prev_err="${PART_ERR[${pid}]:-}"
    [[ "${PART_STATE[${pid}]:-}" == "1" ]] && prev_verdict="true"
    [[ "${PART_FED[${pid}]:-}" == "1" ]] && prev_fed="true"
    fed="${prev_fed}"
  fi

  if [[ "${tool}" == "glob" ]]; then
    if [[ -z "${pid}" || -z "${PART_MODE[${pid}]:-}" ]]; then
      [[ -n "${pid}" ]] && PART_MODE[${pid}]="glob"
      render_header
      arg="${F[pattern]}"
      [[ -n "${arg}" ]] || arg="${F[title]}"
      [[ -n "${arg}" ]] || arg="${tool}"
      if [[ "${status}" == "error" ]]; then
        printf '❌️ Glob %s\n' "${arg}"
      else
        printf '🔎 Glob %s\n' "${arg}"
      fi
    fi
    if [[ -n "${F[output]}" ]]; then
      stream_delta "${prev_out}" "${F[output]}"
      if [[ "${STREAM_KIND}" != "stale" ]]; then
        if [[ "${fed}" == "false" ]]; then
          print_newline
          fed="true"
        fi
        if [[ "${STREAM_KIND}" == "revise" ]]; then
          close_line
          render_stream "${F[output]}"
        else
          render_stream "${STREAM_TAIL}"
        fi
        prev_out="${F[output]}"
      fi
    fi
    if [[ -n "${F[toolerror]}" ]]; then
      local err_prefix=""
      [[ -z "${prev_err}" ]] && err_prefix="ERROR: "
      stream_delta "${prev_err}" "${F[toolerror]}"
      if [[ "${STREAM_KIND}" != "stale" ]]; then
        if [[ "${fed}" == "false" ]]; then
          print_newline
          fed="true"
        fi
        close_line
        if [[ "${STREAM_KIND}" == "revise" ]]; then
          render_stream "${F[toolerror]}" "ERROR: "
        else
          render_stream "${STREAM_TAIL}" "${err_prefix}"
        fi
        prev_err="${F[toolerror]}"
      fi
    fi
    if [[ -n "${pid}" ]]; then
      PART_OUT[${pid}]="${prev_out}"
      PART_ERR[${pid}]="${prev_err}"
      [[ "${fed}" == "true" ]] && PART_FED[${pid}]=1
      PART_STATE[${pid}]=1
    fi
    return 0
  fi

  # First sighting of the part: open the block. A command execution carries
  # its `$` caption; anything else reports with the verdict line alone.
  if [[ -z "${pid}" || -z "${PART_MODE[${pid}]:-}" ]]; then
    [[ -n "${pid}" ]] && PART_MODE[${pid}]="${is_cmd}"
    render_header
    if [[ "${is_cmd}" == "true" ]]; then
      label="${F[title]}"
      [[ -n "${label}" ]] || label="${F[command]}"
      [[ -n "${label}" ]] || label="${tool}"
      # GitHub Actions collapses a run's log by `::group::`/`::endgroup::`
      # markers, so wrap each command block in one there and keep the plain
      # `$ <command>` caption everywhere else.
      if [[ "${GITHUB_ACTIONS:-}" == "true" || "${GITHUB_ACTIONS:-}" == "1" ]]; then
        echo -n '::group::'
        GROUP_DEPTH=$((GROUP_DEPTH + 1))
      fi
      echo "\$ ${label}"
    fi
  fi

  if [[ "${is_cmd}" == "false" ]]; then
    if [[ "${prev_verdict}" == "true" ]]; then
      return 0
    fi
    if [[ "${status}" != "completed" && "${status}" != "error" ]]; then
      return 0
    fi
    label="${tool^}"
    local arg="${F[filepath]}"
    [[ -n "${arg}" ]] || arg="${F[title]}"
    if [[ -n "${arg}" ]]; then
      label="${label} ${arg}"
    fi
    if [[ "${status}" == "error" ]]; then
      printf '❌️ %s\n' "${label}"
      if [[ -n "${F[toolerror]}" ]]; then
        print_newline
        render_stream "${F[toolerror]}" "ERROR: "
      fi
    else
      printf '✅ %s\n' "${label}"
      if [[ -n "${F[diff]}" ]]; then
        # The diff is its own structured text (unified diff): print it without
        # the block's indent so it stays copy-pasteable as a real diff.
        local _saved_indent="${INDENT}"
        INDENT=""
        render_stream "${F[diff]}"
        INDENT="${_saved_indent}"
      elif [[ "${tool}" == "edit" && ( -n "${F[oldstr]}" || -n "${F[newstr]}" ) ]]; then
        render_marked "${F[oldstr]}" "-"
        render_marked "${F[newstr]}" "+"
      fi
    fi
    [[ -n "${pid}" ]] && PART_STATE[${pid}]=1
    return 0
  fi

  # Command execution: stream the feed (whatever the command printed, then the
  # reason it failed) as it arrives, one growing block for the whole call.
  if [[ -n "${F[output]}" ]]; then
    stream_delta "${prev_out}" "${F[output]}"
    if [[ "${STREAM_KIND}" != "stale" ]]; then
      if [[ "${fed}" == "false" ]]; then
        print_newline
        fed="true"
      fi
      if [[ "${STREAM_KIND}" == "revise" ]]; then
        close_line
        render_stream "${F[output]}"
      else
        render_stream "${STREAM_TAIL}"
      fi
      prev_out="${F[output]}"
    fi
  fi
  if [[ -n "${F[toolerror]}" ]]; then
    local err_prefix=""
    [[ -z "${prev_err}" ]] && err_prefix="ERROR: "
    stream_delta "${prev_err}" "${F[toolerror]}"
    if [[ "${STREAM_KIND}" != "stale" ]]; then
      if [[ "${fed}" == "false" ]]; then
        print_newline
        fed="true"
      fi
      # An error is its own line of the feed, never a continuation of output.
      close_line
      if [[ "${STREAM_KIND}" == "revise" ]]; then
        render_stream "${F[toolerror]}" "ERROR: "
      else
        render_stream "${STREAM_TAIL}" "${err_prefix}"
      fi
      prev_err="${F[toolerror]}"
    fi
  fi
  if [[ -n "${pid}" ]]; then
    PART_OUT[${pid}]="${prev_out}"
    PART_ERR[${pid}]="${prev_err}"
    [[ "${fed}" == "true" ]] && PART_FED[${pid}]=1
  fi

  # The verdict: when the call is over, not while it is running.
  [[ "${prev_verdict}" == "true" ]] && return 0
  if [[ "${status}" != "completed" && "${status}" != "error" ]]; then
    return 0
  fi
  label="${F[title]}"
  [[ -n "${label}" ]] || label="${F[command]}"
  [[ -n "${label}" ]] || label="${tool}"
  # Close the collapsible group BEFORE the verdict line so the result (✅/❌️)
  # stays visible even when GitHub Actions collapses the command's group; the
  # verdict then precedes the next model name (header) instead of being hidden.
  if [[ "${GITHUB_ACTIONS:-}" == "true" || "${GITHUB_ACTIONS:-}" == "1" ]]; then
    if [[ "${GROUP_DEPTH}" -gt 0 ]]; then
      echo '::endgroup::'
      GROUP_DEPTH=$((GROUP_DEPTH - 1))
    fi
  fi
  [[ "${fed}" == "true" ]] && print_newline
  if [[ "${timed_out}" == "true" ]]; then
    printf '❌️ %s (timed out)\n' "${label}"
  elif [[ "${status}" == "error" ]] || { [[ -n "${code}" ]] && [[ "${code}" != "0" ]]; }; then
    if [[ -n "${code}" ]]; then
      printf '❌️ %s (exit %s)\n' "${label}" "${code}"
    else
      printf '❌️ %s\n' "${label}"
    fi
  else
    printf '✅ %s\n' "${label}"
  fi
  # The group was closed above (or already closed by a later block's header),
  # so no stray ::endgroup:: here.
  [[ -n "${pid}" ]] && PART_STATE[${pid}]=1
  return 0
}

# A session-level error (provider auth, rate limit, ...): no command ran, so
# just the header and the message.
render_block_error() {
  local msg="${F[errmsg]}"
  [[ -n "${msg}" ]] || msg="${F[errname]}"
  [[ -n "${msg}" ]] || msg="unknown error"
  render_header
  render_indent "❌️ ${msg}"
}

render_event() {
  local line="${1}"
  line="${line%$'\r'}"
  case "${line}" in
    '{'*) ;;
    '') return 0 ;;
    *)
      # Not a JSON object: pass it through so a stray line on the stream is
      # never silently dropped. opencode's own --print-logs output is not such
      # a line -- that goes to stderr, beside the rendered log, not into here.
      printf '%s\n' "${line}"
      return 0
      ;;
  esac
  render_fields "${line}"
  local pid="${F[id]}"
  # Same part id and identical content again: a replay (resumed session /
  # reconnected event stream), so print it once. Same id with *changed*
  # content still renders, the log must never drop a real update.
  if [[ -n "${pid}" && "${FLUSHING}" != "true" ]]; then
    local fp="${F[type]}|${F[status]}|${F[title]}|${F[command]}|${F[filepath]}|${F[pattern]}|${F[oldstr]}|${F[newstr]}|${F[output]}|${F[exit]}|${F[diff]}|${F[toolerror]}|${F[errmsg]}|${F[errname]}|${F[text]}"
    if [[ "${SEEN_PARTS[${pid}]:-}" == "${fp}" ]]; then
      return 0
    fi
    SEEN_PARTS[${pid}]="${fp}"
  fi
  # Buffering: while a command is still running, defer any subsequent block so
  # the command's result is printed before the next model name (header). The
  # deferred events are flushed once that command completes.
  local completes_open="false"
  if [[ -n "${OPEN_CMD_PID}" && "${pid}" == "${OPEN_CMD_PID}" && "${F[type]}" == "tool_use" ]]; then
    if [[ "${F[status]}" == "completed" || "${F[status]}" == "error" ]]; then
      completes_open="true"
    fi
  fi
  # An update to the command that is currently running is part of that
  # command's own stream: it must render live (so its incremental output is
  # shown as it arrives) instead of being deferred behind the buffered blocks.
  local is_open_cmd_update="false"
  if [[ -n "${OPEN_CMD_PID}" && "${pid}" == "${OPEN_CMD_PID}" && "${F[type]}" == "tool_use" ]]; then
    is_open_cmd_update="true"
  fi
  if [[ "${FLUSHING}" != "true" && "${is_open_cmd_update}" != "true" && "${#BUFFERED_EVENTS[@]}" -gt 0 && "${completes_open}" != "true" ]]; then
    BUFFERED_EVENTS+=("${line}")
    return 0
  fi
  if [[ "${FLUSHING}" != "true" && "${is_open_cmd_update}" != "true" && -n "${OPEN_CMD_PID}" && "${completes_open}" != "true" ]]; then
    BUFFERED_EVENTS+=("${line}")
    return 0
  fi
  case "${F[type]}" in
    text | reasoning) render_block_text ;;
    tool_use) render_block_tool ;;
    error) render_block_error ;;
    *)
      # step_start / step_finish and anything new: bookkeeping, not content.
      ;;
  esac
  # Track a command that is now running (incomplete) so later blocks buffer.
  if [[ "${FLUSHING}" != "true" && "${F[type]}" == "tool_use" && "${F[status]}" == "running" && -z "${OPEN_CMD_PID}" ]]; then
    OPEN_CMD_PID="${pid}"
  fi
  # When the open command completes, flush the deferred blocks. Only the
  # outer (non-nested) completion drives a flush, so a completion that is
  # itself being flushed does not toggle FLUSHING and break the outer loop.
  if [[ "${completes_open}" == "true" && "${FLUSHING}" != "true" ]]; then
    OPEN_CMD_PID=""
    local _buf
    FLUSHING="true"
    if [[ "${#BUFFERED_EVENTS[@]}" -gt 0 ]]; then
      for _buf in "${BUFFERED_EVENTS[@]}"; do
        render_event "${_buf}"
      done
    fi
    FLUSHING="false"
    BUFFERED_EVENTS=()
  fi
}

# Safety net: a group left open must never outlive the renderer (a signal or
# an early exit mid-command would otherwise hide the rest of the GitHub
# Actions log).
trap close_open_groups EXIT

while IFS= read -r render_line || [[ -n "${render_line}" ]]; do
  render_event "${render_line}"
done

# Flush any blocks that were deferred while a command was running, so a
# command that never completed still leaves the deferred output on the log.
OPEN_CMD_PID=""
FLUSHING="true"
if [[ "${#BUFFERED_EVENTS[@]}" -gt 0 ]]; then
  for _buf in "${BUFFERED_EVENTS[@]}"; do
    render_event "${_buf}"
  done
fi
FLUSHING="false"
BUFFERED_EVENTS=()

# Close any command group left open when the stream ended (e.g. a command that
# was still running) so GitHub Actions does not swallow the trailing output.
close_open_groups
