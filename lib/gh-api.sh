#!/usr/bin/env bash
# GitHub API helpers for conahcnuj
#
# Functions talk to the GitHub REST / GraphQL APIs using the GitHub App
# installation token (gh-app/get-token.sh). Output follows one convention:
# a single line of pipe-separated fields. Fields that may contain newlines,
# quotes or control characters (titles, bodies, comments, labels, review
# feedback, raw payloads) are base64 encoded and carry a `_b64` suffix;
# decode with gh_api_unb64().
#
# Offline tests: set GH_API_TEST_MODE=1. Every function then reads exactly
# one mocked response line from stdin and performs no network I/O. The
# caller supplies one JSON document per API call, in call order.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_APP_DIR="${GH_APP_DIR:-${HERE}/../gh-app}"

# shellcheck source=lib/rate-limit.sh
. "${HERE}/../lib/rate-limit.sh"

# Accept the value either as $1 or on stdin (so both `gh_api_unb64 "$x"` and
# `printf '%s' "$x" | gh_api_unb64` work under `shopt -u nounset`-safe use).
gh_api_b64() {
  if [[ $# -ge 1 ]]; then
    printf '%s' "${1}" | base64 | tr -d '\n'
  else
    base64 | tr -d '\n'
  fi
}
gh_api_unb64() {
  if [[ $# -ge 1 ]]; then
    printf '%s' "${1}" | base64 -d 2>/dev/null || true
  else
    base64 -d 2>/dev/null || true
  fi
}

# Unescape literal escape sequences (\\n, \\t, \\r, \\") in a string.
# GitHub API returns issue/PR bodies with literal \n in JSON strings.
gh_api_unescape() {
  local s="${1}"
  # Replace literal \n with actual newline, \t with tab, \\ with \, \" with "
  s="${s//\\n/$'\n'}"
  s="${s//\\t/$'\t'}"
  s="${s//\\r/$'\r'}"
  s="${s//\\\\/\\}"
  s="${s//\\\"/\"}"
  printf '%s' "${s}"
}

# JSON-escape a string for embedding inside a GraphQL query string or a JSON
# body. Escapes backslashes and quotes; converts literal line breaks into \n
# sequences (raw newlines are invalid inside GraphQL string literals, and
# multi-line title/body/comment text is the norm). Every other control byte
# (tab, CR, ESC, BEL, ...) becomes a \u00XX escape, DEL included for the same
# reason: a raw control byte inside a JSON string makes GitHub refuse the whole
# request with 400 "Problems parsing JSON" and the caller loses the call. Such
# bytes do reach this function - the bug report body is the tail of the run
# log, and the renderer decodes opencode's \t / \r escapes into real tab and
# carriage-return bytes before printing them (issue #156: the bug report for
# #155 was rejected on exactly that, so the report itself was lost).
gh_api_escape() {
  printf '%s' "${1}" |
    sed 's/\\/\\\\/g; s/"/\\"/g' |
    awk '
      BEGIN {
        for (i = 1; i < 32; i++) ctl[sprintf("%c", i)] = i
        ctl[sprintf("%c", 127)] = 127
      }
      NR > 1 { printf "\\n" }
      {
        n = length($0)
        for (i = 1; i <= n; i++) {
          c = substr($0, i, 1)
          if (c in ctl) printf "\\u%04x", ctl[c]
          else printf "%s", c
        }
      }'
}

# Read a single line from stdin (used by every test-mode function so that a
# caller can "feed a tape" of one JSON response per API call).
gh_api_read_line() {
  local line=""
  IFS= read -r line || true
  printf '%s\n' "${line}"
}

# App installation token. Test mode returns a dummy without any network I/O.
gh_api_get_token() {
  if [[ "${GH_API_TEST_MODE:-0}" == "1" ]]; then
    printf '%s\n' "test-token"
    return 0
  fi
  bash "${GH_APP_DIR}/get-token.sh"
}

# The HTTP status of a response curl recorded with -D. curl writes one header
# block per response, so the answer is the LAST status line in the dump: reading
# only the first line mistakes a proxy's "HTTP/1.1 200 Connection established"
# (or any informational 1xx block) for the response itself and silently turns a
# real API answer into the wrong verdict. Prints nothing when there is none.
gh_api_http_status() {
  tr -d '\r' < "${1}" 2>/dev/null |
    sed -n 's#^HTTP/[0-9.]* \([0-9][0-9][0-9]\).*$#\1#p' |
    tail -n 1
}

# HTTP layer. Args: method url [request-body]
# Real mode: performs the call; on 403/429 waits for the rate limit using
# Retry-After / X-RateLimit-Reset headers and retries (max 5 tries).
# Test mode: echoes the single stdin "response" line unchanged.
# A call that ends up without a 2xx says so on stderr: callers routinely throw
# this function's stdout away and the response body is the only place GitHub
# states why, so a failure that reached nothing but the exit status would leave
# a bug report with no clue at all (issue #134).
gh_api_call() {
  local method="${1:-GET}"
  local url="${2}"
  local data="${3:-}"

  if [[ "${GH_API_TEST_MODE:-0}" == "1" ]]; then
    gh_api_read_line
    return 0
  fi

  local token headers body code attempt curl_status detail
  token="$(gh_api_get_token)"
  headers="$(mktemp)"
  body="$(mktemp)"
  # The payload goes to a file and is sent with --data-binary. Passing it as
  # `-d "${data}"` routes it through the command-line argument encoding, which
  # on Windows Git Bash converts non-ASCII bytes (UTF-8) to the system codepage
  # and corrupts them, making GitHub reject the request ("Problems parsing
  # JSON"). Reading from a file keeps the bytes intact on every platform.
  local datafile=""
  if [[ -n "${data}" ]]; then
    datafile="$(mktemp)"
    printf '%s' "${data}" > "${datafile}"
  fi
  attempt=0
  while [[ ${attempt} -lt 5 ]]; do
    attempt=$((attempt + 1))
    curl_status=0
    local -a args=(
      -sS -D "${headers}" -o "${body}" -X "${method}"
      -H "Authorization: Bearer ${token}"
      -H "Accept: application/vnd.github+json"
    )
    if [[ -n "${data}" ]]; then
      args+=(-H "Content-Type: application/json" --data-binary "@${datafile}")
    fi
    curl "${args[@]}" "${url}" || curl_status=$?
    code="$(gh_api_http_status "${headers}")"
    if [[ "${code}" == "403" || "${code}" == "429" ]]; then
      rate_limit_wait "$(tr -d '\r' < "${headers}")"
      continue
    fi
    break
  done
  GH_API_LAST_HTTP_CODE="${code}"
  rm -f "${headers}" "${datafile}"
  if [[ "${code}" != "200" && "${code}" != "201" ]]; then
    detail="${code:-no response}"
    if [[ "${curl_status}" -ne 0 ]]; then
      detail="${detail}, curl exit ${curl_status}"
    fi
    echo "ERROR: ${method} ${url} -> ${detail}: $(head -c 300 "${body}" | tr -d '\r\n')" >&2
  fi
  cat "${body}"
  rm -f "${body}"
  case "${code}" in
    200|201) return 0 ;;
    *) return 1 ;;
  esac
}

gh_api_graphql() {
  local query="${1}"
  shift
  local -a var_keys=() var_vals=()
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      -F)
        var_keys+=("${2%%=*}")
        var_vals+=("${2#*=}")
        shift 2
        ;;
      *) break ;;
    esac
  done
  local vars_json="{}"
  if [[ ${#var_keys[@]} -gt 0 ]]; then
    local parts=()
    local i
    for i in "${!var_keys[@]}"; do
      parts+=("$(printf '"%s":"%s"' "${var_keys[i]}" "${var_vals[i]}")")
    done
    local IFS=,
    vars_json="{${parts[*]}}"
  fi
  local payload
  payload="$(printf '{"query":"%s","variables":%s}' "$(gh_api_escape "${query}")" "${vars_json}")"
  local json http_code
  json="$(gh_api_call POST "${GH_APP_API_BASE:-https://api.github.com}/graphql" "${payload}")"
  http_code="${GH_API_LAST_HTTP_CODE:-}"
  # Check for HTTP-level errors (401, 403, etc.) that gh_api_call doesn't retry
  if [[ -n "${http_code}" && "${http_code}" != "200" ]]; then
    echo "GraphQL HTTP error ${http_code}: ${json}" >&2
    return 1
  fi
  # Check for GraphQL errors (returned with HTTP 200 but have errors field)
  local errors
  errors="$(printf '%s' "${json}" | sed -n 's/.*"errors"[[:space:]]*:[[:space:]]*\(\[[^]]*\]\).*/\1/p')"
  if [[ -n "${errors}" && "${errors}" != "[]" ]]; then
    echo "GraphQL error: ${errors}" >&2
    return 1
  fi
  # Check for GitHub API error responses (e.g., {"message":"Bad credentials"})
  local message
  message="$(printf '%s' "${json}" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  if [[ -n "${message}" ]]; then
    echo "GitHub API error: ${message}" >&2
    return 1
  fi
  printf '%s\n' "${json}"
}

# --- JSON field extraction (single-line, compact JSON best) ----------------

# String field value. Also handles unquoted values (bool, null, number, enum).
gh_api_json_str() {
  local json="${1}" key="${2}"
  local val
  # Try quoted string first
  val="$(printf '%s' "${json}" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1)"
  if [[ -n "${val}" ]]; then
    printf '%s\n' "${val}"
    return 0
  fi
  # Try unquoted value (bool, null, number, bare enum)
  val="$(printf '%s' "${json}" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\([^,}]*\).*/\1/p" | head -1)"
  # Trim whitespace
  val="$(printf '%s' "${val}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  printf '%s\n' "${val}"
}

# Numeric field value.
gh_api_json_num() {
  local json="${1}" key="${2}"
  printf '%s' "${json}" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" | head -1
}

# --- Issues / PRs -----------------------------------------------------------

# Fetch an issue (PRs are issues too). Output: title_b64|body_b64|labels_b64|is_pr
gh_api_fetch_issue() {
  local owner="${1}" repo="${2}" number="${3}" json
  if [[ "${GH_API_TEST_MODE:-0}" == "1" ]]; then
    json="$(gh_api_read_line)"
  else
    json="$(gh_api_call GET "https://api.github.com/repos/${owner}/${repo}/issues/${number}")"
  fi

  local title body labels is_pr="false"
  title="$(gh_api_json_str "${json}" "title")"
  body="$(gh_api_json_str "${json}" "body")"
  labels="$(printf '%s' "${json}" | sed -n 's/.*"labels"[[:space:]]*:[[:space:]]*\(\[[^]]*\]\).*/\1/p')"
  if printf '%s' "${json}" | grep -q '"pull_request"'; then
    is_pr="true"
  fi

  printf '%s|%s|%s|%s\n' "$(gh_api_b64 "${title}")" "$(gh_api_b64 "${body}")" "$(gh_api_b64 "${labels}")" "${is_pr}"
}

# Repo default branch info. Output: default_branch|default_oid
gh_api_get_repo() {
  local owner="${1}" repo="${2}" json
  local query="query(\$owner: String!, \$repo: String!) { repository(owner: \$owner, name: \$repo) { defaultBranchRef { name, target { oid } } } }"
  if [[ "${GH_API_TEST_MODE:-0}" == "1" ]]; then
    json="$(gh_api_read_line)"
  else
    json="$(gh_api_graphql "${query}" -F owner="${owner}" -F repo="${repo}")"
  fi

  local branch oid
  branch="$(gh_api_json_str "${json}" "name")"
  oid="$(gh_api_json_str "${json}" "oid")"
  printf '%s|%s\n' "${branch}" "${oid}"
}

# PR state summary for resume.
# Output: number|state|title_b64|body_b64|isDraft|mergeable|mergeStateStatus|reviewDecision|head|base|headRefOid|linkedIssue
gh_api_fetch_pr_state() {
  local owner="${1}" repo="${2}" number="${3}" json
  local query="query { repository(owner: \"${owner}\", name: \"${repo}\") { pullRequest(number: ${number}) { number, state, title, body, isDraft, mergeable, mergeStateStatus, reviewDecision, headRefName, baseRefName, headRefOid, closingIssuesReferences(first: 5) { nodes { number } } } } }"
  if [[ "${GH_API_TEST_MODE:-0}" == "1" ]]; then
    json="$(gh_api_read_line)"
  else
    json="$(gh_api_graphql "${query}")"
  fi

  local state title body is_draft mergeable mss decision head base head_oid linked
  state="$(gh_api_json_str "${json}" "state")"
  title="$(gh_api_json_str "${json}" "title")"
  body="$(gh_api_json_str "${json}" "body")"
  is_draft="$(printf '%s' "${json}" | sed -n 's/.*"isDraft"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p' | head -1)"
  mergeable="$(gh_api_json_str "${json}" "mergeable")"
  mss="$(gh_api_json_str "${json}" "mergeStateStatus")"
  decision="$(gh_api_json_str "${json}" "reviewDecision")"
  head="$(gh_api_json_str "${json}" "headRefName")"
  base="$(gh_api_json_str "${json}" "baseRefName")"
  head_oid="$(gh_api_json_str "${json}" "headRefOid")"
  # Only count numbers inside closingIssuesReferences' nodes, never the PR itself.
  local refs_part
  refs_part="$(printf '%s' "${json}" | sed -n 's/.*"closingIssuesReferences".*"nodes":[[:space:]]*\(\[[^]]*\]\).*/\1/p')"
  linked="$(gh_api_json_num "${refs_part}" "number")"

  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "${number}" "${state}" "$(gh_api_b64 "${title}")" "$(gh_api_b64 "${body}")" \
    "${is_draft}" "${mergeable}" "${mss}" "${decision}" "${head}" "${base}" "${head_oid}" "${linked}"
}

# Workflows whose checks the driver must not treat as a constraint. Both of
# them attach a check run to the PR head commit while they are still running,
# and neither can finish while this driver run is alive:
#   - "Issue auto-drive" is the driver's own run: counting it makes the driver
#     wait for itself before it can do anything.
#   - "Owner-approved auto-merge" merges the PR only once every other check on
#     the approved head commit is green - this driver's run included - so
#     counting it here deadlocks the two against each other. Neither check can
#     ever pass, the driver burns its whole time budget in poll_conditions and
#     the merge job fails on its own check timeout (issue #115). Each side
#     waits for CI only: the merge job skips the driver by workflow name the
#     same way the driver skips the merge job here.
# A run a maintainer cancelled (or that timed out) also stays on the head commit
# as a failure no code change can ever fix, so both are left out of the
# aggregate entirely. Comma separated; empty disables the filter.
# `-` (not `:-`) so an explicitly empty value really disables the filter: the
# caller has to be able to turn it off from the environment alone.
CONAHCNUJ_OWN_WORKFLOWS="${CONAHCNUJ_OWN_WORKFLOWS-Issue auto-drive,Owner-approved auto-merge}"

# Aggregate a statusCheckRollup payload (stdin) into SUCCESS / PENDING /
# FAILURE, leaving out the checks that belong to the workflows named in $1.
# Precedence follows GitHub's own rollup: a failing check beats a pending one,
# and NEUTRAL / SKIPPED count as success.
# A payload that carries no context list (an older response, or one that could
# not be enumerated) cannot be filtered, so its own aggregate "state" is trusted
# as-is; an empty result means "no checks at all", which the caller reads as
# SUCCESS.
gh_api_rollup_state() {
  local skip="${1:-}" json contexts node type state status conclusion workflow result="" pending="false"

  json="$(gh_api_read_line)"
  if [[ "${json}" != *'"contexts"'* ]]; then
    gh_api_json_str "${json}" "state"
    return 0
  fi
  # More contexts than one page holds: the aggregate would be computed from an
  # incomplete list, so trust the rollup's own state instead of guessing.
  if printf '%s' "${json}" | grep -q '"contexts":{"nodes":\[.*\],"pageInfo":{"hasNextPage":true}'; then
    gh_api_json_str "${json}" "state"
    return 0
  fi
  # Every context is a flat object, so the only "},{" inside the array separates
  # two of them: splitting there yields one context per line.
  contexts="$(printf '%s' "${json}" | sed -n 's/.*"contexts":{"nodes":[[:space:]]*\(\[[^]]*\]\).*/\1/p')"
  while IFS= read -r node; do
    [[ -n "${node}" ]] || continue
    type="$(gh_api_json_str "${node}" "__typename")"
    case "${type}" in
      StatusContext)
        state="$(gh_api_json_str "${node}" "state")"
        case "${state}" in
          SUCCESS) ;;
          PENDING|EXPECTED) pending="true" ;;
          "") pending="true" ;;
          *) result="FAILURE" ;;
        esac
        ;;
      CheckRun)
        # A check run that belongs to one of the skipped workflows is left out of
        # the aggregate entirely: neither its pending nor its failed state may
        # gate the run that is doing the polling.
        workflow="$(printf '%s' "${node}" | sed -n 's/.*"workflow":{"name":"\([^"]*\)".*/\1/p')"
        if [[ -n "${workflow}" && ",${skip}," == *",${workflow},"* ]]; then
          continue
        fi
        status="$(gh_api_json_str "${node}" "status")"
        if [[ "${status}" != "COMPLETED" ]]; then
          pending="true"
          continue
        fi
        conclusion="$(gh_api_json_str "${node}" "conclusion")"
        case "${conclusion}" in
          SUCCESS|NEUTRAL|SKIPPED) ;;
          "") pending="true" ;;
          null) pending="true" ;;
          *) result="FAILURE" ;;
        esac
        ;;
      *)
        # Not a member we know how to read: wait rather than call it green.
        pending="true"
        ;;
    esac
  done < <(printf '%s\n' "${contexts}" | sed 's/},{/}\n{/g')

  if [[ "${result}" == "FAILURE" ]]; then
    printf '%s\n' "FAILURE"
  elif [[ "${pending}" == "true" ]]; then
    printf '%s\n' "PENDING"
  else
    printf '%s\n' "SUCCESS"
  fi
}

