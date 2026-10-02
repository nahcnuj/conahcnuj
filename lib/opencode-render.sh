#!/usr/bin/env bash
# opencode-render - turn the raw `opencode run --format json` event stream into
# a console log a human can read.
#
# Usage:
#   bash lib/opencode-render.sh [--model provider/model] [--repo owner/repo]
#                              [--dir <work tree>] < events.jsonl > log
#
# opencode writes one JSON event per line. Dumped raw into a CI log it says
# nothing about what happened, so every content-bearing event (assistant text,
# reasoning, a tool call, a session error) becomes a block introduced by a
# single context header:
#
#   Space Bunny (medium)@nahcnuj/conahcnuj:.  1a2b3c4 [feature/x] +12/-3 +2 new
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
# events are dropped, and lines that are not JSON (opencode's own --print-logs
# output lands on stdout too) pass through verbatim.
#
# Overridable: CONAHCNUJ_RENDER_MAX_LINES (per-block line cap, default 400),
# CONAHCNUJ_RENDER_MAX_COLS (per-line column cap, default 400). Truncation is
# always announced in place so nothing disappears silently.

set -uo pipefail

MAX_LINES="${CONAHCNUJ_RENDER_MAX_LINES:-400}"
MAX_COLS="${CONAHCNUJ_RENDER_MAX_COLS:-400}"
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
function field(s, key, start,  re, i, e, off) {
  # start (1-based) lets a caller skip an object it has already read, so a key
  # nested inside that object can never shadow the real one.
  off = start ? start - 1 : 0
  re = "\"" key "\"[ \t]*:[ \t]*"
  if (!match(substr(s, off + 1), re)) return ""
  i = off + RSTART + RLENGTH
  e = val_end(s, i)
  return substr(s, i, e - i + 1)
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
  # Everything the serializer writes after "input" (output / metadata / title /
  # error) is looked up from there on, never inside the tool's own arguments.
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
}
AWK

# Per-event field bag, filled by render_fields. Every key is pre-created so a
# missing field reads as empty under `set -u`, and a separate SEEN set tells an
# absent field apart from one whose first line is blank.
declare -A F=(
  [type]="" [tool]="" [status]="" [title]="" [command]=""
  [output]="" [exit]="" [toolerror]="" [errmsg]="" [errname]="" [text]=""
)
declare -A SEEN=()

render_fields() {
  local tag value nl=$'\n'
  local -a keys=(
    type tool status title command output exit toolerror errmsg errname text
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

# --- context line -----------------------------------------------------------

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
render_dir() {
  local top here
  top="$(git -C "${DIR}" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "${top}" ]]; then
    printf '%s' "${DIR}"
    return 0
  fi
  here="$(cd "${DIR}" 2>/dev/null && pwd -P || printf '%s' "${DIR}")"
  top="$(cd "${top}" 2>/dev/null && pwd -P || printf '%s' "${top}")"
  if [[ "${here}" == "${top}" ]]; then
    printf '.'
  elif [[ "${here}" == "${top}"/* ]]; then
    printf '%s' "${here#"${top}"/}"
  else
    printf '%s' "${DIR}"
  fi
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
  local add del stat=""
  local adds=0 dels=0
  while IFS=$'\t' read -r add del _; do
    [[ "${add}" =~ ^[0-9]+$ ]] || add=0
    [[ "${del}" =~ ^[0-9]+$ ]] || del=0
    adds=$((adds + add))
    dels=$((dels + del))
  done < <(git -C "${DIR}" diff --numstat HEAD 2>/dev/null || true)
  stat="+${adds}/-${dels}"
  local new
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

# Print text indented under its block, capped so one runaway payload cannot
# bury the log. Both caps announce what was dropped.
render_indent() {
  local -a lines=()
  local line total limit i
  [[ -n "${1:-}" ]] || return 0
  mapfile -t lines <<< "${1}"
  total="${#lines[@]}"
  limit="${MAX_LINES}"
  [[ "${limit}" -le "${total}" ]] || limit="${total}"
  for ((i = 0; i < limit; i++)); do
    line="${lines[i]}"
    if [[ "${#line}" -gt "${MAX_COLS}" ]]; then
      printf '%s%s ...[+%s cols]\n' "${INDENT}" "${line:0:MAX_COLS}" "$(( ${#line} - MAX_COLS ))"
    else
      printf '%s%s\n' "${INDENT}" "${line}"
    fi
  done
  if [[ "${total}" -gt "${limit}" ]]; then
    printf '%s... (%s more lines truncated)\n' "${INDENT}" "$(( total - limit ))"
  fi
}

# Assistant text and reasoning read the same way: the header says which step
# this is, the body is just the model's words.
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
    if [[ -n "${F[output]}" ]]; then
      render_indent "${F[output]}"
    fi
    if [[ -n "${F[toolerror]}" ]]; then
      render_indent "ERROR: ${F[toolerror]}"
    fi
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
      # Not JSON: opencode's own --print-logs output shares stdout.
      printf '%s\n' "${line}"
      return 0
      ;;
  esac
  render_fields "${line}"
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
