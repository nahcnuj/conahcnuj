#!/usr/bin/env bash
# These tests intentionally exercise the piped (no-argument) form of the
# dual-mode gh_api_unb64 helper as well as the "$1" form.
# shellcheck disable=SC2119
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${HERE}/../lib/gh-api.sh"

# shellcheck source=lib/gh-api.sh
. "${LIB}"

export GH_API_TEST_MODE=1

MOCK_ISSUE='{"number": 10, "title": "issue駆動自律開発", "body": "# 背景\n\nGitHub Appsによってエージェント自身にコミット・PR作成・レビュー対応をさせられるようになった。\nイシューから始めてPRのレビューコメントを通して作業を進められるようにしたい。", "labels": [{"name": "enhancement"}, {"name": "automation"}], "state": "open", "html_url": "https://github.com/nahcnuj/conahcnuj/issues/10"}'

MOCK_PR_AS_ISSUE='{"number": 15, "title": "Fix something", "body": "Closes #10", "pull_request": {}}'

MOCK_REPO='{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}}'

MOCK_PR_STATE='{"data":{"repository":{"pullRequest":{"number":15,"state":"OPEN","title":"Fix something","body":"Closes #10","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"CHANGES_REQUESTED","headRefName":"feature/fix-10","baseRefName":"main","headRefOid":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","closingIssuesReferences":{"nodes":[{"number":10}]}}}}}'

MOCK_CONDITIONS_OK='{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}}'

MOCK_CONDITIONS_FAIL='{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE"}}}]}}}}}}'

MOCK_CONDITIONS_NOCHECKS='{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[]}}}}}}'

MOCK_REVIEWS='{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[{"state":"CHANGES_REQUESTED","body":"Please fix the typo","author":{"login":"reviewer"}}]},"comments":{"nodes":[{"body":"Nice work so far!","author":{"login":"reviewer"}}]},"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"body":"Inline note on line 10"}]}},{"isResolved":true,"comments":{"nodes":[{"body":"Resolved thread"}]}}]}}}}}'

MOCK_PR_BY_HEAD_EMPTY='{"data":{"repository":{"pullRequests":{"nodes":[]}}}}'

MOCK_PR_BY_HEAD_FOUND='{"data":{"repository":{"pullRequests":{"nodes":[{"number":42}]}}}}'

MOCK_REPO_ID='{"data":{"repository":{"id":"R_kgDOXmplR3p"}}}'

MOCK_CREATE_PR='{"data":{"createPullRequest":{"pullRequest":{"number":123}}}}'

MOCK_COMMENT='{"id":777}'

test_fetch_issue() {
  local out title body labels is_pr
  out="$(printf '%s\n' "${MOCK_ISSUE}" | gh_api_fetch_issue "nahcnuj" "conahcnuj" 10)"
  title="$(printf '%s' "${out}" | cut -d'|' -f1 | gh_api_unb64)"
  body="$(printf '%s' "${out}" | cut -d'|' -f2 | gh_api_unb64)"
  labels="$(printf '%s' "${out}" | cut -d'|' -f3 | gh_api_unb64)"
  is_pr="$(printf '%s' "${out}" | cut -d'|' -f4)"
  [[ "${title}" == "issue駆動自律開発" ]]
  [[ "${body}" == *"GitHub Appsによって"* ]]
  [[ "${labels}" == *"enhancement"* ]]
  [[ "${labels}" == *"automation"* ]]
  [[ "${is_pr}" == "false" ]]
  echo "gh_api_fetch_issue passed"
}

test_fetch_issue_is_pr() {
  local out is_pr
  out="$(printf '%s\n' "${MOCK_PR_AS_ISSUE}" | gh_api_fetch_issue "nahcnuj" "conahcnuj" 15)"
  is_pr="$(printf '%s' "${out}" | cut -d'|' -f4)"
  [[ "${is_pr}" == "true" ]]
  echo "gh_api_fetch_issue (PR detection) passed"
}

test_get_repo() {
  local out branch oid
  out="$(printf '%s\n' "${MOCK_REPO}" | gh_api_get_repo "nahcnuj" "conahcnuj")"
  branch="$(printf '%s' "${out}" | cut -d'|' -f1)"
  oid="$(printf '%s' "${out}" | cut -d'|' -f2)"
  [[ "${branch}" == "main" ]]
  [[ "${oid}" == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]]
  echo "gh_api_get_repo passed"
}

test_fetch_pr_state() {
  local out state title head base closes mergeable decision
  out="$(printf '%s\n' "${MOCK_PR_STATE}" | gh_api_fetch_pr_state "nahcnuj" "conahcnuj" 15)"
  state="$(printf '%s' "${out}" | cut -d'|' -f2)"
  title="$(printf '%s' "${out}" | cut -d'|' -f3 | gh_api_unb64)"
  mergeable="$(printf '%s' "${out}" | cut -d'|' -f6)"
  decision="$(printf '%s' "${out}" | cut -d'|' -f8)"
  head="$(printf '%s' "${out}" | cut -d'|' -f9)"
  base="$(printf '%s' "${out}" | cut -d'|' -f10)"
  closes="$(printf '%s' "${out}" | cut -d'|' -f12)"
  [[ "${state}" == "OPEN" ]]
  [[ "${title}" == "Fix something" ]]
  [[ "${mergeable}" == "MERGEABLE" ]]
  [[ "${decision}" == "CHANGES_REQUESTED" ]]
  [[ "${head}" == "feature/fix-10" ]]
  [[ "${base}" == "main" ]]
  [[ "${closes}" == "10" ]]
  echo "gh_api_fetch_pr_state passed"
}