# Non-reviewer merge constraints. Output: checks_state|mergeable|mergeStateStatus|state
# checks_state is SUCCESS when there is no status check on the head commit, and
# the checks of the workflows in CONAHCNUJ_OWN_WORKFLOWS (the driver's own run
# and the merge job that waits for it) never count against the run that is
# polling. state is the PR state, so the caller can tell "still open" from
# "merged/closed while we waited"; it is empty when the payload does not carry
# it, which the caller reads as unknown (keep polling).
gh_api_fetch_pr_conditions() {
  local owner="${1}" repo="${2}" number="${3}" json
  local query="query { repository(owner: \"${owner}\", name: \"${repo}\") { pullRequest(number: ${number}) { mergeable, mergeStateStatus, state, commits(last: 1) { nodes { commit { statusCheckRollup { state, contexts(first: 100) { nodes { __typename, ... on CheckRun { name, status, conclusion, checkSuite { workflowRun { workflow { name } } } }, ... on StatusContext { context, state } }, pageInfo { hasNextPage } } } } } } } } }"
  if [[ "${GH_API_TEST_MODE:-0}" == "1" ]]; then
    json="$(gh_api_read_line)"
  else
    json="$(gh_api_graphql "${query}")"
  fi

  local state mergeable mss pr_state
  state="$(printf '%s' "${json}" | gh_api_rollup_state "${CONAHCNUJ_OWN_WORKFLOWS}")"
  if [[ -z "${state}" ]]; then
    state="SUCCESS"
  fi
  mergeable="$(gh_api_json_str "${json}" "mergeable")"
  mss="$(gh_api_json_str "${json}" "mergeStateStatus")"
  # The PR's own state, anchored to the field right after mergeStateStatus:
  # statusCheckRollup has a "state" of its own and a bare key match would pick
  # up that aggregate instead (fields come back in query order).
  pr_state="$(printf '%s' "${json}" | sed -n 's/.*"mergeStateStatus"[[:space:]]*:[[:space:]]*"[^"]*",[[:space:]]*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  printf '%s|%s|%s|%s\n' "${state}" "${mergeable}" "${mss}" "${pr_state}"
}

# Review status + raw payload.
# Output: decision|payload_b64  (payload = raw GraphQL response; feed it to
# gh_api_review_summary to turn it into readable feedback text).
gh_api_fetch_reviews() {
  local owner="${1}" repo="${2}" number="${3}" json
  local query="query { repository(owner: \"${owner}\", name: \"${repo}\") { pullRequest(number: ${number}) { reviewDecision, reviews(last: 25) { nodes { state, body, author { login } } }, comments(last: 25) { nodes { body, author { login } } }, reviewThreads(first: 50) { nodes { isResolved, comments(first: 10) { nodes { databaseId, body, author { login } } } } } } } }"
  if [[ "${GH_API_TEST_MODE:-0}" == "1" ]]; then
    json="$(gh_api_read_line)"
  else
    json="$(gh_api_graphql "${query}")"
  fi

  local decision
  decision="$(gh_api_json_str "${json}" "reviewDecision")"
  printf '%s|%s\n' "${decision}" "$(gh_api_b64 "${json}")"
}

# Turn a raw reviews GraphQL payload (stdin) into readable feedback text.
gh_api_review_summary() {
  local json decision
  json="$(gh_api_read_line)"

  decision="$(gh_api_json_str "${json}" "reviewDecision")"
  printf 'reviewDecision: %s\n' "${decision:-NONE}"

  # Reviews (nodes look like {"state":"...","body":"...","author":{"login":"..."}}).
  local reviews_part
  reviews_part="$(printf '%s' "${json}" | sed 's/"reviewThreads":.*//' | sed 's/"comments":.*//')"
  local rn
  if printf '%s' "${reviews_part}" | grep -qE '\{"state":"[^"]*","body":"[^"]*"'; then
    echo "REVIEWS:"
  fi
  while IFS= read -r rn; do
    [[ -z "${rn}" ]] && continue
    local st bd au
    st="$(gh_api_json_str "${rn}" "state")"
    bd="$(gh_api_json_str "${rn}" "body")"
    au="$(gh_api_json_str "${rn}" "login")"
    [[ -z "${bd}" ]] && bd="(no body)"
    printf -- '- [review %s] %s: %s\n' "${st}" "${au}" "${bd}"
  done < <(printf '%s' "${reviews_part}" | grep -oE '\{"state":"[^"]*","body":"[^"]*","author":\{"login":"[^"]*"\}' || true)

  # Issue-level comments.
  local comments_part comment_matches bn
  comments_part="$(printf '%s' "${json}" | sed 's/"reviewThreads":.*//' | sed -n 's/.*"comments":{"nodes":\(\[[^]]*\]\).*/\1/p')"
  comment_matches="$(printf '%s' "${comments_part}" | grep -oE '"body":"[^"]*"' | grep -v '"body":"<!-- conahcnuj-continuation -->' || true)"
  if [[ -n "${comment_matches}" ]]; then
    echo "COMMENTS:"
  fi
  while IFS= read -r bn; do
    [[ -z "${bn}" ]] && continue
    local bd
    bd="$(gh_api_json_str "${bn}" "body")"
    [[ -n "${bd}" ]] || bd="(no body)"
    printf -- '- %s\n' "${bd}"
  done < <(printf '%s\n' "${comment_matches}")

  # Inline review threads: skip resolved ones, quote unresolved feedback.
  local threads_part
  threads_part="$(printf '%s' "${json}" | sed -n 's/.*"reviewThreads":{"nodes":\(.*\)/\1/p')"
  if echo "${threads_part}" | grep -q '"isResolved":false'; then
    echo "REVIEW THREADS (unresolved):"
  fi
  gh_api_format_unresolved_threads "${json}"
}

# Unresolved inline review threads from a raw reviews payload (stdin).
# Output: one "- [comment <id> by <author>] <body>" line per comment of an
# unresolved thread, nothing when every thread is resolved (or there are none).
# The comment id is what a reply is posted against (the agent answers the
# reviewer in-thread; see the feedback round in bin/conahcnuj.sh), so the
# summary names it. Split out so the initial context of a run can quote the
# feedback that is still open without dragging the rest of the review state
# along; collect_initial_context in bin/conahcnuj.sh is the caller.
gh_api_unresolved_threads() {
  local json
  json="$(gh_api_read_line)"
  gh_api_format_unresolved_threads "${json}"
}

# Shared formatter for the two callers above: walk each unresolved thread and
# print every comment with the numeric id a reply would target. Comments that
# carry no id (an older/parsed-down payload) still print their body.
gh_api_format_unresolved_threads() {
  local json="${1}" threads_part tn
  threads_part="$(printf '%s' "${json}" | sed -n 's/.*"reviewThreads":{"nodes":\(.*\)/\1/p')"
  while IFS= read -r tn; do
    [[ -z "${tn}" ]] && continue
    local cn cid ca cb printed="false"
    while IFS= read -r cn; do
      [[ -z "${cn}" ]] && continue
      cid="$(gh_api_json_num "${cn}" "databaseId")"
      ca="$(gh_api_json_str "${cn}" "login")"
      cb="$(gh_api_json_str "${cn}" "body")"
      [[ -n "${cb}" ]] || cb="(no body)"
      printed="true"
      if [[ -n "${cid}" ]]; then
        printf -- '- [comment %s by %s] %s\n' "${cid}" "${ca:-unknown}" "${cb}"
      else
        printf -- '- %s\n' "${cb}"
      fi
    done < <(printf '%s' "${tn}" | grep -oE '\{"databaseId":[0-9]+,"body":"[^"]*","author":\{"login":"[^"]*"\}' || true)
    if [[ "${printed}" != "true" ]]; then
      local bn
      while IFS= read -r bn; do
        [[ -z "${bn}" ]] && continue
        printf -- '- %s\n' "${bn}"
      done < <(printf '%s' "${tn}" | grep -oE '"body":"[^"]*"' | sed 's/"body":"//; s/"$//' || true)
    fi
  done < <(printf '%s' "${threads_part}" | grep -oE '\{"isResolved":false,"comments":\{"nodes":\[[^]]*\]' || true)
}

# Fingerprint of the actionable review feedback in a raw reviews payload.
# Returns empty when there is no reviewer feedback to act on, so a poll of the
# initial "waiting for review" state (reviewDecision=REVIEW_REQUIRED or empty,
# no reviews/comments/threads) is never mistaken for fresh feedback.
# Comments carry their author, so the bot's own replies are dropped before the
# hash: they are review comments too, and counting them would let a reply look
# like fresh reviewer feedback (the driver would answer its own answer forever).
gh_api_review_fingerprint() {
  local raw="${1}" matches="" decision=""
  matches="$(printf '%s' "${raw}" | grep -oE '\{"state":"[^"]*","body":"[^"]*","author":\{"login":"[^"]*"\}|\{"databaseId":[0-9]+,"body":"[^"]*","author":\{"login":"[^"]*"\}|\{"body":"[^"]*","author":\{"login":"[^"]*"\}|\{"body":"[^"]*"|"isResolved":(true|false)' | grep -v '\[bot\]' | grep -v '"body":"<!-- conahcnuj-continuation -->' || true)"
  if [[ -z "${matches}" ]]; then
    # Only a decision that means "do work now" counts as feedback on its own;
    # REVIEW_REQUIRED / empty just mean "waiting for reviewers".
    decision="$(gh_api_json_str "${raw}" "reviewDecision")"
    if [[ "${decision}" != "CHANGES_REQUESTED" && "${decision}" != "COMMENTED" ]]; then
      printf '%s\n' ""
      return 0
    fi
  fi
  printf '%s%s' "${matches}" "${decision}" | sort -u | cksum | cut -d' ' -f1
}

# Find the open PR whose head is <branch>. Output: PR number (empty if none).
gh_api_find_pr_by_head() {
  local owner="${1}" repo="${2}" branch="${3}" json
  local query="query(\$owner: String!, \$repo: String!, \$branch: String!) { repository(owner: \$owner, name: \$repo) { pullRequests(headRefName: \$branch, states: [OPEN], first: 1) { nodes { number } } } }"
  if [[ "${GH_API_TEST_MODE:-0}" == "1" ]]; then
    json="$(gh_api_read_line)"
  else
    json="$(gh_api_graphql "${query}" -F owner="${owner}" -F repo="${repo}" -F branch="${branch}")"
  fi
  gh_api_json_num "${json}" "number"
}

# Find any PR (open/closed/merged) whose head is <branch>.
# Output: "<number>|<state>" (empty if none). Used to avoid head-branch collisions.
gh_api_find_pr_by_head_any() {
  local owner="${1}" repo="${2}" branch="${3}" json
  local query="query(\$owner: String!, \$repo: String!, \$branch: String!) { repository(owner: \$owner, name: \$repo) { pullRequests(headRefName: \$branch, first: 10) { nodes { number state } } } }"
  if [[ "${GH_API_TEST_MODE:-0}" == "1" ]]; then
    json="$(gh_api_read_line)"
  else
    json="$(gh_api_graphql "${query}" -F owner="${owner}" -F repo="${repo}" -F branch="${branch}")"
  fi
  local num state
  num="$(gh_api_json_num "${json}" "number")"
  state="$(gh_api_json_str "${json}" "state")"
  if [[ -n "${num}" && -n "${state}" ]]; then
    printf '%s|%s\n' "${num}" "${state}"
  fi
}

# Create a branch ref from a base OID. Args: owner repo branch base_oid
gh_api_create_branch() {
  local owner="${1}" repo="${2}" branch="${3}" base_oid="${4}"
  local body
  body="{\"ref\":\"refs/heads/${branch}\",\"sha\":\"${base_oid}\"}"
  gh_api_call POST "https://api.github.com/repos/${owner}/${repo}/git/refs" "${body}"
}

# Create a PR. Output: PR number. Args: owner repo title body head base
# The createPullRequest mutation requires the repository node id (it rejects
# repositoryNameWithOwner), so this first resolves the id with one extra
# GraphQL query. In test mode that consumes one extra mock line.
gh_api_create_pr() {
  local owner="${1}" repo="${2}" title="${3}" body="${4}" head="${5}" base="${6}"

  local id_query="query(\$owner: String!, \$repo: String!) { repository(owner: \$owner, name: \$repo) { id } }"
  local id_json
  if [[ "${GH_API_TEST_MODE:-0}" == "1" ]]; then
    id_json="$(gh_api_read_line)"
  else
    id_json="$(gh_api_graphql "${id_query}" -F owner="${owner}" -F repo="${repo}")"
  fi
  local repo_id
  repo_id="$(gh_api_json_str "${id_json}" "id")"
  if [[ -z "${repo_id}" ]]; then
    echo "ERROR: could not resolve the repository id for ${owner}/${repo}." >&2
    return 1
  fi

  local query
  query="mutation { createPullRequest(input: { repositoryId: \"${repo_id}\", headRefName: \"$(gh_api_escape "${head}")\", baseRefName: \"$(gh_api_escape "${base}")\", title: \"$(gh_api_escape "${title}")\", body: \"$(gh_api_escape "${body}")\" }) { pullRequest { number } } }"

  local json
  if [[ "${GH_API_TEST_MODE:-0}" == "1" ]]; then
    json="$(gh_api_read_line)"
  else
    json="$(gh_api_graphql "${query}")"
  fi
  gh_api_json_num "${json}" "number"
}

# Update a PR's body so it stays in sync with the linked issue. Args: owner repo pr body
# (Discards the updated PR JSON; the response must not leak into the caller's stdout.)
gh_api_update_pr() {
  local owner="${1}" repo="${2}" number="${3}" body="${4}"
  local payload
  payload="{\"body\":\"$(gh_api_escape "${body}")\"}"
  gh_api_call PATCH "https://api.github.com/repos/${owner}/${repo}/pulls/${number}" "${payload}" >/dev/null
}

# Request review on a PR. Args: owner repo pr [reviewer]
# A named reviewer assigns the request to that account; omitting it asks for
# review without naming anyone.
gh_api_request_review() {
  local owner="${1}" repo="${2}" number="${3}" reviewer="${4:-}"
  local body
  if [[ -n "${reviewer}" ]]; then
    body="{\"reviewers\":[\"$(gh_api_escape "${reviewer}")\"]}"
  else
    body='{"reviewers":[]}'
  fi
  gh_api_call POST "https://api.github.com/repos/${owner}/${repo}/pulls/${number}/requested_reviewers" "${body}"
}

# The reviewers GitHub currently has requested on a PR, one per line (nothing
# when nobody is asked; a team slug is written "team:<slug>"). Non-zero exit when
# the PR could not be read at all, so the caller can tell "GitHub says nobody is
# asked" from "I could not look" — only the first is proof that a hand-off was
# lost. The request endpoint answers with a status alone, and a status is not
# proof: a transport error or a 5xx that arrives after GitHub has already
# recorded the request reads exactly like a refusal (issue #134, where the driver
# died with "could not request review" on a PR that did carry a
# review_requested event). Reading the PR back tells the two apart, so a
# hand-off GitHub accepted is never retried into a duplicate or reported as lost.
gh_api_requested_reviewers() {
  local owner="${1}" repo="${2}" number="${3}" json logins teams
  if [[ "${GH_API_TEST_MODE:-0}" == "1" ]]; then
    json="$(gh_api_read_line)"
  else
    json="$(gh_api_call GET "https://api.github.com/repos/${owner}/${repo}/pulls/${number}/requested_reviewers")" || return 1
  fi
  # The payload is {"users":[…],"teams":[…]}: a user object carries a "login" and
  # a team object a "slug". Both are a hand-off to a human, so both are reported;
  # a team-only request read as "nobody was asked" would fail a run on a PR
  # GitHub had already asked. This is the one REST payload in this file, so the
  # separator has to be read the way REST actually answers: pretty-printed, with
  # a space after the colon ("login": "x"), unlike the compact GraphQL payloads
  # and the one-line mock tape. A compact-only pattern finds nothing in a real
  # response, so the read-back reported "nobody was asked" on a PR GitHub had
  # already recorded a request on and the driver kept dying on the hand-off
  # (issue #136: PR #687 carried reviewRequests=[nahcnuj] and the run still
  # exited 1 with "could not request review").
  logins="$(printf '%s' "${json}" |
    grep -oE '"login"[[:space:]]*:[[:space:]]*"[^"]*"' |
    sed 's/^"login"[[:space:]]*:[[:space:]]*"//; s/"$//' || true)"
  teams="$(printf '%s' "${json}" |
    grep -oE '"slug"[[:space:]]*:[[:space:]]*"[^"]*"' |
    sed 's/^"slug"[[:space:]]*:[[:space:]]*"//; s/"$//; s/^/team:/' || true)"
  [[ -n "${logins}" ]] && printf '%s\n' "${logins}"
  [[ -n "${teams}" ]] && printf '%s\n' "${teams}"
  return 0
}

