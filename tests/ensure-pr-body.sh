#!/usr/bin/env bash
# PR description composition test (offline).
#
# Covers the "PR body is null" regression: a PR whose body the API reports as
# null used to end up literally reading "Closes #n\n\nnull", which no reviewer
# can use. The description must come from the coding agent (.pr-body) and never
# be empty:
#
#   * with a linked issue: "Closes #<n>\n\n<description>" is derived and synced
#   * a resumed PR with no linked issue keeps its own body verbatim (no bogus
#     "Closes #", no PATCH)
#   * the agent's .pr-body wins over the issue text and never gets committed
#   * a null / empty issue or PR body falls back to the title
#   * the same description is published only once (no PATCH per poll)
#
# Sources bin/conahcnuj.sh via CONAHCNUJ_IMPORT=1 (main() must not run) and
# stubs gh_api_update_pr / gh_api_find_pr_by_head / gh_api_create_pr so the
# description is observable without any network I/O. ensure_pr runs in a
# command-substitution subshell (an in-subshell variable set would vanish), so
# the stubs append their reports to a file outside the subshell.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

export CONAHCNUJ_IMPORT=1
# shellcheck source=bin/conahcnuj.sh
. "${REPO}/bin/conahcnuj.sh"

REPORT="$(mktemp)"
WORKDIR="$(mktemp -d)"
trap 'rm -f "${REPORT}"; rm -rf "${WORKDIR}"' EXIT

# Stubs that report what would go over the wire instead of calling the API.
gh_api_update_pr() {
  printf 'UPDATE|%s|%s\n' "${3}" "${4}" >> "${REPORT}"
}
gh_api_create_pr() {
  printf 'CREATE|%s|%s\n' "${3}" "${4}" >> "${REPORT}"
  printf '%s\n' "77"
}
gh_api_find_pr_by_head() {
  printf '%s\n' ""
}

# ensure_pr publishes the description at most once per distinct body
# (PR_BODY_PUBLISHED_FILE) and the report file accumulates otherwise, so reset
# the published body, the captured .pr-body and the report between scenarios.
reset_pr_body_state() {
  rm -f "${PR_BODY_PUBLISHED_FILE}" "${AGENT_PR_BODY_FILE}" "${WORKDIR}/.pr-body"
  : > "${REPORT}"
}

# The coding agent writes .pr-body into the work tree; the driver must take it
# out of the tree and remember it outside.
write_agent_pr_body() {
  printf '%s\n' "${1}" > "${WORKDIR}/.pr-body"
}

count_report() {
  printf '%s\n' "$(grep -c "^${1}|" "${REPORT}")"
}

# --- gh_api_json_text: a null body must not survive as the text "null" --------

