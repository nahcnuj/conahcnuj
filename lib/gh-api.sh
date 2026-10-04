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
# multi-line title/body/comment text is the norm).
gh_api_escape() {
  printf '%s' "${1}" |
    sed 's/\\/\\\\/g; s/"/\\"/g' |
    awk '{ if (NR > 1) printf "\\n"; printf "%s", $0 }'
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

# HTTP layer. Args: method url [request-body]
# Real mode: performs the call; on 403/429 waits for the rate limit using
# Retry-After / X-RateLimit-Reset headers and retries (max 5 tries).
# Test mode: echoes the single stdin "response" line unchanged.
gh_api_call() {
  local method="${1:-GET}"
  local url="${2}"
  local data="${3:-}"

  if [[ "${GH_API_TEST_MODE:-0}" == "1" ]]; then
    gh_api_read_line
    return 0
  fi

  local token headers body code attempt
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
    local -a args=(
      -sS -D "${headers}" -o "${body}" -X "${method}"
      -H "Authorization: Bearer ${token}"
      -H "Accept: application/vnd.github+json"
    )
    if [[ -n "${data}" ]]; then
      args+=(-H "Content-Type: application/json" --data-binary "@${datafile}")
    fi
    curl "${args[@]}" "${url}" || true
    code="$(tr -d '\r' < "${headers}" | sed -n '1s/.* \([0-9][0-9][0-9]\)$/\1/p')"
    if [[ "${code}" == "403" || "${code}" == "429" ]]; then
      rate_limit_wait "$(tr -d '\r' < "${headers}")"
      continue
    fi
    break
  done
  GH_API_LAST_HTTP_CODE="${code}"
  rm -f "${headers}" "${datafile}"
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

# Raw (still backslash-escaped) value of a JSON string field, honouring escapes
# so a value may itself contain quotes. Args: json key
# gh_api_json_str stops at the first quote, which truncates a field whose content
# has escaped quotes (a bug report carrying the driver's log tail is full of
# them). This scans past `\"` pairs instead and reports the LAST occurrence of
# the key, matching gh_api_json_str's greediness, so put the multi-line field
# last in the query. Decoded with gh_api_unescape. Prints nothing when the key is
# absent or its value is not a string.
gh_api_json_str_escaped() {
  printf '%s' "${1}" | awk -v key="${2}" '
    # 1-based offset, in s, of the character right after the last occurrence of
    # needle (0 when there is none). o tracks where the current tail of s starts
    # in the original string.
    function last_match(s, needle,   p, o, q) {
      o = 1
      p = 0
      while ((q = index(s, needle)) > 0) {
        p = o + q + length(needle) - 1
        o = p
        s = substr(s, q + length(needle))
      }
      return p
    }
    {
      after = last_match($0, "\"" key "\"")
      if (after == 0) exit
      rest = substr($0, after + 1)
      sub(/^[[:space:]]*:[[:space:]]*/, "", rest)
      if (substr(rest, 1, 1) != "\"") exit
      rest = substr(rest, 2)
      value = ""
      n = length(rest)
      i = 1
      while (i <= n) {
        c = substr(rest, i, 1)
        # A backslash escapes whatever follows it, so the pair is consumed whole
        # and an escaped quote never ends the value.
        if (c == "\\") {
          value = value substr(rest, i, 2)
          i += 2
          continue
        }
        if (c == "\"") break
        value = value c
        i++
      }
      printf "%s", value
      exit
    }
  '
}

# Fetch one discussion thread. Args: owner repo number
# Output: title_b64|body_b64|url|category|id|triaged_issue
# `triaged_issue` is the issue number a previous triage run already filed for
# this thread (0 when the thread was never triaged), read from the marker the
# triage reply carries. That makes triage idempotent: re-running it (dispatch,
# or a re-fired trigger) must not open a second issue for one report.
# The query asks for `body` last so the multi-line field is the document's last
# `"body":` occurrence, which gh_api_json_str_escaped resolves correctly.
gh_api_fetch_discussion() {
  local owner="${1}" repo="${2}" number="${3}"
  local query="query { repository(owner: \"${owner}\", name: \"${repo}\") { discussion(number: ${number}) { number id title url category { name } comments(first: 100) { nodes { body } } body } } }"
  local json
  if [[ "${GH_API_TEST_MODE:-0}" == "1" ]]; then
    json="$(gh_api_read_line)"
  else
    json="$(gh_api_graphql "${query}")"
  fi

  # The marker lives in a comment body, so it is plain text in the response and
  # needs no JSON parsing.
  local triaged
  triaged="$(printf '%s' "${json}" | grep -oE '<!-- conahcnuj:triage issue=[0-9]+' | sed -n 's/.*issue=//p' | head -1)"
  printf '%s|%s|%s|%s|%s|%s\n' \
    "$(gh_api_b64 "$(gh_api_json_str_escaped "${json}" "title")")" \
    "$(gh_api_b64 "$(gh_api_unescape "$(gh_api_json_str_escaped "${json}" "body")")")" \
    "$(gh_api_json_str "${json}" "url")" \
    "$(gh_api_json_str "${json}" "name")" \
    "$(gh_api_json_str "${json}" "id")" \
    "${triaged:-0}"
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

# Every issue number in the repository, oldest first, one per line. Pull
# requests are included (the REST issues endpoint returns both); the caller
# filters them out with the is_pr flag of gh_api_fetch_issue. Paginates until a
# short page comes back, so it also works for repositories with more than 100
# issues. Used to walk the historical bug-report issues for the migration to
# Discussions (bin/migrate-bug-reports.sh).
gh_api_list_issue_numbers() {
  local owner="${1}" repo="${2}"
  local per_page=100 page=1 json count
  while :; do
    json="$(gh_api_call GET "https://api.github.com/repos/${owner}/${repo}/issues?state=all&per_page=${per_page}&page=${page}")" || return 1
    count="$(printf '%s' "${json}" | grep -oE '"number":[0-9]+' | wc -l | tr -d '[:space:]')"
    printf '%s' "${json}" | grep -oE '"number":[0-9]+' | cut -d: -f2 || true
    [[ "${count}" -ge "${per_page}" ]] || break
    page=$((page + 1))
  done
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
  local query="query { repository(owner: \"${owner}\", name: \"${repo}\") { pullRequest(number: ${number}) { reviewDecision, reviews(last: 25) { nodes { state, body, author { login } } }, comments(last: 25) { nodes { body, author { login } } }, reviewThreads(first: 50) { nodes { isResolved, comments(first: 10) { nodes { body } } } } } } }"
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
  local threads_part tn
  threads_part="$(printf '%s' "${json}" | sed -n 's/.*"reviewThreads":{"nodes":\(.*\)/\1/p')"
  if echo "${threads_part}" | grep -q '"isResolved":false'; then
    echo "REVIEW THREADS (unresolved):"
  fi
  while IFS= read -r tn; do
    [[ -z "${tn}" ]] && continue
    local tbd
    tbd="$(printf '%s' "${tn}" | grep -oE '"body":"[^"]*"' | sed 's/"body":"//; s/"$//' | tr '\n' ' ')"
    printf -- '- %s\n' "${tbd}"
  done < <(printf '%s' "${threads_part}" | grep -oE '\{"isResolved":false,"comments":\{"nodes":\[[^]]*\]' || true)
}

# Fingerprint of the actionable review feedback in a raw reviews payload.
# Returns empty when there is no reviewer feedback to act on, so a poll of the
# initial "waiting for review" state (reviewDecision=REVIEW_REQUIRED or empty,
# no reviews/comments/threads) is never mistaken for fresh feedback.
gh_api_review_fingerprint() {
  local raw="${1}" matches="" decision=""
  matches="$(printf '%s' "${raw}" | grep -oE '\{"state":"[^"]*","body":"[^"]*","author":\{"login":"[^"]*"\}|\{"body":"[^"]*"|"isResolved":(true|false)' | grep -v '"body":"<!-- conahcnuj-continuation -->' || true)"
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

# Post a PR/issue comment. Args: owner repo pr body  (output: comment id)
gh_api_post_comment() {
  local owner="${1}" repo="${2}" number="${3}" body="${4}"
  local payload
  payload="{\"body\":\"$(gh_api_escape "${body}")\"}"
  local json
  json="$(gh_api_call POST "https://api.github.com/repos/${owner}/${repo}/issues/${number}/comments" "${payload}")"
  gh_api_json_num "${json}" "id"
}

# Create an issue. Args: owner repo title body
# Output: issue number (empty when the API call failed)
# Used by the discussion triage run, which turns an investigated bug-report
# discussion into planned work (bin/conahcnuj.sh).
gh_api_create_issue() {
  local owner="${1}" repo="${2}" title="${3}" body="${4}"
  local escaped_title escaped_body payload
  escaped_title="$(gh_api_escape "${title}")"
  escaped_body="$(gh_api_escape "${body}")"
  payload="{\"title\":\"${escaped_title}\",\"body\":\"${escaped_body}\"}"
  local json
  json="$(gh_api_call POST "https://api.github.com/repos/${owner}/${repo}/issues" "${payload}")" || return 1
  gh_api_json_num "${json}" "number"
}

# Close an issue (pull requests are issues too). Args: owner repo number
# state_reason "not_planned" marks it as moved/duplicate instead of done.
gh_api_close_issue() {
  local owner="${1}" repo="${2}" number="${3}" reason="${4:-}"
  local payload='{"state":"closed"}'
  if [[ -n "${reason}" ]]; then
    payload="{\"state\":\"closed\",\"state_reason\":\"$(gh_api_escape "${reason}")\"}"
  fi
  gh_api_call PATCH "https://api.github.com/repos/${owner}/${repo}/issues/${number}" "${payload}" >/dev/null
}

# --- Discussions ------------------------------------------------------------
# Error reports live in a discussion category, not in issues: an issue would
# re-trigger issue-driver.yml (the driver's own report is then resolved as if it
# were planned work), and a discussion is the right home for an unplanned
# failure report. Discussions are GraphQL-only.
# The two directions are kept apart on purpose: reporting files a discussion
# (gh_api_create_discussion / gh_api_reply_discussion), triage reads one back and
# turns an investigated report into an issue (gh_api_fetch_discussion below).

# Resolve the repository node id and one discussion category id.
# Args: owner repo category (category name or slug, matched case-insensitively)
# Output: repo_id|category_id (category_id empty when nothing matches)
gh_api_discussion_category() {
  local owner="${1}" repo="${2}" category="${3}"
  local query="query(\$owner: String!, \$repo: String!) { repository(owner: \$owner, name: \$repo) { id discussionCategories(first: 25) { nodes { id name slug } } } }"
  local json
  if [[ "${GH_API_TEST_MODE:-0}" == "1" ]]; then
    json="$(gh_api_read_line)"
  else
    json="$(gh_api_graphql "${query}" -F owner="${owner}" -F repo="${repo}")"
  fi

  local repo_id nodes node id name slug want
  repo_id="$(printf '%s' "${json}" | sed -n 's/.*"repository":{"id":"\([^"]*\)".*/\1/p')"
  want="$(printf '%s' "${category}" | tr '[:upper:]' '[:lower:]')"
  # Field order comes from the query above, so a node is one flat object.
  nodes="$(printf '%s' "${json}" | grep -oE '\{"id":"[^"]*","name":"[^"]*","slug":"[^"]*"\}' || true)"
  while IFS= read -r node; do
    [[ -n "${node}" ]] || continue
    name="$(gh_api_json_str "${node}" "name" | tr '[:upper:]' '[:lower:]')"
    slug="$(gh_api_json_str "${node}" "slug" | tr '[:upper:]' '[:lower:]')"
    if [[ "${name}" == "${want}" || "${slug}" == "${want}" ]]; then
      id="$(gh_api_json_str "${node}" "id")"
      printf '%s|%s\n' "${repo_id}" "${id}"
      return 0
    fi
  done <<< "${nodes}"
  printf '%s|\n' "${repo_id}"
}

# Start a discussion thread. Args: owner repo category title body
# Output: number|url
gh_api_create_discussion() {
  local owner="${1}" repo="${2}" category="${3}" title="${4}" body="${5}"
  local ids repo_id category_id
  ids="$(gh_api_discussion_category "${owner}" "${repo}" "${category}")"
  repo_id="${ids%%|*}"
  category_id="${ids#*|}"
  if [[ -z "${repo_id}" || -z "${category_id}" ]]; then
    echo "ERROR: discussion category '${category}' does not exist in ${owner}/${repo}." >&2
    return 1
  fi

  local query
  query="mutation { createDiscussion(input: { repositoryId: \"${repo_id}\", categoryId: \"${category_id}\", title: \"$(gh_api_escape "${title}")\", body: \"$(gh_api_escape "${body}")\" }) { discussion { number url } } }"
  local json
  if [[ "${GH_API_TEST_MODE:-0}" == "1" ]]; then
    json="$(gh_api_read_line)"
  else
    json="$(gh_api_graphql "${query}")"
  fi
  local number url
  number="$(gh_api_json_num "${json}" "number")"
  url="$(gh_api_json_str "${json}" "url")"
  if [[ -z "${number}" ]]; then
    echo "ERROR: the discussion was not created (category ${category})." >&2
    return 1
  fi
  printf '%s|%s\n' "${number}" "${url}"
}

# Find the thread in a category whose title matches exactly, so repeated
# failures of the same kind can be collected in one thread.
# Args: owner repo category title
# Output: number|discussion_id|url (empty when the category has no such thread)
gh_api_find_discussion_by_title() {
  local owner="${1}" repo="${2}" category="${3}" title="${4}"
  local ids category_id
  ids="$(gh_api_discussion_category "${owner}" "${repo}" "${category}")"
  category_id="${ids#*|}"
  if [[ -z "${category_id}" ]]; then
    echo "ERROR: discussion category '${category}' does not exist in ${owner}/${repo}." >&2
    return 1
  fi

  # Discussions are not searchable through the REST API and the GraphQL
  # connection has no title filter, so walk the category's threads
  # (newest first) and compare titles locally.
  local query="query { repository(owner: \"${owner}\", name: \"${repo}\") { discussions(first: 100, categoryId: \"${category_id}\", orderBy: { field: CREATED_AT, direction: DESC }) { nodes { number id title url } } } }"
  local json
  if [[ "${GH_API_TEST_MODE:-0}" == "1" ]]; then
    json="$(gh_api_read_line)"
  else
    json="$(gh_api_graphql "${query}")"
  fi

  local nodes node number
  nodes="$(printf '%s' "${json}" | grep -oE '\{"number":[0-9]+,"id":"[^"]*","title":"[^"]*","url":"[^"]*"\}' || true)"
  while IFS= read -r node; do
    [[ -n "${node}" ]] || continue
    [[ "$(gh_api_json_str "${node}" "title")" == "${title}" ]] || continue
    number="$(gh_api_json_num "${node}" "number")"
    printf '%s|%s|%s\n' "${number}" "$(gh_api_json_str "${node}" "id")" "$(gh_api_json_str "${node}" "url")"
    return 0
  done <<< "${nodes}"
  return 0
}

# Reply to an existing thread. Args: owner repo discussion_id body
# (owner/repo are accepted for symmetry with the other helpers.)
# Output: comment id
gh_api_reply_discussion() {
  local owner="${1}" repo="${2}" discussion_id="${3}" body="${4}"
  local query
  query="mutation { addDiscussionComment(input: { discussionId: \"${discussion_id}\", body: \"$(gh_api_escape "${body}")\" }) { comment { id } } }"
  local json
  if [[ "${GH_API_TEST_MODE:-0}" == "1" ]]; then
    json="$(gh_api_read_line)"
  else
    json="$(gh_api_graphql "${query}")"
  fi
  gh_api_json_str "${json}" "id"
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