#!/usr/bin/env bash
# Owner-approved auto-merge "merge or enable auto-merge, without waiting for CI"
# test (offline).
#
# The workflow used to poll the head commit's status checks until every CI run was
# green and then merge itself, keeping the 'enable / enable' check pending on the
# head for up to 25 minutes (so the driver and the merge job could deadlock).
# Issue #269 asked to stop waiting: merge when mergeable, otherwise enable native
# auto-merge and let GitHub decide when to land it. The job now finishes in a few
# API calls.
#
# This test extracts the `run:` block from the workflow (a reusable workflow may
# not read files from the calling repository, so the logic must live in the YAML)
# and proves that:
#   - the block no longer polls/watches checks (no sleep, no --watch, no rollup)
#   - it stays syntactically valid shell
#   - replaying mocked `gh` calls, the block merges now when it can, queues native
#     auto-merge (and exits 0 without dispatching) when immediate merge is refused,
#     fails with the Allow auto-merge hint when neither works, skips a changed
#     head, skips an already-merged PR, and dispatches only when it observed the
#     merge.
#
# No secrets, no network. Skipped where jq is unavailable.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
WORKFLOW="${REPO}/.github/workflows/owner-approved-auto-merge.yml"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq is not installed"; exit 0; }

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT

RUN="${ROOT}/run.sh"
start="$(grep -nF "run: |" "${WORKFLOW}" | head -1 | cut -d: -f1)"
if [[ -z "${start}" ]]; then
  echo "FAIL: could not find the run block in ${WORKFLOW}" >&2
  exit 1
fi
# The run block is the last element of the file; strip the 10-space YAML indent.
awk -v s="${start}" 'NR > s { sub(/^          /, ""); print }' "${WORKFLOW}" > "${RUN}"
if [[ ! -s "${RUN}" ]]; then
  echo "FAIL: the run block extracted from ${WORKFLOW} is empty" >&2
  exit 1
fi

# The whole point of #269: the job must not wait for CI, so the old polling
# machinery must be gone. Grep the extracted block (comments included) - any of
# these means the waiting loop came back.
if grep -E 'CHECK_TIMEOUT|CHECK_INTERVAL|IGNORED_WORKFLOWS|outstanding_checks|gh pr checks|statusCheckRollup|--watch|while true|sleep ' "${RUN}"; then
  echo "FAIL: the merge job still waits for checks (see matches above)" >&2
  exit 1
fi
echo "the merge job does not wait for checks passed"

if ! bash -n "${RUN}"; then
  echo "FAIL: the run block is not valid bash" >&2
  exit 1
fi
echo "the run block is valid bash passed"

# The requested contract: merge now when mergeable, otherwise enable native
# auto-merge. The two calls must still carry the approved head guard.
for needle in "--auto" "--match-head-commit" "Allow auto-merge"; do
  if ! grep -qF -- "${needle}" "${RUN}"; then
    echo "FAIL: the run block no longer contains '${needle}'" >&2
    exit 1
  fi
done
echo "merge / enable-auto-merge contract markers present passed"

# --- behaviour replay with a mocked gh -------------------------------------
#
# Scenario state is exported and read by the mock; the extracted block runs in
# its own bash, so `gh` is exported as a function.
MERGE_ERROR="X Pull request is not mergeable: the head branch is not up to date with the base branch."
AUTO_ERROR="X could not enable auto-merge: Resource not accessible by integration"
DISPATCH_LOG="${ROOT}/dispatched"
HEAD_SHA="deadbeef"

gh() {
  local a auto=0 tag
  for a in "$@"; do
    [[ "${a}" == "--auto" ]] && auto=1
  done
  case "$1" in
    api)
      # repos/<owner>/<repo>/pulls/<n> -> what the mock scenario put in PR_API_JSON
      printf '%s' "${PR_API_JSON}"
      ;;
    pr)
      case "$2" in
        merge)
          if [[ "${auto}" == "1" ]]; then
            if [[ "${AUTO_RC}" == "0" ]]; then
              printf '%s\n' "Created an automatic merge for PR #${PR_NUMBER}."
              return 0
            fi
            printf '%s\n' "${AUTO_ERROR}" >&2
            return 1
          fi
          if [[ "${MERGE_RC}" == "0" ]]; then
            printf '%s\n' "Merged pull request #${PR_NUMBER}."
            return 0
          fi
          printf '%s\n' "${MERGE_ERROR}" >&2
          return 1
          ;;
        view)
          printf '%s\n' "${VIEW_STATE}"
          ;;
        *)
          echo "unexpected gh pr args: $*" >&2
          return 1
          ;;
      esac
      ;;
    workflow)
      # gh workflow run <name> --repo <owner>/<repo>
      tag="$(printf '%s ' "$@")"
      printf '%s\n' "${tag% }" >> "${DISPATCH_LOG}"
      return 0
      ;;
    *)
      echo "unexpected gh command: $*" >&2
      return 1
      ;;
  esac
}
export -f gh

# build_pr_api <head sha> <state> <merged>
build_pr_api() {
  PR_API_JSON="$(printf '{"head":{"sha":"%s"},"state":"%s","merged":%s}' "${1}" "${2}" "${3}")"
  export PR_API_JSON
}

