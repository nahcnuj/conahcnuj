#!/usr/bin/env bash
# gh_api_review_fingerprint tests: a raw reviews payload with no reviewer
# feedback must fingerprint as EMPTY (so the driver only re-requests review
# instead of firing a spurious implementation round), while real feedback or an
# actionable decision (CHANGES_REQUESTED / COMMENTED with no body) must
# fingerprint as non-empty and change when the feedback changes. The bot's own
# in-thread replies must NOT change it (the agent answers the reviewer in the
# thread, and counting that answer would loop forever).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

# shellcheck source=lib/gh-api.sh
. "${REPO}/lib/gh-api.sh"

EMPTY_REVIEWS='{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}'
NO_DECISION='{"data":{"repository":{"pullRequest":{"reviewDecision":null,"reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}'
CONTINUATION_ONLY='{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviews":{"nodes":[]},"comments":{"nodes":[{"body":"<!-- conahcnuj-continuation -->\n継続するにはこちらをクリック","author":{"login":"conahcnuj[bot]"}}]},"reviewThreads":{"nodes":[]}}}}'
CHANGES_EMPTY_BODY='{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[{"state":"CHANGES_REQUESTED","body":"","author":{"login":"reviewer"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}'
WITH_FEEDBACK='{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[{"state":"CHANGES_REQUESTED","body":"Please fix the typo","author":{"login":"reviewer"}}]},"comments":{"nodes":[{"body":"Nice work","author":{"login":"reviewer"}}]},"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"body":"Inline note"}]}}]}}}}'

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -z "$(gh_api_review_fingerprint "${EMPTY_REVIEWS}")" ]] || fail "empty reviews / REVIEW_REQUIRED must fingerprint empty"
echo "empty reviews / REVIEW_REQUIRED -> empty: passed"

[[ -z "$(gh_api_review_fingerprint "${NO_DECISION}")" ]] || fail "empty reviews / no decision must fingerprint empty"
echo "empty reviews / no decision -> empty: passed"

[[ -z "$(gh_api_review_fingerprint "${CONTINUATION_ONLY}")" ]] || fail "continuation comment must not be treated as review feedback"
echo "continuation comment -> empty: passed"

# An approval short of the required count leaves reviewDecision at
# REVIEW_REQUIRED. The approval is not feedback, so it must fingerprint empty;
# otherwise the owner's approval fires a spurious implementation round on a PR
# that is only waiting for another reviewer.
APPROVED_STILL_REQUIRED='{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviews":{"nodes":[{"state":"APPROVED","body":"LGTM","author":{"login":"nahcnuj"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}'
[[ -z "$(gh_api_review_fingerprint "${APPROVED_STILL_REQUIRED}")" ]] || fail "an approval short of the required count must not fingerprint as feedback"
echo "APPROVED review / REVIEW_REQUIRED -> empty: passed"

# An approval must not mask a change request that is still pending: the
# CHANGES_REQUESTED review is the feedback and has to keep the fingerprint
# non-empty.
APPROVED_AND_CHANGES='{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[{"state":"APPROVED","body":"LGTM","author":{"login":"nahcnuj"}},{"state":"CHANGES_REQUESTED","body":"Please fix the typo","author":{"login":"reviewer"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}'
[[ -n "$(gh_api_review_fingerprint "${APPROVED_AND_CHANGES}")" ]] || fail "an approval must not hide a pending change request"
echo "APPROVED + CHANGES_REQUESTED -> non-empty: passed"

[[ -n "$(gh_api_review_fingerprint "${CHANGES_EMPTY_BODY}")" ]] || fail "CHANGES_REQUESTED with empty body must fingerprint non-empty"
echo "CHANGES_REQUESTED with empty body -> non-empty: passed"

f1="$(gh_api_review_fingerprint "${WITH_FEEDBACK}")"
[[ -n "${f1}" ]] || fail "feedback payload must fingerprint non-empty"
echo "with feedback -> non-empty: passed"

CHANGED_FEEDBACK='{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[{"state":"CHANGES_REQUESTED","body":"Please fix the OTHER typo","author":{"login":"reviewer"}}]},"comments":{"nodes":[{"body":"Nice work","author":{"login":"reviewer"}}]},"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"body":"Inline note"}]}}]}}}}'
f2="$(gh_api_review_fingerprint "${CHANGED_FEEDBACK}")"
[[ "${f1}" != "${f2}" ]] || fail "changed feedback must change the fingerprint"
echo "changed feedback -> fingerprint changes: passed"

# The agent answers a review thread by posting a reply as the bot. That reply
# is a review comment too, so it must be dropped before hashing: otherwise
# every answer would read as fresh feedback and the driver would answer its own
# answer forever.
THREAD_FEEDBACK='{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":321,"body":"Inline note","author":{"login":"reviewer"}}]}}]}}}}'
THREAD_FEEDBACK_AND_BOT_REPLY='{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"databaseId":321,"body":"Inline note","author":{"login":"reviewer"}},{"databaseId":322,"body":"Fixed in the latest commit","author":{"login":"conahcnuj[bot]"}}]}}]}}}}'
f3="$(gh_api_review_fingerprint "${THREAD_FEEDBACK}")"
f4="$(gh_api_review_fingerprint "${THREAD_FEEDBACK_AND_BOT_REPLY}")"
[[ -n "${f3}" ]] || fail "thread feedback must fingerprint non-empty"
[[ "${f3}" == "${f4}" ]] || fail "the bot's own reply must not change the fingerprint"
echo "bot reply in a thread -> fingerprint unchanged: passed"

echo "All review-fingerprint tests passed"