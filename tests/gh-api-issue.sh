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

# Payloads that enumerate the check contexts, so the driver's own
# workflow run can be told apart from real CI. Each CheckRun names the
# workflow it belongs to through checkSuite.workflowRun.workflow.
MOCK_CONDITIONS_CONTEXTS='{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"PENDING","contexts":{"nodes":[{"__typename":"CheckRun","name":"Attempt to resolve issue","status":"IN_PROGRESS","conclusion":null,"checkSuite":{"workflowRun":{"workflow":{"name":"Issue auto-drive"}}}},{"__typename":"CheckRun","name":"Lint shell scripts (ubuntu-latest)","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},{"__typename":"CheckRun","name":"enable / enable","status":"COMPLETED","conclusion":"SKIPPED","checkSuite":{"workflowRun":{"workflow":{"name":"Owner-approved auto-merge"}}}}],"pageInfo":{"hasNextPage":false}}}}}]}}}}}'

# The driver's own run failed (a maintainer cancelled it, or it timed
# out): no code change can ever fix that, so it must not count as a
# constraint the driver tries to "fix" in a loop.
MOCK_CONDITIONS_OWN_FAILED='{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE","contexts":{"nodes":[{"__typename":"CheckRun","name":"Attempt to resolve issue","status":"COMPLETED","conclusion":"CANCELLED","checkSuite":{"workflowRun":{"workflow":{"name":"Issue auto-drive"}}}},{"__typename":"CheckRun","name":"Lint shell scripts (ubuntu-latest)","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}}],"pageInfo":{"hasNextPage":false}}}}}]}}}}}'

# Real CI is still running: the driver must keep waiting for it.
MOCK_CONDITIONS_CI_PENDING='{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"PENDING","contexts":{"nodes":[{"__typename":"CheckRun","name":"Attempt to resolve issue","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"Issue auto-drive"}}}},{"__typename":"CheckRun","name":"Lint shell scripts (ubuntu-latest)","status":"IN_PROGRESS","conclusion":null,"checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}}],"pageInfo":{"hasNextPage":false}}}}}]}}}}}'

# The auto-merge job waits for the driver's own check run before it merges, so
# waiting for it here deadlocks the two: the driver's check cannot finish until
# the driver exits, and the merge job cannot finish until it does. Its check is
# left out of the aggregate, whether it is still pending or already failed.
MOCK_CONDITIONS_AUTOMERGE_PENDING='{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","state":"OPEN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"PENDING","contexts":{"nodes":[{"__typename":"CheckRun","name":"Attempt to resolve issue","status":"IN_PROGRESS","conclusion":null,"checkSuite":{"workflowRun":{"workflow":{"name":"Issue auto-drive"}}}},{"__typename":"CheckRun","name":"enable / enable","status":"IN_PROGRESS","conclusion":null,"checkSuite":{"workflowRun":{"workflow":{"name":"Owner-approved auto-merge"}}}},{"__typename":"CheckRun","name":"Mock tests (no secrets / no network) (ubuntu-latest)","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}}],"pageInfo":{"hasNextPage":false}}}}}]}}}}}'

# Real CI failed: the driver must fix it.
MOCK_CONDITIONS_CI_FAILED='{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE","contexts":{"nodes":[{"__typename":"CheckRun","name":"Attempt to resolve issue","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"Issue auto-drive"}}}},{"__typename":"CheckRun","name":"Lint shell scripts (ubuntu-latest)","status":"COMPLETED","conclusion":"FAILURE","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}}],"pageInfo":{"hasNextPage":false}}}}}]}}}}}'

# A legacy StatusContext (not a CheckRun) that is still expected.
MOCK_CONDITIONS_STATUS_PENDING='{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"PENDING","contexts":{"nodes":[{"__typename":"StatusContext","context":"continuous-integration/jenkins","state":"PENDING"}],"pageInfo":{"hasNextPage":false}}}}}]}}}}}'

# A CheckRun with no checkSuite (created outside a workflow run) cannot
# be attributed to a workflow, so it is never skipped.
MOCK_CONDITIONS_NO_SUITE='{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE","contexts":{"nodes":[{"__typename":"CheckRun","name":"external linter","status":"COMPLETED","conclusion":"FAILURE","checkSuite":null}],"pageInfo":{"hasNextPage":false}}}}}]}}}}}'