# run_block <scenario> [MERGE_RC] [AUTO_RC] [VIEW_STATE] [POST_MERGE_DISPATCH]
run_block() {
  local scenario="$1" out rc
  export REPOSITORY="nahcnuj/conahcnuj"
  export PR_NUMBER="42"
  export HEAD_SHA="deadbeef"
  export MERGE_METHOD="merge"
  export MERGE_RC="${2:-0}"
  export AUTO_RC="${3:-0}"
  export VIEW_STATE="${4:-MERGED}"
  export POST_MERGE_DISPATCH="${5:-}"
  rm -f "${DISPATCH_LOG}"
  export MERGE_ERROR AUTO_ERROR DISPATCH_LOG
  out="$(bash "${RUN}" 2>&1)" && rc=0 || rc=$?
  printf 'rc=%s %s\n%s\n' "${rc}" "${scenario}" "${out}"
}

expect_rc() {
  local label="${1}" want="${2}" got="${3}" out="${4}" needle="${5:-}"
  if [[ "${got}" != "${want}" ]]; then
    echo "FAIL: ${label}: rc '${got}', want '${want}'" >&2
    printf '%s\n' "${out}" >&2
    exit 1
  fi
  if [[ -n "${needle}" ]] && [[ "${out}" != *"${needle}"* ]]; then
    echo "FAIL: ${label}: '${needle}' is not in the output" >&2
    printf '%s\n' "${out}" >&2
    exit 1
  fi
  echo "${label} passed"
}

expect_dispatch() {
  local label="${1}" want="${2}"
  local got=""
  if [[ -f "${DISPATCH_LOG}" ]]; then
    got="$(<"${DISPATCH_LOG}")"
  fi
  if [[ "${got}" != *"${want}"* ]]; then
    echo "FAIL: ${label}: dispatch '${want}' was not recorded" >&2
    printf '%s\n' "${got}" >&2
    exit 1
  fi
  echo "${label} passed"
}

expect_no_dispatch() {
  local label="${1}"
  if [[ -f "${DISPATCH_LOG}" ]]; then
    echo "FAIL: ${label}: unexpected dispatch recorded" >&2
    cat "${DISPATCH_LOG}" >&2
    exit 1
  fi
  echo "${label} passed"
}

# A changed head (later push dismissed the approval) is skipped, not merged.
build_pr_api "cafebabe" "OPEN" false
out="$(run_block "head-changed" 0 0 MERGED "")"
rc="$(printf '%s\n' "${out}" | sed -n '1{s/^rc=//;s/ .*$//;p}')"
expect_rc "a changed head is skipped" 0 "${rc}" "${out}" "not the current head"

# The same approval reaching a PR that already merged is a no-op, not a failure.
build_pr_api "${HEAD_SHA}" "closed" true
out="$(run_block "already-merged" 0 0 MERGED "")"
rc="$(printf '%s\n' "${out}" | sed -n '1{s/^rc=//;s/ .*$//;p}')"
expect_rc "an already-merged PR is skipped" 0 "${rc}" "${out}" "already merged"

# The unhappy path: neither immediate merge nor native auto-merge work. The job
# fails and points at branch protection / Allow auto-merge.
build_pr_api "${HEAD_SHA}" "OPEN" false
out="$(run_block "auto-merge-unavailable" 1 1 OPEN "")"
rc="$(printf '%s\n' "${out}" | sed -n '1{s/^rc=//;s/ .*$//;p}')"
expect_rc "failing both merge paths fails the job" 1 "${rc}" "${out}" "Allow auto-merge"

# CI still green, head up to date: the immediate merge succeeds and the job ends.
# post-merge-dispatch fires because the merge actually happened.
build_pr_api "${HEAD_SHA}" "OPEN" false
out="$(run_block "merge-now" 0 0 MERGED "cd.yml")"
rc="$(printf '%s\n' "${out}" | sed -n '1{s/^rc=//;s/ .*$//;p}')"
expect_rc "an immediate merge succeeds" 0 "${rc}" "${out}" "Merged pull request"
expect_dispatch "post-merge-dispatch fires after an immediate merge" "workflow run cd.yml --repo nahcnuj/conahcnuj"

# post-merge-dispatch is only for when we observed the merge.
build_pr_api "${HEAD_SHA}" "OPEN" false
out="$(run_block "merge-now-no-dispatch" 0 0 MERGED "")"
rc="$(printf '%s\n' "${out}" | sed -n '1{s/^rc=//;s/ .*$//;p}')"
expect_rc "an immediate merge without dispatch env succeeds" 0 "${rc}" "${out}" "Merged pull request"
expect_no_dispatch "no dispatch is fired without post-merge-dispatch"

# Checks still pending / head behind: immediate merge is refused, native
# auto-merge is queued and the job ends green without waiting for CI. Nothing is
# dispatched because the PR is not merged yet.
build_pr_api "${HEAD_SHA}" "OPEN" false
out="$(run_block "queue-auto-merge" 1 0 OPEN "cd.yml")"
rc="$(printf '%s\n' "${out}" | sed -n '1{s/^rc=//;s/ .*$//;p}')"
expect_rc "an refused merge queues native auto-merge" 0 "${rc}" "${out}" "auto-merge is queued"
expect_no_dispatch "no dispatch is fired while the merge is queued"

# All requirements were actually met, so --auto landed immediately (native
# auto-merge merges at once when nothing blocks it): that is a merge, not a queue.
build_pr_api "${HEAD_SHA}" "OPEN" false
out="$(run_block "auto-merge-lands" 1 0 MERGED "cd.yml")"
rc="$(printf '%s\n' "${out}" | sed -n '1{s/^rc=//;s/ .*$//;p}')"
expect_rc "a queued auto-merge that lands immediately succeeds" 0 "${rc}" "${out}" "auto-merge is queued"
expect_dispatch "post-merge-dispatch fires when auto-merge merged the PR" "workflow run cd.yml --repo nahcnuj/conahcnuj"

echo "auto-merge merge-or-queue behavior passed"

echo "auto-merge workflow behavior passed"