# Post a PR/issue comment. Args: owner repo pr body  (output: comment id)
gh_api_post_comment() {
  local owner="${1}" repo="${2}" number="${3}" body="${4}"
  local payload
  payload="{\"body\":\"$(gh_api_escape "${body}")\"}"
  local json
  json="$(gh_api_call POST "https://api.github.com/repos/${owner}/${repo}/issues/${number}/comments" "${payload}")"
  gh_api_json_num "${json}" "id"
}

# Create an issue. Args: owner repo title body. Output: issue number.
gh_api_create_issue() {
  local owner="${1}" repo="${2}" title="${3}" body="${4}"
  local payload
  payload="{\"title\":\"$(gh_api_escape "${title}")\",\"body\":\"$(gh_api_escape "${body}")\"}"
  local json
  json="$(gh_api_call POST "https://api.github.com/repos/${owner}/${repo}/issues" "${payload}")"
  gh_api_json_num "${json}" "number"
}

# Merge a PR (SQUASH). Args: owner repo pr  (output: true/false)
gh_api_merge_pr() {
  local owner="${1}" repo="${2}" pr_number="${3}"
  local id_query="query(\$owner: String!, \$repo: String!, \$number: Int!) { repository(owner: \$owner, name: \$repo) { pullRequest(number: \$number) { id } } }"
  local pr_id
  if [[ "${GH_API_TEST_MODE:-0}" == "1" ]]; then
    pr_id="PR_ID_PLACEHOLDER"
    gh_api_read_line >/dev/null || true
  else
    local id_json
    id_json="$(gh_api_graphql "${id_query}" -F owner="${owner}" -F repo="${repo}" -F number="${pr_number}")"
    pr_id="$(gh_api_json_str "${id_json}" "id")"
  fi

  local query="mutation { mergePullRequest(input: { pullRequestId: \"${pr_id}\", mergeMethod: SQUASH }) { pullRequest { merged } } }"
  if [[ "${GH_API_TEST_MODE:-0}" == "1" ]]; then
    gh_api_read_line >/dev/null || true
  else
    gh_api_graphql "${query}" >/dev/null
  fi
}