# More contexts than one page holds: a filtered aggregate would be
# computed from an incomplete list, so the rollup's own state wins.
MOCK_CONDITIONS_PAGINATED='{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE","contexts":{"nodes":[{"__typename":"CheckRun","name":"Attempt to resolve issue","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"Issue auto-drive"}}}}],"pageInfo":{"hasNextPage":true}}}}}]}}}}}'

# The statusCheckRollup the API really returned for PR #113's head commit
# during the driver run reported in issue #115, replayed verbatim: the
# driver's own run sits there as CANCELLED (that run was still polling when
# the log was captured), every other workflow is green, and the rollup's own
# aggregate state is FAILURE. Kept as one payload so the exclusion is checked
# against real data, not only hand-written mocks.
MOCK_CONDITIONS_REAL='{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE","contexts":{"nodes":[{"__typename":"CheckRun","name":"Attempt to resolve issue","status":"COMPLETED","conclusion":"CANCELLED","checkSuite":{"workflowRun":{"workflow":{"name":"Issue auto-drive"}}}},{"__typename":"CheckRun","name":"enable / enable","status":"COMPLETED","conclusion":"SKIPPED","checkSuite":{"workflowRun":{"workflow":{"name":"Owner-approved auto-merge"}}}},{"__typename":"CheckRun","name":"Lint shell scripts (ubuntu-latest)","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},{"__typename":"CheckRun","name":"Analyze (actions)","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CodeQL"}}}},{"__typename":"CheckRun","name":"Lint shell scripts (windows-latest)","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},{"__typename":"CheckRun","name":"Analyze (javascript-typescript)","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CodeQL"}}}},{"__typename":"CheckRun","name":"Check install.ps1 syntax","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},{"__typename":"CheckRun","name":"install.ps1 deployment test","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},{"__typename":"CheckRun","name":"Mock tests (no secrets / no network) (ubuntu-latest)","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},{"__typename":"CheckRun","name":"Mock tests (no secrets / no network) (windows-latest)","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},{"__typename":"CheckRun","name":"Typecheck opencode plugin","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},{"__typename":"CheckRun","name":"Plugin runtime smoke test (ubuntu-latest)","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},{"__typename":"CheckRun","name":"Plugin runtime smoke test (windows-latest)","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},{"__typename":"CheckRun","name":"E2E opencode run (opencode free model)","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},{"__typename":"CheckRun","name":"CodeQL","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":null}}],"pageInfo":{"hasNextPage":false}}}}}]}}}}}}'

