#!/usr/bin/env bash
# Offline tests for the discussion helpers (bug reports live in the "Bug
# report" category). No secrets, no network: every call reads one mocked
# response line from stdin.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${HERE}/../lib/gh-api.sh"

# shellcheck source=lib/gh-api.sh
. "${LIB}"

export GH_API_TEST_MODE=1

MOCK_CATEGORIES='{"data":{"repository":{"id":"R_kgDOXmplR3p","discussionCategories":{"nodes":[{"id":"DIC_kwDOAAAAAA","name":"General","slug":"general"},{"id":"DIC_kwDOBBBBBB","name":"Bug report","slug":"bug-report"}]}}}}'

MOCK_DISCUSSIONS_EMPTY='{"data":{"repository":{"discussions":{"nodes":[]}}}}'

MOCK_DISCUSSIONS_FOUND='{"data":{"repository":{"discussions":{"nodes":[{"number":7,"id":"D_kwDOCcCCCCC","title":"conahcnuj: failed to resolve #14","url":"https://github.com/nahcnuj/conahcnuj/discussions/7"},{"number":8,"id":"D_kwDODdDDDDD","title":"conahcnuj: driver terminated abnormally","url":"https://github.com/nahcnuj/conahcnuj/discussions/8"}]}}}}'

MOCK_CREATE_DISCUSSION='{"data":{"createDiscussion":{"discussion":{"number":9,"url":"https://github.com/nahcnuj/conahcnuj/discussions/9"}}}}'

MOCK_EMPTY_RESULT='{"data":{}}'

MOCK_REPLY='{"data":{"addDiscussionComment":{"comment":{"id":"DC_kwDOEeEEEEE"}}}}'

# One bug-report discussion. The body is last, as gh_api_fetch_discussion's
# query asks, and carries escaped quotes and \n (a real report quotes the
# driver's log tail) so the extractor is exercised end to end.
MOCK_DISCUSSION='{"data":{"repository":{"discussion":{"number":7,"id":"D_kwDOCcCCCCC","title":"conahcnuj: failed to resolve #14","url":"https://github.com/nahcnuj/conahcnuj/discussions/7","category":{"name":"Bug report"},"comments(first:100)":{"nodes":[{"body":"another occurrence"}]},"body":"## Error log\n\nERROR: grep -qE \"Bug report issue\" run.log\n"}}}}'

# The same thread after a triage run filed an issue: the reply carries the marker
# gh_api_fetch_discussion looks for, so a second run does not file a second one.
MOCK_DISCUSSION_TRIAGED='{"data":{"repository":{"discussion":{"number":7,"id":"D_kwDOCcCCCCC","title":"conahcnuj: failed to resolve #14","url":"https://github.com/nahcnuj/conahcnuj/discussions/7","category":{"name":"Bug report"},"comments(first:100)":{"nodes":[{"body":"<!-- conahcnuj:triage issue=42 -->\nTracked as #42."}]},"body":"report"}}}}'

MOCK_DISCUSSION_OTHER_CATEGORY='{"data":{"repository":{"discussion":{"number":3,"id":"D_kwDOOtherXXX","title":"How do I ...","url":"https://github.com/nahcnuj/conahcnuj/discussions/3","category":{"name":"General"},"comments(first:100)":{"nodes":[]},"body":"a question"}}}}'

MOCK_DISCUSSION_MISSING='{"data":{"repository":{}}}'

MOCK_CREATE_ISSUE='{"number":42,"html_url":"https://github.com/nahcnuj/conahcnuj/issues/42"}'

test_discussion_category() {
  local out repo_id category_id
  # Resolved by name...
  out="$(printf '%s\n' "${MOCK_CATEGORIES}" | gh_api_discussion_category "nahcnuj" "conahcnuj" "Bug report")"
  repo_id="${out%%|*}"
  category_id="${out#*|}"
  [[ "${repo_id}" == "R_kgDOXmplR3p" ]]
  [[ "${category_id}" == "DIC_kwDOBBBBBB" ]]
  # ...by slug...
  out="$(printf '%s\n' "${MOCK_CATEGORIES}" | gh_api_discussion_category "nahcnuj" "conahcnuj" "bug-report")"
  category_id="${out#*|}"
  [[ "${category_id}" == "DIC_kwDOBBBBBB" ]]
  # ...and case-insensitively (the driver default is "Bug report").
  out="$(printf '%s\n' "${MOCK_CATEGORIES}" | gh_api_discussion_category "nahcnuj" "conahcnuj" "BUG REPORT")"
  category_id="${out#*|}"
  [[ "${category_id}" == "DIC_kwDOBBBBBB" ]]
  echo "gh_api_discussion_category passed"
}

