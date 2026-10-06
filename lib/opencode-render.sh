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
# \uXXXX escapes are left as-is: JSON.stringify never emits them for printable
# text, so they only show up for control bytes and lone surrogates.
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
function unescape(s,  out, i, n, c, e) {
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
    if (e == "n") out = out "\n"
    else if (e == "t") out = out "\t"
    else if (e == "r") out = out "\r"
    else if (e == "b") out = out "\b"
    else if (e == "f") out = out "\f"
    else if (e == "/") out = out "/"
    else out = out e
    i += 2
  }
  return out
}
function emit(tag, raw,  v, n, a, i) {
  v = unescape(raw)
  n = split(v, a, "\n")
  # A payload that ends with a newline splits into a trailing empty element;
  # print() adds the newline back, so dropping it keeps one trailing blank
  # line from being invented.
  if (n > 0 && a[n] == "") n--
  for (i = 1; i <= n; i++) printf "%s%s%s\n", tag, sep, a[i]
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
  emit("output", field(s, "output", after))
  emit("exit", field(field(s, "metadata", after), "exit"))
  emit("toolerror", field(s, "error", after))
  emit("errmsg", field(field(e, "data"), "message"))
  emit("errname", field(e, "name"))
  emit("text", field(p, "text"))
  emit("id", field(p, "id"))
}
AWK

# --- field extraction -------------------------------------------------------

# Per-event field bag, filled by render_fields. Every key is pre-created so a
# missing field reads as empty under `set -u`, and a separate SEEN set tells an
# absent field apart from one whose first line is blank.
declare -A F=(
  [type]="" [tool]="" [status]="" [title]="" [command]=""
  [output]="" [exit]="" [toolerror]="" [errmsg]="" [errname]="" [text]=""
  [id]=""
)
declare -A SEEN=()
# Part ids already rendered, mapped to their content fingerprint. opencode can
# replay parts (session resumes, stream reconnects), and the same part must
# never be printed twice in the run log or troubleshooting drowns in copies.
declare -A SEEN_PARTS=()

render_fields() {
  local tag value nl=$'\n'
  local -a keys=(
    type tool status title command output exit toolerror errmsg errname text id
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
  done < <(printf '%s\n' "${1}" | awk -v sep="${SEP}" "${RENDER_AWK}" 2>/dev/null)
}

# --- context header ---------------------------------------------------------

# Model label: the plugin writes the session's display name plus its effort
# variant into CONAHCNUJ_MODEL_LABEL_FILE while the run is in flight, so read
# it live and fall back to the model id the driver asked for.
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

render_header() {
  printf '%-*s  %s [%s] %s\n' 44 \
    "$(render_model_label)@$(render_repo):$(render_dir)" \
    "$(render_sha)" "$(render_branch)" "$(render_diff)"
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

# Assistant text and reasoning read the same way: the header says which step
# this is, the body is just the model's words, printed in full.
render_block_text() {
  [[ -n "${F[text]}" ]] || return 0
  render_header
  render_indent "${F[text]}"
}

# A tool call: the command line, whatever it printed, and whether it worked.
# opencode reports a non-zero command as a "completed" call carrying an exit
# code, so the exit status decides the verdict, not state.status alone.
render_block_tool() {
  local label status code
  label="${F[title]}"
  [[ -n "${label}" ]] || label="${F[command]}"
  [[ -n "${label}" ]] || label="${F[tool]}"
  [[ -n "${label}" ]] || label="tool"
  status="${F[status]}"
  code="${F[exit]}"
  case "${code}" in
    ''|*[!0-9]*) code="" ;;
  esac
  render_header
  printf '$ %s\n' "${label}"
  if [[ -n "${F[output]}" || -n "${F[toolerror]}" ]]; then
    # Whatever the command printed, then the reason it failed if it did. Blank
    # lines on both sides keep the result from melting into the verdict.
    printf '\n'
    [[ -n "${F[output]}" ]] && render_indent "${F[output]}"
    [[ -n "${F[toolerror]}" ]] && render_indent "ERROR: ${F[toolerror]}"
    printf '\n'
  fi
  if [[ "${status}" == "error" ]] || { [[ -n "${code}" ]] && [[ "${code}" != "0" ]]; }; then
    if [[ -n "${code}" ]]; then
      printf '❌️ %s (exit %s)\n' "${label}" "${code}"
    else
      printf '❌️ %s\n' "${label}"
    fi
  else
    printf '✅ %s\n' "${label}"
  fi
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
  # Same part id and identical content again: a replay (resumed session /
  # reconnected event stream), so print it once. Same id with *changed*
  # content still renders, the log must never drop a real update.
  local pid="${F[id]}"
  if [[ -n "${pid}" ]]; then
    local fp="${F[type]}|${F[status]}|${F[title]}|${F[command]}|${F[output]}|${F[exit]}|${F[toolerror]}|${F[errmsg]}|${F[errname]}|${F[text]}"
    if [[ "${SEEN_PARTS[${pid}]:-}" == "${fp}" ]]; then
      return 0
    fi
    SEEN_PARTS[${pid}]="${fp}"
  fi
  case "${F[type]}" in
    text | reasoning) render_block_text ;;
    tool_use) render_block_tool ;;
    error) render_block_error ;;
    *)
      # step_start / step_finish and anything new: bookkeeping, not content.
      ;;
  esac
}

while IFS= read -r render_line || [[ -n "${render_line}" ]]; do
  render_event "${render_line}"
done