# The statusCheckRollup the API really returned for PR #117's head commit while
# this run was fixing it (issue #115): the auto-merge job had timed out waiting
# for the driver's own check run, so its check sits there as FAILURE, the
# driver's run is still IN_PROGRESS, and all of CI is green. Neither the failed
# auto-merge check nor the driver's own run may become a constraint, or the
# driver waits for the merge that only it can unblock.
MOCK_CONDITIONS_DEADLOCK='{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED","state":"OPEN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"FAILURE","contexts":{"nodes":[{"__typename":"CheckRun","name":"enable / enable","status":"COMPLETED","conclusion":"FAILURE","checkSuite":{"workflowRun":{"workflow":{"name":"Owner-approved auto-merge"}}}},{"__typename":"CheckRun","name":"CodeQL","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":null},{"__typename":"CheckRun","name":"Lint shell scripts (windows-latest)","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},{"__typename":"CheckRun","name":"Check install.ps1 syntax","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},{"__typename":"CheckRun","name":"Mock tests (no secrets / no network) (ubuntu-latest)","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},{"__typename":"CheckRun","name":"Plugin runtime smoke test (windows-latest)","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},{"__typename":"CheckRun","name":"E2E opencode run (opencode free model)","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},{"__typename":"CheckRun","name":"Typecheck opencode plugin","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},{"__typename":"CheckRun","name":"Plugin runtime smoke test (ubuntu-latest)","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},{"__typename":"CheckRun","name":"Mock tests (no secrets / no network) (windows-latest)","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},{"__typename":"CheckRun","name":"Lint shell scripts (ubuntu-latest)","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},{"__typename":"CheckRun","name":"install.ps1 deployment test","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},{"__typename":"CheckRun","name":"Attempt to resolve issue","status":"IN_PROGRESS","conclusion":null,"checkSuite":{"workflowRun":{"workflow":{"name":"Issue auto-drive"}}}},{"__typename":"CheckRun","name":"Analyze (actions)","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CodeQL"}}}},{"__typename":"CheckRun","name":"Analyze (javascript-typescript)","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CodeQL"}}}}],"pageInfo":{"hasNextPage":false}}}}}]}}}}}'

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
  local out state mergeable pr_state
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

  # The driver's own workflow run is excluded from the aggregate:
  # a pending or failed "Issue auto-drive" check must not become a
  # constraint the driver would loop over (issue #115).
  out="$(printf '%s\n' "${MOCK_CONDITIONS_CONTEXTS}" | gh_api_fetch_pr_conditions "nahcnuj" "conahcnuj" 15)"
  state="$(printf '%s' "${out}" | cut -d'|' -f1)"
  [[ "${state}" == "SUCCESS" ]]

  out="$(printf '%s\n' "${MOCK_CONDITIONS_OWN_FAILED}" | gh_api_fetch_pr_conditions "nahcnuj" "conahcnuj" 15)"
  state="$(printf '%s' "${out}" | cut -d'|' -f1)"
  [[ "${state}" == "SUCCESS" ]]

  # The auto-merge job's own check is excluded the same way: it waits for the
  # driver's check run, so the driver waiting for it would deadlock the pair.
  out="$(printf '%s\n' "${MOCK_CONDITIONS_AUTOMERGE_PENDING}" | gh_api_fetch_pr_conditions "nahcnuj" "conahcnuj" 117)"
  state="$(printf '%s' "${out}" | cut -d'|' -f1)"
  [[ "${state}" == "SUCCESS" ]]
  pr_state="$(printf '%s' "${out}" | cut -d'|' -f4)"
  [[ "${pr_state}" == "OPEN" ]]

  # Real CI still running or failing is still a real constraint.
  out="$(printf '%s\n' "${MOCK_CONDITIONS_CI_PENDING}" | gh_api_fetch_pr_conditions "nahcnuj" "conahcnuj" 15)"
  state="$(printf '%s' "${out}" | cut -d'|' -f1)"
  [[ "${state}" == "PENDING" ]]

  out="$(printf '%s\n' "${MOCK_CONDITIONS_CI_FAILED}" | gh_api_fetch_pr_conditions "nahcnuj" "conahcnuj" 15)"
  state="$(printf '%s' "${out}" | cut -d'|' -f1)"
  [[ "${state}" == "FAILURE" ]]

  # Legacy status contexts and unattributed check runs still count.
  out="$(printf '%s\n' "${MOCK_CONDITIONS_STATUS_PENDING}" | gh_api_fetch_pr_conditions "nahcnuj" "conahcnuj" 15)"
  state="$(printf '%s' "${out}" | cut -d'|' -f1)"
  [[ "${state}" == "PENDING" ]]

  out="$(printf '%s\n' "${MOCK_CONDITIONS_NO_SUITE}" | gh_api_fetch_pr_conditions "nahcnuj" "conahcnuj" 15)"
  state="$(printf '%s' "${out}" | cut -d'|' -f1)"
  [[ "${state}" == "FAILURE" ]]

  # A paginated context list cannot be filtered reliably, so the
  # rollup's own aggregate state is trusted instead.
  out="$(printf '%s\n' "${MOCK_CONDITIONS_PAGINATED}" | gh_api_fetch_pr_conditions "nahcnuj" "conahcnuj" 15)"
  state="$(printf '%s' "${out}" | cut -d'|' -f1)"
  [[ "${state}" == "FAILURE" ]]

  # The exclusion is configurable; disabling it restores the
  # unfiltered behaviour.
  out="$(
    CONAHCNUJ_OWN_WORKFLOWS=""
    export CONAHCNUJ_OWN_WORKFLOWS
    printf '%s\n' "${MOCK_CONDITIONS_CONTEXTS}" | gh_api_fetch_pr_conditions "nahcnuj" "conahcnuj" 15
  )"
  state="$(printf '%s' "${out}" | cut -d'|' -f1)"
  [[ "${state}" == "PENDING" ]]

  # Replaying the payload the API really returned for PR #113 in the run
  # from issue #115: the cancelled own run must not keep the driver
  # polling, so the aggregate FAILURE has to come out as SUCCESS.
  out="$(printf '%s\n' "${MOCK_CONDITIONS_REAL}" | gh_api_fetch_pr_conditions "nahcnuj" "conahcnuj" 113)"
  state="$(printf '%s' "${out}" | cut -d'|' -f1)"
  [[ "${state}" == "SUCCESS" ]]

  # The very same payload without the exclusion is the FAILURE that run
  # kept looping on.
  out="$(
    CONAHCNUJ_OWN_WORKFLOWS=""
    export CONAHCNUJ_OWN_WORKFLOWS
    printf '%s\n' "${MOCK_CONDITIONS_REAL}" | gh_api_fetch_pr_conditions "nahcnuj" "conahcnuj" 113
  )"
  state="$(printf '%s' "${out}" | cut -d'|' -f1)"
  [[ "${state}" == "FAILURE" ]]

  # An empty value coming from the environment (a workflow env block, for
  # instance) has to disable the exclusion too, not fall back to the
  # default: re-sourced here so the default assignment sees it.
  out="$(
    CONAHCNUJ_OWN_WORKFLOWS=""
    export CONAHCNUJ_OWN_WORKFLOWS
    # shellcheck source=lib/gh-api.sh
    . "${LIB}"
    printf '%s\n' "${MOCK_CONDITIONS_REAL}" | gh_api_fetch_pr_conditions "nahcnuj" "conahcnuj" 113
  )"
  state="$(printf '%s' "${out}" | cut -d'|' -f1)"
  [[ "${state}" == "FAILURE" ]]

  # The same payload PR #117 handed the driver in the run that reported issue
  # #115: with the auto-merge check excluded the aggregate is SUCCESS, without
  # it the driver sees the FAILURE it could never have fixed by changing code.
  out="$(printf '%s\n' "${MOCK_CONDITIONS_DEADLOCK}" | gh_api_fetch_pr_conditions "nahcnuj" "conahcnuj" 117)"
  state="$(printf '%s' "${out}" | cut -d'|' -f1)"
  [[ "${state}" == "SUCCESS" ]]

  out="$(
    CONAHCNUJ_OWN_WORKFLOWS=""
    export CONAHCNUJ_OWN_WORKFLOWS
    printf '%s\n' "${MOCK_CONDITIONS_DEADLOCK}" | gh_api_fetch_pr_conditions "nahcnuj" "conahcnuj" 117
  )"
  state="$(printf '%s' "${out}" | cut -d'|' -f1)"
  [[ "${state}" == "FAILURE" ]]

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
  local continuation_summary
  continuation_summary="$(printf '%s\n' '{\"data\":{\"repository\":{\"pullRequest\":{\"reviewDecision\":\"REVIEW_REQUIRED\",\"reviews\":{\"nodes\":[]},\"comments\":{\"nodes\":[{\"body\":\"<!-- conahcnuj-continuation -->\\n継続するにはこちらをクリック\",\"author\":{\"login\":\"conahcnuj[bot]\"}}]},\"reviewThreads\":{\"nodes\":[]}}}}}' | gh_api_review_summary)"
  [[ "${continuation_summary}" != *"conahcnuj-continuation"* ]]
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
  # With a reviewer login the request names it; without one it stays a plain
  # ask-for-review. The stubbed gh_api_call reports the request body.
  local body
  body="$(
    gh_api_call() { printf '%s' "${3}"; }
    gh_api_request_review "nahcnuj" "conahcnuj" 15 "nahcnuj"
  )"
  [[ "${body}" == '{"reviewers":["nahcnuj"]}' ]]
  body="$(
    gh_api_call() { printf '%s' "${3}"; }
    gh_api_request_review "nahcnuj" "conahcnuj" 15
  )"
  [[ "${body}" == '{"reviewers":[]}' ]]
  echo "gh_api_request_review passed"
}

