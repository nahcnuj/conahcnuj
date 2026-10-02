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
grep -q '^COMMENT|123|.*conahcnuj-continuation.*継続するにはこちらをクリック.*actions/workflows/issue-driver.yml/dispatch?inputs%5Bnumber%5D=123' "${REPORT}" || { echo "FAIL: continuation comment was not posted to the PR with a prefilled workflow link"; exit 1; }

# --- .pr-title / .pr-body (issue #17) ----------------------------------------
# capture_pr_overrides must move the files out of the work tree (they are
# metadata, never part of a commit) and keep their content for ensure_pr.
: > "${PR_TITLE_OVERRIDE_FILE}"
: > "${PR_BODY_OVERRIDE_FILE}"
printf 'feat: agent chosen title\n' > .pr-title
printf 'Why this change is needed.\n\n- point one\n- point two\n' > .pr-body
capture_pr_overrides
[[ ! -e .pr-title && ! -e .pr-body ]] || { echo "FAIL: capture_pr_overrides left metadata in the work tree"; exit 1; }
[[ "$(pr_title_override)" == "feat: agent chosen title" ]] || { echo "FAIL: captured title was '$(pr_title_override)'"; exit 1; }
grep -q 'point two' <(pr_body_override) || { echo "FAIL: captured body lost content"; exit 1; }
# The captured wording must not count as work, or the driver would try to commit
# it. Checked in a throwaway repo so the real work tree's own edits cannot mask it.
meta_repo="$(mktemp -d)"
git -C "${meta_repo}" init -q
printf 'x\n' > "${meta_repo}/tracked.txt"
git -C "${meta_repo}" add -A
git -C "${meta_repo}" -c user.name=t -c user.email=t@example.com commit -qm init
printf 'title\n' > "${meta_repo}/.pr-title"
printf 'body\n' > "${meta_repo}/.pr-body"
if workdir_changed "${meta_repo}"; then
  echo "FAIL: .pr-title / .pr-body must not count as a working-tree change"
  rm -rf "${meta_repo}"
  exit 1
fi
rm -rf "${meta_repo}"
echo "capture_pr_overrides moves PR metadata out of the work tree: passed"

# Creation path: the agent's title and body win over the issue text.
reset_body_marker
# shellcheck disable=SC2329
# shellcheck disable=SC2317
gh_api_find_pr_by_head() { printf '%s\n' ""; }
# shellcheck disable=SC2329
gh_api_create_pr() {
  printf 'CREATE|%s|%s\n' "${3}" "$(printf '%s' "${4}" | tr '\n' ' ')" >> "${REPORT}"
  printf '%s\n' "78"
}
out="$(ensure_pr "nahcnuj" "conahcnuj" "" "conahcnuj/10-x" "main" "issue title" "issue body" "10")"
[[ "${out}" == "78" ]] || { echo "FAIL: override create output was '${out}' (expected 78)"; exit 1; }
# The report collapses newlines to spaces, so match on content, not layout.
grep -q '^CREATE|feat: agent chosen title|' "${REPORT}" || { echo "FAIL: creation ignored .pr-title: $(cat "${REPORT}")"; exit 1; }
grep '^CREATE|' "${REPORT}" | grep -q 'Closes #10.*Why this change is needed.*point two' \
  || { echo "FAIL: creation ignored .pr-body: $(cat "${REPORT}")"; exit 1; }
# A freshly created PR already has the wording, so no PATCH may follow.
[[ "$(grep -c '^UPDATE|' "${REPORT}")" == "0" ]] || { echo "FAIL: creation must not be followed by a PATCH"; exit 1; }
echo "ensure_pr creates the PR with the agent's title and body: passed"

# Existing PR: the wording is PATCHed once, including the title.
reset_body_marker
out="$(ensure_pr "nahcnuj" "conahcnuj" "15" "feature/fix-10" "main" "issue title" "issue body" "10")"
[[ "${out}" == "15" ]] || { echo "FAIL: override resume output was '${out}' (expected 15)"; exit 1; }
[[ "$(grep -c '^UPDATE|' "${REPORT}")" == "1" ]] || { echo "FAIL: resume must PATCH the PR once"; exit 1; }
grep -q 'Why this change is needed' "${REPORT}" || { echo "FAIL: resume did not apply .pr-body"; exit 1; }
echo "ensure_pr applies the agent's wording to an existing PR: passed"

# Without overrides the derived behaviour is unchanged: title = issue title.
: > "${PR_TITLE_OVERRIDE_FILE}"
: > "${PR_BODY_OVERRIDE_FILE}"
reset_body_marker
out="$(ensure_pr "nahcnuj" "conahcnuj" "" "conahcnuj/10-y" "main" "issue title" "issue body" "10")"
grep '^CREATE|' "${REPORT}" | grep -q 'issue title.*Closes #10.*issue body' \
  || { echo "FAIL: without overrides the issue title/body must be used: $(cat "${REPORT}")"; exit 1; }
echo "ensure_pr falls back to the issue title and body: passed"

# An issue with an empty body must not produce a bare "Closes #n" description.
reset_body_marker
out="$(ensure_pr "nahcnuj" "conahcnuj" "" "conahcnuj/10-z" "main" "Linux対応" "" "10")"
grep '^CREATE|' "${REPORT}" | grep -q 'Linux対応.*Closes #10.*Linux対応' \
  || { echo "FAIL: empty issue body must fall back to the issue title: $(cat "${REPORT}")"; exit 1; }
echo "ensure_pr falls back to the issue title for an empty issue body: passed"

echo "All ensure_pr body tests passed"