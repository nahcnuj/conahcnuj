#!/usr/bin/env bash
# ensure_pr body-derivation test (offline).
#
# Regression test for the "malformed Closes #" bug: a resumed PR with no linked
# issue must keep its body verbatim and must not be PATCHed. A PR that closes an
# issue gets the "Closes #<n>\n\n<issue body>" body.
#
# Sources bin/conahcnuj.sh via CONAHCNUJ_IMPORT=1 (main() must not run) and
# stubs gh_api_update_pr / gh_api_find_pr_by_head / gh_api_create_pr so the
# derived body is observable without any network I/O. ensure_pr runs in a
# command-substitution subshell (an in-subshell variable set would vanish), so
# the stubs append their reports to a file outside the subshell.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

export CONAHCNUJ_IMPORT=1
# shellcheck source=bin/conahcnuj.sh
. "${REPO}/bin/conahcnuj.sh"

REPORT="$(mktemp)"
trap 'rm -f "${REPORT}"' EXIT

# Stub of gh_api_update_pr that reports the number and body instead of the API.
gh_api_update_pr() {
  printf 'UPDATE|%s|%s\n' "${3}" "${4}" >> "${REPORT}"
}

# ensure_pr syncs the body at most once per driver process (PR_BODY_SYNCED_FILE)
# and the report file accumulates otherwise, so reset both between scenarios.
reset_body_marker() {
  rm -f "${PR_BODY_SYNCED_FILE}"
  : > "${REPORT}"
}

# With a linked issue, the body is derived and synced once.
reset_body_marker
out="$(ensure_pr "nahcnuj" "conahcnuj" "15" "feature/fix-10" "main" "Fix something" "real issue body

more" "10")"
[[ "${out}" == "15" ]] || { echo "FAIL: ensure_pr output was '${out}' (expected 15)"; exit 1; }
[[ "$(grep -c '^UPDATE|' "${REPORT}")" == "1" ]] || { echo "FAIL: linked-issue body sync must issue exactly one PATCH"; exit 1; }
grep -q "^UPDATE|15|Closes #10" "${REPORT}" || { echo "FAIL: linked-issue body was not derived"; exit 1; }
echo "ensure_pr links issue -> Closes #n body: passed"

# Reuse path over an existing PR also derives the body.
reset_body_marker
# shellcheck disable=SC2329
# shellcheck disable=SC2317
gh_api_find_pr_by_head() { printf '%s\n' "42"; }
out="$(ensure_pr "nahcnuj" "conahcnuj" "" "conahcnuj/10-x" "main" "Fix something" "issue body" "10")"
[[ "${out}" == "42" ]] || { echo "FAIL: reuse output was '${out}' (expected 42)"; exit 1; }
[[ "$(grep -c '^UPDATE|' "${REPORT}")" == "1" ]] || { echo "FAIL: reuse path must sync the body exactly once"; exit 1; }
grep -q "^UPDATE|42|Closes #10" "${REPORT}" || { echo "FAIL: reuse path did not derive the Closes #n body"; exit 1; }
echo "ensure_pr reuses existing PR and syncs body: passed"

# No linked issue: body must stay verbatim and NO PATCH may be issued.
reset_body_marker
# shellcheck disable=SC2329
# shellcheck disable=SC2317
gh_api_find_pr_by_head() { printf '%s\n' ""; }
# shellcheck disable=SC2329
gh_api_create_pr() { printf '%s\n' "77"; }
out="$(ensure_pr "nahcnuj" "conahcnuj" "" "conahcnuj/10-x" "main" "Fix something" "hand-written body" "")"
[[ "${out}" == "77" ]] || { echo "FAIL: no-issue create output was '${out}' (expected 77)"; exit 1; }
[[ "$(grep -c '^UPDATE|' "${REPORT}")" == "0" ]] || { echo "FAIL: no-issue path must not PATCH the PR body"; exit 1; }

reset_body_marker
out="$(ensure_pr "nahcnuj" "conahcnuj" "15" "feature/fix-10" "main" "Fix something" "hand-written body" "")"
[[ "${out}" == "15" ]] || { echo "FAIL: no-issue resume output was '${out}' (expected 15)"; exit 1; }
[[ "$(grep -c '^UPDATE|' "${REPORT}")" == "0" ]] || { echo "FAIL: no-issue resume must not PATCH the PR body"; exit 1; }
echo "ensure_pr keeps no-issue PR body verbatim (no bogus 'Closes #'): passed"

gh_api_post_comment() {
  printf 'COMMENT|%s|%s\n' "${3}" "$(printf '%s' "${4}" | tr '\n' ' ')" >> "${REPORT}"
}
post_pr_continuation_comment "nahcnuj" "conahcnuj" "123"
grep -q '^COMMENT|123|.*conahcnuj-continuation.*再実行してください.*gh workflow run issue-driver.yml -f number=123 -R nahcnuj/conahcnuj' "${REPORT}" || { echo "FAIL: continuation comment was not posted with the workflow-run command"; exit 1; }
grep -q '^COMMENT|123|.*actions/workflows/issue-driver.yml) を開き' "${REPORT}" || { echo "FAIL: continuation comment must link to the workflow run-history page"; exit 1; }
grep -q 'issue-driver.yml/dispatch' "${REPORT}" && { echo "FAIL: continuation comment must not embed the prefilled <file>/dispatch page (it 404s with \"This workflow does not exist\" even for a workflow registered on the default branch)"; exit 1; }

echo "All ensure_pr body tests passed"