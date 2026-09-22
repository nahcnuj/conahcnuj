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
  attempt=0
  while [[ ${attempt} -lt 5 ]]; do
    attempt=$((attempt + 1))
    local -a args=(
      -sS -D "${headers}" -o "${body}" -X "${method}"
      -H "Authorization: Bearer ${token}"
      -H "Accept: application/vnd.github+json"
    )
    if [[ -n "${data}" ]]; then
      args+=(-H "Content-Type: application/json" -d "${data}")
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
  rm -f "${headers}"
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

# String field value.
gh_api_json_str() {
  local json="${1}" key="${2}"
  printf '%s' "${json}" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
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
  local query='query($owner: String!, $repo: String!) { repository(owner: $owner, name: $repo) { defaultBranchRef { name, target { oid } } } }'
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
  local query='query($owner: String!, $repo: String!, $number: Int!) { repository(owner: $owner, name: $repo) { pullRequest(number: $number) { number, state, title, body, isDraft, mergeable, mergeStateStatus, reviewDecision, headRefName, baseRefName, headRefOid, closingIssuesReferences(first: 5) { nodes { number } } } } }'
  if [[ "${GH_API_TEST_MODE:-0}" == "1" ]]; then
    json="$(gh_api_read_line)"
  else
    json="$(gh_api_graphql "${query}" -F owner="${owner}" -F repo="${repo}" -F number="${number}")"
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

# Non-reviewer merge constraints. Output: checks_state|mergeable|mergeStateStatus
# checks_state is SUCCESS when there is no status check on the head commit.
gh_api_fetch_pr_conditions() {
  local owner="${1}" repo="${2}" number="${3}" json
  local query='query($owner: String!, $repo: String!, $number: Int!) { repository(owner: $owner, name: $repo) { pullRequest(number: $number) { mergeable, mergeStateStatus, commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } } } }'
  if [[ "${GH_API_TEST_MODE:-0}" == "1" ]]; then
    json="$(gh_api_read_line)"
  else
    json="$(gh_api_graphql "${query}" -F owner="${owner}" -F repo="${repo}" -F number="${number}")"
  fi

  local state mergeable mss
  state="$(gh_api_json_str "${json}" "state")"
  if [[ -z "${state}" ]]; then
    state="SUCCESS"
  fi
  mergeable="$(gh_api_json_str "${json}" "mergeable")"
  mss="$(gh_api_json_str "${json}" "mergeStateStatus")"
  printf '%s|%s|%s\n' "${state}" "${mergeable}" "${mss}"
}

# Review status + raw payload.
# Output: decision|payload_b64  (payload = raw GraphQL response; feed it to
# gh_api_review_summary to turn it into readable feedback text).
gh_api_fetch_reviews() {
  local owner="${1}" repo="${2}" number="${3}" json
  local query='query($owner: String!, $repo: String!, $number: Int!) { repository(owner: $owner, name: $repo) { pullRequest(number: $number) { reviewDecision, reviews(last: 25) { nodes { state, body, author { login } } }, comments(last: 25) { nodes { body, author { login } } }, reviewThreads(first: 50) { nodes { isResolved, comments(first: 10) { nodes { body } } } } } } }'
  if [[ "${GH_API_TEST_MODE:-0}" == "1" ]]; then
    json="$(gh_api_read_line)"
  else
    json="$(gh_api_graphql "${query}" -F owner="${owner}" -F repo="${repo}" -F number="${number}")"
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
  local comments_part bn
  comments_part="$(printf '%s' "${json}" | sed 's/"reviewThreads":.*//' | sed -n 's/.*"comments":{"nodes":\(\[[^]]*\]\).*/\1/p')"
  if [[ -n "${comments_part}" ]]; then
    echo "COMMENTS:"
  fi
  while IFS= read -r bn; do
    [[ -z "${bn}" ]] && continue
    local bd
    bd="$(gh_api_json_str "${bn}" "body")"
    [[ -z "${bd}" ]] && bd="(no body)"
    printf -- '- %s\n' "${bd}"
  done < <(printf '%s' "${comments_part}" | grep -oE '"body":"[^"]*"' || true)

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
  matches="$(printf '%s' "${raw}" | grep -oE '\{"state":"[^"]*","body":"[^"]*","author":\{"login":"[^"]*"\}|\{"body":"[^"]*"|"isResolved":(true|false)' || true)"
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
  local query='query($owner: String!, $repo: String!, $branch: String!) { repository(owner: $owner, name: $repo) { pullRequests(headRefName: $branch, states: [OPEN], first: 1) { nodes { number } } } }'
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
  local query='query($owner: String!, $repo: String!, $branch: String!) { repository(owner: $owner, name: $repo) { pullRequests(headRefName: $branch, states: [OPEN, CLOSED, MERGED], first: 1, orderBy: {field: CREATED_AT, direction: DESC}) { nodes { number state } } } }'
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

  local id_query='query($owner: String!, $repo: String!) { repository(owner: $owner, name: $repo) { id } }'
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

# Request reviewers on a PR (empty list = ask for review). Args: owner repo pr
gh_api_request_review() {
  local owner="${1}" repo="${2}" number="${3}"
  local body='{"reviewers":[]}'
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

# Merge a PR (SQUASH). Args: owner repo pr  (output: true/false)
gh_api_merge_pr() {
  local owner="${1}" repo="${2}" pr_number="${3}"
  local id_query='query($owner: String!, $repo: String!, $number: Int!) { repository(owner: $owner, name: $repo) { pullRequest(number: $number) { id } } }'
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