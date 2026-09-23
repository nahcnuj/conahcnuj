#!/usr/bin/env bash
# gh_api_review_fingerprint tests: a raw reviews payload with no reviewer
# feedback must fingerprint as EMPTY (so the driver polls instead of firing a
# spurious implementation round), while real feedback or an actionable
# decision (CHANGES_REQUESTED / COMMENTED with no body) must fingerprint as
# non-empty and change when the feedback changes.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

# shellcheck source=lib/gh-api.sh
. "${REPO}/lib/gh-api.sh"

EMPTY_REVIEWS='{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}'
NO_DECISION='{"data":{"repository":{"pullRequest":{"reviewDecision":null,"reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}'
CHANGES_EMPTY_BODY='{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[{"state":"CHANGES_REQUESTED","body":"","author":{"login":"reviewer"}}]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}'
WITH_FEEDBACK='{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[{"state":"CHANGES_REQUESTED","body":"Please fix the typo","author":{"login":"reviewer"}}]},"comments":{"nodes":[{"body":"Nice work","author":{"login":"reviewer"}}]},"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"body":"Inline note"}]}}]}}}}'

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -z "$(gh_api_review_fingerprint "${EMPTY_REVIEWS}")" ]] || fail "empty reviews / REVIEW_REQUIRED must fingerprint empty"
echo "empty reviews / REVIEW_REQUIRED -> empty: passed"

[[ -z "$(gh_api_review_fingerprint "${NO_DECISION}")" ]] || fail "empty reviews / no decision must fingerprint empty"
echo "empty reviews / no decision -> empty: passed"

[[ -n "$(gh_api_review_fingerprint "${CHANGES_EMPTY_BODY}")" ]] || fail "CHANGES_REQUESTED with empty body must fingerprint non-empty"
echo "CHANGES_REQUESTED with empty body -> non-empty: passed"

f1="$(gh_api_review_fingerprint "${WITH_FEEDBACK}")"
[[ -n "${f1}" ]] || fail "feedback payload must fingerprint non-empty"
echo "with feedback -> non-empty: passed"

CHANGED_FEEDBACK='{"data":{"repository":{"pullRequest":{"reviewDecision":"CHANGES_REQUESTED","reviews":{"nodes":[{"state":"CHANGES_REQUESTED","body":"Please fix the OTHER typo","author":{"login":"reviewer"}}]},"comments":{"nodes":[{"body":"Nice work","author":{"login":"reviewer"}}]},"reviewThreads":{"nodes":[{"isResolved":false,"comments":{"nodes":[{"body":"Inline note"}]}}]}}}}'
f2="$(gh_api_review_fingerprint "${CHANGED_FEEDBACK}")"
[[ "${f1}" != "${f2}" ]] || fail "changed feedback must change the fingerprint"
echo "changed feedback -> fingerprint changes: passed"

echo "All review-fingerprint tests passed"