test_http_status() {
  local dump
  dump="$(mktemp)"
  # A plain single-block response.
  printf 'HTTP/2 201\r\ncontent-type: application/json\r\n\r\n' > "${dump}"
  [[ "$(gh_api_http_status "${dump}")" == "201" ]]
  # A reason phrase after the code, and a status from an HTTP/1.1 response.
  printf 'HTTP/1.1 422 Unprocessable Entity\r\nx: y\r\n\r\n' > "${dump}"
  [[ "$(gh_api_http_status "${dump}")" == "422" ]]
  # curl records one block per response, so the answer is the LAST status line:
  # a proxy CONNECT reply or an informational 1xx in front of it must not be
  # mistaken for the response (issue #134).
  printf 'HTTP/1.1 200 Connection established\r\n\r\nHTTP/2 201\r\nx: y\r\n\r\n' > "${dump}"
  [[ "$(gh_api_http_status "${dump}")" == "201" ]]
  printf 'HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 403 rate limit exceeded\r\n\r\n' > "${dump}"
  [[ "$(gh_api_http_status "${dump}")" == "403" ]]
  # A header that merely mentions HTTP is not a status line, and no response at
  # all yields nothing rather than a bogus code.
  printf 'via: HTTP/1.1 200 proxy\r\nx-ratelimit-remaining: 4999\r\n\r\n' > "${dump}"
  [[ -z "$(gh_api_http_status "${dump}")" ]]
  : > "${dump}"
  [[ -z "$(gh_api_http_status "${dump}")" ]]
  rm -f "${dump}"
  echo "gh_api_http_status passed"
}

