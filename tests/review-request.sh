#!/usr/bin/env bash
# request_review_from_owner tests (offline).
#
# The review request is the hand-off from the driver to a human, so the run ends
# once the repository owner is assigned as the PR's reviewer. A reviewer GitHub
# refuses to assign (e.g. the PR author, or a request that is already pending)
# must not fail the run: the unnamed ask-for-review is the fallback, and only
# when that fails too is the hand-off reported as an error — and even then the PR
# is read back first, because the request endpoint answers with a status and a
# status does not prove nobody was asked (issue #134).
#
# Sources bin/conahcnuj.sh via CONAHCNUJ_IMPORT=1 (main() must not run) and
# stubs gh_api_request_review so the calls are observable without any network
# I/O. Each attempt is appended to a file, so the fallback order is checkable.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

export CONAHCNUJ_IMPORT=1
# shellcheck source=bin/conahcnuj.sh
. "${REPO}/bin/conahcnuj.sh"

CALLS="$(mktemp)"
trap 'rm -f "${CALLS}"' EXIT

FAIL_NAMED="false"
FAIL_UNNAMED="false"
# What the PR really holds, as gh_api_requested_reviewers would report it.
REQUESTED=""

# Stub of gh_api_request_review that records the requested reviewer ("named" for
# the 4-arg form) and fails on demand. Records to a file so the order survives
# the command substitution the caller runs the function in.
gh_api_request_review() {
  local reviewer="${4:-}"
  printf 'REQUEST|%s|%s\n' "${3}" "${reviewer}" >> "${CALLS}"
  if [[ -z "${reviewer}" && "${FAIL_UNNAMED}" == "true" ]]; then
    return 1
  fi
  if [[ -n "${reviewer}" && "${FAIL_NAMED}" == "true" ]]; then
    return 1
  fi
  return 0
}

gh_api_requested_reviewers() {
  [[ -n "${REQUESTED}" ]] || return 0
  printf '%s\n' "${REQUESTED}"
}

fail() { echo "FAIL: $*" >&2; exit 1; }

# The happy path: the owner is named as the reviewer and the hand-off succeeds.
: > "${CALLS}"
out="$(request_review_from_owner "nahcnuj" "conahcnuj" 15 2>&1)" || fail "naming the owner as reviewer must succeed"
[[ "${out}" == *"Assigned nahcnuj as reviewer on PR #15."* ]] || fail "the owner was not reported as assigned: ${out}"
[[ "$(cat "${CALLS}")" == "REQUEST|15|nahcnuj" ]] || fail "the owner was not the requested reviewer: $(cat "${CALLS}")"
echo "request_review_from_owner assigns the owner: passed"

# A reviewer that cannot be assigned falls back to the unnamed ask-for-review.
FAIL_NAMED="true"
: > "${CALLS}"
out="$(request_review_from_owner "nahcnuj" "conahcnuj" 15 2>&1)" || fail "an unassignable owner must not fail the hand-off"
[[ "${out}" == *"not assignable; asked for review instead"* ]] || fail "the fallback was not reported: ${out}"
[[ "$(cat "${CALLS}")" == "REQUEST|15|nahcnuj
REQUEST|15|" ]] || fail "the fallback must retry without a reviewer: $(cat "${CALLS}")"
echo "request_review_from_owner falls back to ask-for-review: passed"

# Both attempts failing is the one case the run may not paper over: the PR would
# sit without anyone asked to look at it.
FAIL_UNNAMED="true"
: > "${CALLS}"
out="$(request_review_from_owner "nahcnuj" "conahcnuj" 15 2>&1)" && fail "a failed hand-off must report an error"
[[ "${out}" == *"ERROR: could not request review on PR #15."* ]] || fail "the failed hand-off was not reported: ${out}"
echo "request_review_from_owner reports a failed hand-off: passed"

# ...unless the PR already carries the request. GitHub recorded it and the call
# still reported a failure (a transport error or a 5xx after the fact), which is
# what killed the run behind issue #134: every constraint had passed, the review
# was asked for, and the driver exited 1 and filed a bug report.
REQUESTED="nahcnuj"
: > "${CALLS}"
out="$(request_review_from_owner "nahcnuj" "conahcnuj" 15 2>&1)" || fail "a review request the PR already holds must count as done"
[[ "${out}" == *"Review already requested on PR #15 (nahcnuj)"* ]] || fail "the confirmed hand-off was not reported: ${out}"
grep -q "ERROR: could not request review" <<<"${out}" && fail "a confirmed hand-off must not be reported as an error: ${out}"
echo "request_review_from_owner confirms a hand-off GitHub already recorded: passed"

echo "All review-request tests passed"