test_fetch_pr_conditions() {
  local out state mergeable
  out="$(printf '%s\n' "${MOCK_CONDITIONS_OK}" | gh_api_fetch_pr_conditions "nahcnuj" "conahcnuj" 15)"
  state="$(printf '%s' "${out}" | cut -d'|' -f1)"
  mergeable="$(printf '%s' "${out}" | cut -d'|' -f2)"
  [[ "${state}" == "SUCCESS" ]]
  [[ "${mergeable}" == "MERGEABLE" ]]

  out="$(printf '%s\n' "${MOCK_CONDITIONS_FAIL}" | gh_api_fetch_pr_conditions "nahcnuj" "conahcnuj" 15)"
  state="$(printf '%s' "${out}" | cut -d'|' -f1)"
  [[ "${state}" == "FAILURE" ]]

  # No status checks at all => SUCCESS (nothing to wait on).
  out="$(printf '%s\n' "${MOCK_CONDITIONS_NOCHECKS}" | gh_api_fetch_pr_conditions "nahcnuj" "conahcnuj" 15)"
  state="$(printf '%s' "${out}" | cut -d'|' -f1)"
  [[ "${state}" == "SUCCESS" ]]
  echo "gh_api_fetch_pr_conditions passed"
}

test_fetch_reviews() {
  local out decision payload
  out="$(printf '%s\n' "${MOCK_REVIEWS}" | gh_api_fetch_reviews "nahcnuj" "conahcnuj" 15)"
  decision="$(printf '%s' "${out}" | cut -d'|' -f1)"
  payload="$(printf '%s' "${out}" | cut -d'|' -f2 | gh_api_unb64)"
  [[ "${decision}" == "CHANGES_REQUESTED" ]]
  # Payload survives the base64 round trip unchanged.
  [[ "${payload}" == "${MOCK_REVIEWS}" ]]
  echo "gh_api_fetch_reviews passed"
}

test_review_summary() {
  local summary
  summary="$(printf '%s\n' "${MOCK_REVIEWS}" | gh_api_review_summary)"
  [[ "${summary}" == *"reviewDecision: CHANGES_REQUESTED"* ]]
  [[ "${summary}" == *"REVIEWS:"* ]]
  [[ "${summary}" == *"Please fix the typo"* ]]
  [[ "${summary}" == *"COMMENTS:"* ]]
  [[ "${summary}" == *"Nice work so far!"* ]]
  [[ "${summary}" == *"REVIEW THREADS (unresolved):"* ]]
  [[ "${summary}" == *"Inline note on line 10"* ]]
  # Resolved threads are excluded.
  [[ "${summary}" != *"Resolved thread"* ]]
  echo "gh_api_review_summary passed"
}

test_find_pr_by_head() {
  local out
  out="$(printf '%s\n' "${MOCK_PR_BY_HEAD_EMPTY}" | gh_api_find_pr_by_head "nahcnuj" "conahcnuj" "conahcnuj/10-x")"
  [[ -z "${out}" ]]
  out="$(printf '%s\n' "${MOCK_PR_BY_HEAD_FOUND}" | gh_api_find_pr_by_head "nahcnuj" "conahcnuj" "feature/fix-10")"
  [[ "${out}" == "42" ]]
  echo "gh_api_find_pr_by_head passed"
}

test_create_pr() {
  local out
  out="$(printf '%s\n' "${MOCK_REPO_ID}" "${MOCK_CREATE_PR}" | gh_api_create_pr "nahcnuj" "conahcnuj" "New PR" "Body" "branch" "main")"
  [[ "${out}" == "123" ]]
  echo "gh_api_create_pr passed"
}

test_update_pr() {
  local out
  out="$(printf '%s\n' '{}' | gh_api_update_pr "nahcnuj" "conahcnuj" 15 "Closes #10

# 背景

書き換え済みの本文です。")"
  # gh_api_update_pr discards the response (must not leak into stdout).
  [[ -z "${out}" ]]
  echo "gh_api_update_pr passed"
}

test_request_review() {
  local out
  out="$(printf '%s\n' '{}' | gh_api_request_review "nahcnuj" "conahcnuj" 15)"
  [[ "${out}" == '{}' ]]
  echo "gh_api_request_review passed"
}

test_post_comment() {
  local out
  out="$(printf '%s\n' "${MOCK_COMMENT}" | gh_api_post_comment "nahcnuj" "conahcnuj" 15 "Addressed feedback")"
  [[ "${out}" == "777" ]]
  echo "gh_api_post_comment passed"
}

test_merge_pr() {
  gh_api_merge_pr "nahcnuj" "conahcnuj" 15 < <(printf '%s\n' '{}' '{}')
  echo "gh_api_merge_pr passed"
}

test_fetch_issue
test_fetch_issue_is_pr
test_get_repo
test_fetch_pr_state
test_fetch_pr_conditions
test_fetch_reviews
test_review_summary
test_find_pr_by_head
test_create_pr
test_update_pr
test_request_review
test_post_comment
test_merge_pr

echo "All gh-api tests passed"