test_discussion_category_unknown() {
  local out rc category_id
  rc=0
  out="$(printf '%s\n' "${MOCK_CATEGORIES}" | gh_api_discussion_category "nahcnuj" "conahcnuj" "Nope" )" || rc=$?
  [[ "${rc}" -eq 0 ]]
  category_id="${out#*|}"
  # The repository id is still reported; the category id is empty so callers
  # can tell "no such category" from "no such repository".
  [[ "${out%%|*}" == "R_kgDOXmplR3p" ]]
  [[ -z "${category_id}" ]]
  echo "gh_api_discussion_category (unknown) passed"
}

test_create_discussion() {
  local out number url
  # Two calls: the category lookup, then the mutation.
  out="$(printf '%s\n' "${MOCK_CATEGORIES}" "${MOCK_CREATE_DISCUSSION}" | gh_api_create_discussion "nahcnuj" "conahcnuj" "Bug report" "conahcnuj: failed to resolve #14" "details")"
  number="${out%%|*}"
  url="${out#*|}"
  [[ "${number}" == "9" ]]
  [[ "${url}" == "https://github.com/nahcnuj/conahcnuj/discussions/9" ]]
  echo "gh_api_create_discussion passed"
}

test_create_discussion_unknown_category() {
  local rc=0
  printf '%s\n' "${MOCK_CATEGORIES}" | gh_api_create_discussion "nahcnuj" "conahcnuj" "Nope" "title" "body" >/dev/null 2>&1 || rc=$?
  [[ "${rc}" -eq 1 ]]
  echo "gh_api_create_discussion (unknown category) passed"
}

test_create_discussion_failed() {
  local rc=0 out=""
  out="$(printf '%s\n' "${MOCK_CATEGORIES}" "${MOCK_EMPTY_RESULT}" | gh_api_create_discussion "nahcnuj" "conahcnuj" "Bug report" "title" "body")" || rc=$?
  [[ "${rc}" -eq 1 ]]
  [[ -z "${out}" ]]
  echo "gh_api_create_discussion (API failure) passed"
}

test_find_discussion_by_title() {
  local out number id url
  out="$(printf '%s\n' "${MOCK_CATEGORIES}" "${MOCK_DISCUSSIONS_FOUND}" | gh_api_find_discussion_by_title "nahcnuj" "conahcnuj" "Bug report" "conahcnuj: failed to resolve #14")"
  number="${out%%|*}"
  id="$(printf '%s' "${out}" | cut -d'|' -f2)"
  url="$(printf '%s' "${out}" | cut -d'|' -f3)"
  [[ "${number}" == "7" ]]
  [[ "${id}" == "D_kwDOCcCCCCC" ]]
  [[ "${url}" == "https://github.com/nahcnuj/conahcnuj/discussions/7" ]]
  # The second thread of the same category is found too (title, not position).
  out="$(printf '%s\n' "${MOCK_CATEGORIES}" "${MOCK_DISCUSSIONS_FOUND}" | gh_api_find_discussion_by_title "nahcnuj" "conahcnuj" "Bug report" "conahcnuj: driver terminated abnormally")"
  [[ "${out%%|*}" == "8" ]]
  # No match: empty output, success (the caller then opens a new thread).
  out="$(printf '%s\n' "${MOCK_CATEGORIES}" "${MOCK_DISCUSSIONS_FOUND}" | gh_api_find_discussion_by_title "nahcnuj" "conahcnuj" "Bug report" "conahcnuj: failed to resolve #99")"
  [[ -z "${out}" ]]
  out="$(printf '%s\n' "${MOCK_CATEGORIES}" "${MOCK_DISCUSSIONS_EMPTY}" | gh_api_find_discussion_by_title "nahcnuj" "conahcnuj" "Bug report" "conahcnuj: failed to resolve #14")"
  [[ -z "${out}" ]]
  echo "gh_api_find_discussion_by_title passed"
}

test_find_discussion_unknown_category() {
  local rc=0
  printf '%s\n' "${MOCK_CATEGORIES}" | gh_api_find_discussion_by_title "nahcnuj" "conahcnuj" "Nope" "title" >/dev/null 2>&1 || rc=$?
  [[ "${rc}" -eq 1 ]]
  echo "gh_api_find_discussion_by_title (unknown category) passed"
}

test_reply_discussion() {
  local out
  out="$(printf '%s\n' "${MOCK_REPLY}" | gh_api_reply_discussion "nahcnuj" "conahcnuj" "D_kwDOCcCCCCC" "another occurrence")"
  [[ "${out}" == "DC_kwDOEeEEEEE" ]]
  echo "gh_api_reply_discussion passed"
}

