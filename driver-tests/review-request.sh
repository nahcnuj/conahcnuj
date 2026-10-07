#!/usr/bin/env bash
# request_review_from_owner tests (offline).
#
# The review request is the hand-off from the driver to a human, so the run ends
# once the repository owner is assigned as the PR's reviewer. A reviewer GitHub
# refuses to assign (e.g. the PR author, or a request that is already pending)
# must not fail the run: the unnamed ask-for-review is the fallback. Every call
# is retried once — asking for the same reviewer twice records no second request,
# and a lone failure is not proof of a refusal (issue #139: PR #138 carried the
# owner as its reviewer while the run exited 1 with "could not request review").
# When no call was accepted the PR is read back before the hand-off is called
# lost (issue #134), and only an answer that says nobody is asked may fail the
# run: a PR that cannot even be read back is reported, not declared lost.
#
# Sources bin/conahcnuj.sh via CONAHCNUJ_IMPORT=1 (main() must not run) and
# stubs gh_api_request_review so the calls are observable without any network
# I/O. Each attempt is appended to a file, so the fallback order is checkable.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

# The retry pause must not cost the offline run 15 seconds per failed attempt.
export CONAHCNUJ_HANDOFF_RETRY_SECONDS=0

export CONAHCNUJ_IMPORT=1
# shellcheck source=bin/conahcnuj.sh
. "${REPO}/bin/conahcnuj.sh"

CALLS="$(mktemp)"
trap 'rm -f "${CALLS}"' EXIT

# How many attempts of each form fail before the stub starts answering 2xx: 0
# always succeeds, 1 fails the first attempt only (a transient failure the retry
# recovers), 2 fails both attempts there are. Counted from the call log, because
# the caller runs the function in a command substitution and a counter would be
# lost with the subshell.
FAIL_NAMED=0
FAIL_UNNAMED=0
# What the PR really holds, as gh_api_requested_reviewers would report it, or
# UNREADABLE to make the read-back itself fail.
REQUESTED=""
UNREADABLE="false"

# Stub of gh_api_request_review that records the requested reviewer ("named" for
# the 4-arg form) and fails on demand. Records to a file so the order survives
# the command substitution the caller runs the function in.
gh_api_request_review() {
  local reviewer="${4:-}" seen
  printf 'REQUEST|%s|%s\n' "${3}" "${reviewer}" >> "${CALLS}"
  seen="$(grep -c "^REQUEST|${3}|${reviewer}\$" "${CALLS}" || true)"
  if [[ -n "${reviewer}" ]]; then
    if (( seen <= FAIL_NAMED )); then
      return 1
    fi
    return 0
  fi
  if (( seen <= FAIL_UNNAMED )); then
    return 1
  fi
  return 0
}

gh_api_requested_reviewers() {
  if [[ "${UNREADABLE}" == "true" ]]; then
    return 1
  fi
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

# A lone failure is a transport error, not a refusal: the retry is idempotent, so
# it must recover the hand-off instead of falling through to the unnamed request
# (issue #139).
FAIL_NAMED=1
: > "${CALLS}"
out="$(request_review_from_owner "nahcnuj" "conahcnuj" 15 2>&1)" || fail "a transient failure must not fail the hand-off"
[[ "${out}" == *"Assigned nahcnuj as reviewer on PR #15."* ]] || fail "the retry did not recover the assignment: ${out}"
[[ "$(cat "${CALLS}")" == "REQUEST|15|nahcnuj
REQUEST|15|nahcnuj" ]] || fail "the failed attempt was not retried once: $(cat "${CALLS}")"
echo "request_review_from_owner retries a failed request once: passed"

# A reviewer that cannot be assigned falls back to the unnamed ask-for-review.
FAIL_NAMED=2
: > "${CALLS}"
out="$(request_review_from_owner "nahcnuj" "conahcnuj" 15 2>&1)" || fail "an unassignable owner must not fail the hand-off"
[[ "${out}" == *"not assignable; asked for review instead"* ]] || fail "the fallback was not reported: ${out}"
[[ "$(cat "${CALLS}")" == "REQUEST|15|nahcnuj
REQUEST|15|nahcnuj
REQUEST|15|" ]] || fail "the fallback must retry without a reviewer: $(cat "${CALLS}")"
echo "request_review_from_owner falls back to ask-for-review: passed"

# Both forms failing *and* GitHub reporting nobody asked is the one case the run
# may not paper over: the PR would sit without anyone asked to look at it.
FAIL_NAMED=2
FAIL_UNNAMED=2
: > "${CALLS}"
out="$(request_review_from_owner "nahcnuj" "conahcnuj" 15 2>&1)" && fail "a failed hand-off must report an error"
[[ "${out}" == *"ERROR: could not request review on PR #15."* ]] || fail "the failed hand-off was not reported: ${out}"
[[ "$(grep -c '^REQUEST|15|' "${CALLS}")" == "4" ]] || fail "both forms must be retried once: $(cat "${CALLS}")"
echo "request_review_from_owner reports a failed hand-off: passed"

# ...unless the PR already carries the request. GitHub recorded it and the call
# still reported a failure (a transport error or a 5xx after the fact), which is
# what killed the run behind issue #134: every constraint had passed, the review
# was asked for, and the driver exited 1 and filed a bug report.
FAIL_NAMED=2
FAIL_UNNAMED=2
REQUESTED="nahcnuj"
: > "${CALLS}"
out="$(request_review_from_owner "nahcnuj" "conahcnuj" 15 2>&1)" || fail "a review request the PR already holds must count as done"
[[ "${out}" == *"Review already requested on PR #15 (nahcnuj)"* ]] || fail "the confirmed hand-off was not reported: ${out}"
grep -q "ERROR: could not request review" <<<"${out}" && fail "a confirmed hand-off must not be reported as an error: ${out}"
echo "request_review_from_owner confirms a hand-off GitHub already recorded: passed"

# A PR that cannot be read back is not a PR that is known to have nobody asked.
# Reporting that as a lost hand-off is exactly what filed the bogus bug reports
# of issues #134 / #136 / #139, so the run warns and finishes instead. Run in
# this shell (not a command substitution) because the verdict also has to reach
# the run's final line through REVIEW_HANDOFF_CONFIRMED.
UNREADABLE="true"
: > "${CALLS}"
OUT_FILE="$(mktemp)"
request_review_from_owner "nahcnuj" "conahcnuj" 15 > "${OUT_FILE}" 2>&1 || fail "an unreadable PR must not fail the run"
out="$(cat "${OUT_FILE}")"
rm -f "${OUT_FILE}"
[[ "${out}" == *"WARNING: no review request on PR #15 was accepted"* ]] || fail "the unverifiable hand-off was not reported: ${out}"
grep -q "ERROR: could not request review" <<<"${out}" && fail "an unverifiable hand-off must not be called lost: ${out}"
[[ "${REVIEW_HANDOFF_CONFIRMED}" == "false" ]] || fail "the unconfirmed hand-off must be recorded as such"
log_review_handoff "nahcnuj" "conahcnuj" 15 "nahcnuj" 2>&1 | grep -q "PR #15 is ready for a human reviewer" || fail "the final line must not claim an unconfirmed request"
echo "request_review_from_owner reports an unverifiable hand-off without failing the run: passed"

echo "All review-request tests passed"