reset_pr_body_state
printf '{"body":null}' > "${WORKDIR}/null.json"
[[ "$(gh_api_json_text "$(cat "${WORKDIR}/null.json")" "body")" == "" ]] || { echo "FAIL: a JSON null body must read as empty, not 'null'"; exit 1; }
printf '{"body":""}' > "${WORKDIR}/empty.json"
[[ "$(gh_api_json_text "$(cat "${WORKDIR}/empty.json")" "body")" == "" ]] || { echo "FAIL: an empty JSON string body must read as empty"; exit 1; }
printf '{"body":"# real"}' > "${WORKDIR}/real.json"
[[ "$(gh_api_json_text "$(cat "${WORKDIR}/real.json")" "body")" == "# real" ]] || { echo "FAIL: a real body must be returned unchanged"; exit 1; }
rm -f "${WORKDIR}"/*.json
echo "gh_api_json_text (null / empty / real body): passed"

# --- pr_body_clean: the literal "null" is never a description ----------------

reset_pr_body_state
[[ "$(pr_body_clean "null")" == "" ]] || { echo "FAIL: pr_body_clean must drop the literal 'null'"; exit 1; }
[[ "$(pr_body_clean '""')" == "" ]] || { echo "FAIL: pr_body_clean must drop a bare '\"\"' body"; exit 1; }
[[ "$(pr_body_clean $'# title\r\n\r\n')" == "# title" ]] || { echo "FAIL: pr_body_clean must strip CR and trailing blank lines"; exit 1; }
echo "pr_body_clean (null / empty / CRLF): passed"

# --- linked issue: the derived description is published once ------------------

reset_pr_body_state
out="$(ensure_pr "nahcnuj" "conahcnuj" "15" "feature/fix-10" "main" "Fix something" "real issue body

more" "10")"
[[ "${out}" == "15" ]] || { echo "FAIL: ensure_pr output was '${out}' (expected 15)"; exit 1; }
[[ "$(count_report UPDATE)" == "1" ]] || { echo "FAIL: linked-issue description sync must issue exactly one PATCH"; exit 1; }
grep -q "^UPDATE|15|Closes #10" "${REPORT}" || { echo "FAIL: linked-issue description was not derived"; exit 1; }
echo "ensure_pr links issue -> Closes #n description: passed"

# --- the same description is not re-published on the next poll ---------------

out="$(ensure_pr "nahcnuj" "conahcnuj" "15" "feature/fix-10" "main" "Fix something" "real issue body

more" "10")"
[[ "$(count_report UPDATE)" == "1" ]] || { echo "FAIL: an unchanged description must not be PATCHed again"; exit 1; }
echo "ensure_pr does not re-publish an unchanged description: passed"

# --- the coding agent's .pr-body wins, and never reaches a commit ------------

reset_pr_body_state
write_agent_pr_body "## What changed

adds the PR description contract"
capture_agent_pr_body "${WORKDIR}"
[[ ! -f "${WORKDIR}/.pr-body" ]] || { echo "FAIL: .pr-body must be taken out of the work tree"; exit 1; }
out="$(ensure_pr "nahcnuj" "conahcnuj" "15" "feature/fix-10" "main" "Fix something" "issue body" "10")"
[[ "${out}" == "15" ]] || { echo "FAIL: ensure_pr output was '${out}' (expected 15)"; exit 1; }
grep -q "^UPDATE|15|Closes #10" "${REPORT}" || { echo "FAIL: the agent's description was not published"; exit 1; }
grep -q "adds the PR description contract" "${REPORT}" || { echo "FAIL: the agent's .pr-body did not reach the PR"; exit 1; }
[[ "$(grep -c "issue body" "${REPORT}")" == "0" ]] || { echo "FAIL: the agent's .pr-body must win over the issue text"; exit 1; }

reset_pr_body_state
write_agent_pr_body "## What changed

agent description for a new PR"
capture_agent_pr_body "${WORKDIR}"
out="$(ensure_pr "nahcnuj" "conahcnuj" "" "conahcnuj/10-x" "main" "Fix something" "issue body" "10")"
[[ "${out}" == "77" ]] || { echo "FAIL: create output was '${out}' (expected 77)"; exit 1; }
grep -q "^CREATE|Fix something|Closes #10" "${REPORT}" || { echo "FAIL: the new PR was not created with the Closes #n description"; exit 1; }
grep -q "agent description for a new PR" "${REPORT}" || { echo "FAIL: the new PR was not created with the agent's description"; exit 1; }
echo "ensure_pr publishes the coding agent's .pr-body: passed"

# --- a blank .pr-body is dropped, not published ------------------------------

reset_pr_body_state
write_agent_pr_body "   "
capture_agent_pr_body "${WORKDIR}" 2>/dev/null
[[ -z "$(agent_pr_body)" ]] || { echo "FAIL: a blank .pr-body must not be kept"; exit 1; }
echo "capture_agent_pr_body (blank description): passed"

# --- null / empty bodies fall back to the title, never to "null" -------------

reset_pr_body_state
out="$(ensure_pr "nahcnuj" "conahcnuj" "15" "feature/fix-10" "main" "Fix something" "null" "10")"
[[ "${out}" == "15" ]] || { echo "FAIL: ensure_pr output was '${out}' (expected 15)"; exit 1; }
grep -q "^UPDATE|15|Closes #10" "${REPORT}" || { echo "FAIL: the closing line was not published"; exit 1; }
grep -q "null" "${REPORT}" && { echo "FAIL: the literal 'null' leaked into the PR description"; exit 1; }
grep -q "Fix something" "${REPORT}" || { echo "FAIL: a null body must fall back to the title"; exit 1; }

reset_pr_body_state
out="$(ensure_pr "nahcnuj" "conahcnuj" "" "conahcnuj/10-x" "main" "Fix something" "" "10")"
grep -q "^CREATE|Fix something|Closes #10" "${REPORT}" || { echo "FAIL: an empty issue body must still yield a described PR"; exit 1; }
grep -q "null" "${REPORT}" && { echo "FAIL: the literal 'null' leaked into a new PR description"; exit 1; }
echo "ensure_pr falls back to the title instead of 'null': passed"

# --- a resumed PR with no linked issue keeps its own description -------------

reset_pr_body_state
out="$(ensure_pr "nahcnuj" "conahcnuj" "" "conahcnuj/10-x" "main" "Fix something" "hand-written body" "")"
[[ "${out}" == "77" ]] || { echo "FAIL: no-issue create output was '${out}' (expected 77)"; exit 1; }
grep -q "^CREATE|Fix something|hand-written body$" "${REPORT}" || { echo "FAIL: a no-issue PR must keep its description verbatim"; exit 1; }
[[ "$(count_report UPDATE)" == "0" ]] || { echo "FAIL: no-issue path must not PATCH the PR description"; exit 1; }

reset_pr_body_state
out="$(ensure_pr "nahcnuj" "conahcnuj" "15" "feature/fix-10" "main" "Fix something" "hand-written body" "")"
[[ "${out}" == "15" ]] || { echo "FAIL: no-issue resume output was '${out}' (expected 15)"; exit 1; }
[[ "$(count_report UPDATE)" == "0" ]] || { echo "FAIL: no-issue resume must not PATCH the PR description"; exit 1; }
echo "ensure_pr keeps no-issue PR description verbatim (no bogus 'Closes #'): passed"

# --- an unlinked PR whose description was lost gets one written --------------

reset_pr_body_state
out="$(ensure_pr "nahcnuj" "conahcnuj" "15" "feature/fix-10" "main" "Fix something" "" "")"
[[ "$(count_report UPDATE)" == "1" ]] || { echo "FAIL: a resumed PR with no description must be given one"; exit 1; }
grep -q "^UPDATE|15|Fix something" "${REPORT}" || { echo "FAIL: the resumed PR description was not repaired"; exit 1; }
echo "ensure_pr repairs a resumed PR whose description was lost: passed"

gh_api_post_comment() {
  printf 'COMMENT|%s|%s\n' "${3}" "$(printf '%s' "${4}" | tr '\n' ' ')" >> "${REPORT}"
}
reset_pr_body_state
post_pr_continuation_comment "nahcnuj" "conahcnuj" "123"
grep -q '^COMMENT|123|.*conahcnuj-continuation.*継続するにはこちらをクリック.*actions/workflows/issue-driver.yml/dispatch?inputs%5Bnumber%5D=123' "${REPORT}" || { echo "FAIL: continuation comment was not posted to the PR with a prefilled workflow link"; exit 1; }

echo "All PR description tests passed"