test_fetch_discussion() {
  local out title body url category id triaged
  out="$(printf '%s\n' "${MOCK_DISCUSSION}" | gh_api_fetch_discussion "nahcnuj" "conahcnuj" "7")"
  title="$(gh_api_unb64 "$(printf '%s' "${out}" | cut -d'|' -f1)")"
  body="$(gh_api_unb64 "$(printf '%s' "${out}" | cut -d'|' -f2)")"
  url="$(printf '%s' "${out}" | cut -d'|' -f3)"
  category="$(printf '%s' "${out}" | cut -d'|' -f4)"
  id="$(printf '%s' "${out}" | cut -d'|' -f5)"
  triaged="$(printf '%s' "${out}" | cut -d'|' -f6)"
  [[ "${title}" == "conahcnuj: failed to resolve #14" ]]
  # A report body carries escaped quotes and newlines; both must survive.
  grep -q 'grep -qE "Bug report issue" run.log' <<<"${body}" || { echo "FAIL: escaped quotes were lost from the body"; return 1; }
  grep -q '## Error log' <<<"${body}" || { echo "FAIL: newlines were lost from the body"; return 1; }
  [[ "${url}" == "https://github.com/nahcnuj/conahcnuj/discussions/7" ]]
  [[ "${category}" == "Bug report" ]]
  [[ "${id}" == "D_kwDOCcCCCCC" ]]
  [[ "${triaged}" == "0" ]]
  # Another category is reported as-is, so the caller can refuse to triage it.
  out="$(printf '%s\n' "${MOCK_DISCUSSION_OTHER_CATEGORY}" | gh_api_fetch_discussion "nahcnuj" "conahcnuj" "3")"
  [[ "$(printf '%s' "${out}" | cut -d'|' -f4)" == "General" ]]
  # A number that is not a discussion yields no id (and no category, which would
  # otherwise make the caller compare against an empty category name).
  out="$(printf '%s\n' "${MOCK_DISCUSSION_MISSING}" | gh_api_fetch_discussion "nahcnuj" "conahcnuj" "999")"
  [[ -z "$(printf '%s' "${out}" | cut -d'|' -f5)" ]]
  echo "gh_api_fetch_discussion passed"
}

test_fetch_discussion_already_triaged() {
  local out triaged
  out="$(printf '%s\n' "${MOCK_DISCUSSION_TRIAGED}" | gh_api_fetch_discussion "nahcnuj" "conahcnuj" "7")"
  triaged="$(printf '%s' "${out}" | cut -d'|' -f6)"
  [[ "${triaged}" == "42" ]] || { echo "FAIL: triaged issue not detected (got '${triaged}')"; exit 1; }
  echo "gh_api_fetch_discussion (already triaged) passed"
}

test_create_issue() {
  local out
  out="$(printf '%s\n' "${MOCK_CREATE_ISSUE}" | gh_api_create_issue "nahcnuj" "conahcnuj" "conahcnuj-triage: driver stalls" "found by the triage run")"
  [[ "${out}" == "42" ]] || { echo "FAIL: issue number not parsed (got '${out}')"; exit 1; }
  # A response without a number means the issue was not created.
  out="$(printf '%s\n' '{}' | gh_api_create_issue "nahcnuj" "conahcnuj" "title" "body")"
  [[ -z "${out}" ]] || { echo "FAIL: an empty response must not yield an issue number"; exit 1; }
  echo "gh_api_create_issue passed"
}

test_json_str_escaped() {
  local out
  # Escaped quotes inside the value must not truncate it, and the key is
  # resolved like the other extractors do: the last occurrence wins.
  out="$(gh_api_json_str_escaped '{"a":"x","body":"one \"two\" three","b":"y"}' "body")"
  [[ "${out}" == 'one \"two\" three' ]] || { echo "FAIL: got '${out}'"; exit 1; }
  out="$(gh_api_json_str_escaped '{"body":"first","c":"z","body":"second"}' "body")"
  [[ "${out}" == "second" ]] || { echo "FAIL: last occurrence not used (got '${out}')"; exit 1; }
  # A non-string value yields nothing instead of garbage.
  [[ -z "$(gh_api_json_str_escaped '{"body":null}' "body")" ]]
  [[ -z "$(gh_api_json_str_escaped '{"other":"x"}' "body")" ]]
  echo "gh_api_json_str_escaped passed"
}

test_discussion_category
test_discussion_category_unknown
test_create_discussion
test_create_discussion_unknown_category
test_create_discussion_failed
test_find_discussion_by_title
test_find_discussion_unknown_category
test_reply_discussion
test_fetch_discussion
test_fetch_discussion_already_triaged
test_create_issue
test_json_str_escaped

echo "All gh-api discussion tests passed"
