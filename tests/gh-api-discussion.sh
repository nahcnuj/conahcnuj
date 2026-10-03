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

test_discussion_category
test_discussion_category_unknown
test_create_discussion
test_create_discussion_unknown_category
test_create_discussion_failed
test_find_discussion_by_title
test_find_discussion_unknown_category
test_reply_discussion

echo "All gh-api discussion tests passed"
