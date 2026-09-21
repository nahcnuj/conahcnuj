#!/usr/bin/env bash
# next_free_branch must avoid head-branch names already used by any PR (even a
# closed one), because GitHub rejects createPullRequest for a duplicate head.
# Open PRs are left as-is so ensure_pr can reuse them. Offline: the API helpers
# read one mock line per call from stdin.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

export GH_API_TEST_MODE=1
CONAHCNUJ_IMPORT=1
CONAHCNUJ_TEST_MODE=0
# shellcheck source=bin/conahcnuj.sh
. "${REPO}/bin/conahcnuj.sh"

EMPTY='{"data":{"repository":{"pullRequests":{"nodes":[]}}}}'
OPEN='{"data":{"repository":{"pullRequests":{"nodes":[{"number":5,"state":"OPEN"}]}}}}'
CLOSED='{"data":{"repository":{"pullRequests":{"nodes":[{"number":13,"state":"CLOSED"}]}}}}'

check() {
  local want="${1}" got="${2}" desc="${3}"
  if [[ "${got}" != "${want}" ]]; then
    echo "FAIL: ${desc}: want '${want}', got '${got}'" >&2
    exit 1
  fi
}

# No PR uses the name: unchanged.
got="$(printf '%s\n' "${EMPTY}" | next_free_branch nahcnuj conahcnuj "conahcnuj/10-issue")"
check "conahcnuj/10-issue" "${got}" "no PR"

# An open PR uses the name: unchanged (ensure_pr will reuse it).
got="$(printf '%s\n' "${OPEN}" | next_free_branch nahcnuj conahcnuj "conahcnuj/10-issue")"
check "conahcnuj/10-issue" "${got}" "open PR"

# A closed PR uses the name: suffix to -2.
got="$(printf '%s\n' "${CLOSED}" "${EMPTY}" | next_free_branch nahcnuj conahcnuj "conahcnuj/10-issue")"
check "conahcnuj/10-issue-2" "${got}" "closed PR"

# -2 also taken: pick -3.
got="$(printf '%s\n' "${CLOSED}" "${CLOSED}" "${EMPTY}" | next_free_branch nahcnuj conahcnuj "conahcnuj/10-issue")"
check "conahcnuj/10-issue-3" "${got}" "closed PR twice"

echo "next_free_branch passed"