test_requested_reviewers() {
  local out
  # What the read-back reports for a PR somebody was asked to look at.
  out="$(printf '%s\n' '{"users":[{"login":"nahcnuj","id":1}],"teams":[]}' | gh_api_requested_reviewers "nahcnuj" "conahcnuj" 15)"
  [[ "${out}" == "nahcnuj" ]]
  # The shape GitHub really sends: the REST API answers pretty-printed, so the
  # login is written "login": "x", with a space after the colon. Matching the
  # compact spelling only made the read-back report nobody as asked on a PR
  # GitHub had already recorded a request on, which killed the run's hand-off
  # with "could not request review" (issue #136).
  out="$(printf '%s\n' '{"users": [{"login": "nahcnuj", "id": 1}], "teams": []}' | gh_api_requested_reviewers "nahcnuj" "conahcnuj" 15)"
  [[ "${out}" == "nahcnuj" ]]
  # Nobody asked: the answer is empty, not an error (the caller reads it as
  # "the hand-off really is lost" only when it is non-empty).
  out="$(printf '%s\n' '{"users":[],"teams":[]}' | gh_api_requested_reviewers "nahcnuj" "conahcnuj" 15)"
  [[ -z "${out}" ]]
  # A team request carries a slug, never a login, so it is not mistaken for a
  # reviewer; a user asked next to a team still is.
  out="$(printf '%s\n' '{"users":[{"login":"conahcnuj[bot]","id":2}],"teams":[{"slug":"reviewers","id":3}]}' | gh_api_requested_reviewers "nahcnuj" "conahcnuj" 15)"
  [[ "${out}" == "conahcnuj[bot]" ]]
  echo "gh_api_requested_reviewers passed"
}

# The same read-back against a response spread over several lines, which is what
# the REST API sends and what the one-line mock tape cannot express. gh_api_call
# is the only seam that can hand back a multi-line body, so it is stubbed here;
# without the whitespace tolerance of the parser the run's hand-off would be
# reported as lost on a real response (issue #136).
test_requested_reviewers_pretty() {
  local out
  out="$(
    export GH_API_TEST_MODE=0
    gh_api_call() {
      printf '%s' '{
  "users": [
    {
      "login": "nahcnuj",
      "id": 2093896,
      "type": "User"
    }
  ],
  "teams": []
}'
    }
    gh_api_requested_reviewers "nahcnuj" "conahcnuj" 15
  )"
  [[ "${out}" == "nahcnuj" ]]
  echo "gh_api_requested_reviewers (pretty-printed payload) passed"
}

test_post_comment() {
  local out
  out="$(printf '%s\n' "${MOCK_COMMENT}" | gh_api_post_comment "nahcnuj" "conahcnuj" 15 "Addressed feedback")"
  [[ "${out}" == "777" ]]
  echo "gh_api_post_comment passed"
}

test_create_issue() {
  local out
  out="$(printf '%s\n' '{"number":25}' | gh_api_create_issue "nahcnuj" "conahcnuj" "Bug report" "details")"
  [[ "${out}" == "25" ]]
  echo "gh_api_create_issue passed"
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
test_http_status
test_requested_reviewers
test_requested_reviewers_pretty
test_post_comment
test_create_issue
test_merge_pr

echo "All gh-api tests passed"