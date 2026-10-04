#!/usr/bin/env bash
# conahcnuj bug-report triage test (offline).
#
# A bug-report discussion triggers a triage run: the driver reads the report,
# has the coding agent investigate it, and turns the verdict into either an
# issue (which the normal driver flow then resolves) or a reply on the thread.
# This exercises the real bin/conahcnuj.sh against a mocked GitHub API tape (one
# JSON per API call, in call order) and a mocked opencode, in a throwaway git
# repository:
#
#   discussion #7 read -> investigate -> issue #42 filed -> reply on the
#   discussion -> exit 0
#
# and the branches around it: a report that is already triaged, a discussion in
# another category, a verdict that needs no issue, and a triage run that fails
# (its bug report must land in a number-free thread so a repeat cannot fire the
# discussion trigger again).
#
# No secrets, no network.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
DRIVER="${REPO}/bin/conahcnuj.sh"

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT

MOCK_CATEGORIES='{"data":{"repository":{"id":"R_kgDOXmplR3p","discussionCategories":{"nodes":[{"id":"DIC_kwDOBBBBBB","name":"Bug report","slug":"bug-report"}]}}}}'
MOCK_REPLY='{"data":{"addDiscussionComment":{"comment":{"id":"DC_kwDOEeEEEEE"}}}}'

# One bug report in the Bug report category, never triaged.
mock_discussion() {
  local number="${1:-7}" category="${2:-Bug report}" id="${3:-D_kwDOCcCCCCC}" comments="${4:-[]}"
  printf '{"data":{"repository":{"discussion":{"number":%s,"id":"%s","title":"conahcnuj: failed to resolve #14","url":"https://github.com/nahcnuj/conahcnuj/discussions/%s","category":{"name":"%s"},"comments(first:100)":{"nodes":%s},"body":"## Error log\\n\\nERROR: no available model completed the work\\n"}}}}' \
    "${number}" "${id}" "${number}" "${category}" "${comments}"
}

export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export MOCK_OPENCODE_MODELS="opencode/first
opencode/second"
export CONAHCNUJ_REPO="nahcnuj/conahcnuj"

# A wrapping agent session (the conahcnuj opencode plugin) exports these for real
# runs; a triage run must not pick them up.
unset CONAHCNUJ_COMMIT_MODEL CONAHCNUJ_MODEL_LABEL_FILE CONAHCNUJ_SESSION_MODEL \
  CONAHCNUJ_RUN_TIMEOUT_SECONDS OPENCODE_LAST_MODEL MOCK_OPENCODE_TRIAGE_FILE

# Run the driver in a fresh repository and return "<exit code>\n<log>".
# Args: triage-file tape-lines...
run_driver() {
  local verdict="${1}" log rc=0
  shift
  local work tape
  work="$(mktemp -d "${ROOT}/work.XXXXXX")"
  tape="${work}.tape"
  git -C "${work}" init -q
  git -C "${work}" config user.email "test@example.com"
  git -C "${work}" config user.name "test"
  git -C "${work}" config commit.gpgsign false
  printf 'base\n' > "${work}/file.txt"
  git -C "${work}" add -A
  git -C "${work}" commit -qm init
  {
    local line
    for line in "$@"; do
      printf '%s\n' "${line}"
    done
  } > "${tape}"
  log="${work}.log"
  (
    cd "${work}"
    MOCK_OPENCODE_TRIAGE_FILE="${verdict}" CONAHCNUJ_MAX_SECONDS=120 \
      bash "${DRIVER}" --discussion 7 < "${tape}"
  ) > "${log}" 2>&1 || rc=$?
  printf 'exit=%s\n' "${rc}"
  cat "${log}"
}

# --- a real defect becomes an issue the driver can resolve -------------------
OUT="$(run_driver ".triage-issue" \
  "$(mock_discussion)" \
  '{"number":42,"html_url":"https://github.com/nahcnuj/conahcnuj/issues/42"}' \
  "${MOCK_REPLY}")"
echo "----- triage (files an issue) -----"
printf '%s\n' "${OUT}"
echo "----------------------------------"

grep -q "^exit=0$" <<<"${OUT}" || { echo "FAIL: triage did not exit 0"; exit 1; }
grep -q "Discussion #7: conahcnuj: failed to resolve #14" <<<"${OUT}" || { echo "FAIL: the report was not read"; exit 1; }
grep -q "Filed issue #42 for discussion #7: https://github.com/nahcnuj/conahcnuj/issues/42" <<<"${OUT}" || { echo "FAIL: the issue was not filed"; exit 1; }
grep -q "Replied on discussion #7 with the issue link" <<<"${OUT}" || { echo "FAIL: no reply on the thread"; exit 1; }
grep -q "Model opencode/first completed the investigation" <<<"${OUT}" || { echo "FAIL: the investigating model was not reported"; exit 1; }
grep -q "already triaged" <<<"${OUT}" && { echo "FAIL: a fresh thread was treated as triaged"; exit 1; }

# --- a report that needs no issue only gets the verdict ---------------------
OUT="$(run_driver ".triage-verdict" \
  "$(mock_discussion 7 'Bug report' D_kwDOCcCCCCC)" \
  "${MOCK_REPLY}")"
echo "----- triage (files no issue) -----"
printf '%s\n' "${OUT}"
echo "---------------------------------"

grep -q "^exit=0$" <<<"${OUT}" || { echo "FAIL: a verdict-only triage did not exit 0"; exit 1; }
grep -q "Verdict for discussion #7: not-a-bug (no issue filed)" <<<"${OUT}" || { echo "FAIL: the verdict was not reported"; exit 1; }
grep -q "Replied on discussion #7 with the verdict" <<<"${OUT}" || { echo "FAIL: no verdict reply on the thread"; exit 1; }
grep -qE "Filed issue #[0-9]+" <<<"${OUT}" && { echo "FAIL: an issue was filed for a verdict-only report"; exit 1; }

# --- a thread that was already triaged is left alone ------------------------
OUT="$(run_driver ".triage-issue" \
  "$(mock_discussion 7 'Bug report' D_kwDOCcCCCCC '[{"body":"<!-- conahcnuj:triage issue=42 -->\nTracked as #42."}]')" \
  '{"number":43,"html_url":"https://github.com/nahcnuj/conahcnuj/issues/43"}')"
echo "----- triage (already triaged) -----"
printf '%s\n' "${OUT}"
echo "------------------------------------"

grep -q "^exit=0$" <<<"${OUT}" || { echo "FAIL: re-triaging a thread did not exit 0"; exit 1; }
grep -q "Discussion #7 was already triaged into issue #42; nothing to do" <<<"${OUT}" || { echo "FAIL: the triaged thread was not detected"; exit 1; }
grep -q "Investigating the report" <<<"${OUT}" && { echo "FAIL: an already triaged thread was investigated again"; exit 1; }
grep -q "Filed issue" <<<"${OUT}" && { echo "FAIL: a second issue was filed for one report"; exit 1; }

# --- a discussion outside the bug report category is not triaged -------------
OUT="$(run_driver ".triage-issue" \
  "$(mock_discussion 7 'General')" \
  '{"number":44,"html_url":"https://github.com/nahcnuj/conahcnuj/issues/44"}')"
echo "----- triage (wrong category) -----"
printf '%s\n' "${OUT}"
echo "------------------------------------"

grep -q "^exit=0$" <<<"${OUT}" || { echo "FAIL: a non-bug-report discussion did not exit 0"; exit 1; }
grep -q "is in the 'General' category, not 'Bug report'; nothing to triage" <<<"${OUT}" || { echo "FAIL: the category check did not refuse the discussion"; exit 1; }
grep -q "Filed issue" <<<"${OUT}" && { echo "FAIL: a question became an issue"; exit 1; }

# --- a triage run that cannot decide files a bug report in a stable thread ---
# The title carries no discussion number on purpose: a second failure appends to
# this thread as a reply, and a reply fires no discussion trigger, so the
# report -> triage -> report chain cannot grow without end.
OUT="$(run_driver "" \
  "$(mock_discussion)" \
  "${MOCK_CATEGORIES}" \
  '{"data":{"repository":{"discussions":{"nodes":[]}}}}' \
  "${MOCK_CATEGORIES}" \
  '{"data":{"createDiscussion":{"discussion":{"number":9,"url":"https://github.com/nahcnuj/conahcnuj/discussions/9"}}}}')"
echo "----- triage (investigation failed) -----"
printf '%s\n' "${OUT}"
echo "--------------------------------------------"

grep -q "^exit=1$" <<<"${OUT}" || { echo "FAIL: a failed investigation did not exit 1"; exit 1; }
grep -q "no available model recorded a triage verdict" <<<"${OUT}" || { echo "FAIL: the missing verdict was not reported"; exit 1; }
grep -q "could not investigate discussion #7" <<<"${OUT}" || { echo "FAIL: the investigation failure was not logged"; exit 1; }
grep -q "Bug report discussion #9 created" <<<"${OUT}" || { echo "FAIL: no bug report was filed"; exit 1; }

# Set once for the whole file: the unit blocks below source the driver, which
# would otherwise run main() on source.
export CONAHCNUJ_IMPORT=1

# --- unit: the triage bug report thread is free of per-run details ----------
# The title is the loop breaker, so it must name no discussion and no number.
(
  unset CONAHCNUJ_REPO
  # shellcheck source=bin/conahcnuj.sh
  source "${DRIVER}"
  BUG_REPORT_KIND="discussion"
  BUG_REPORT_INPUT=""
  [[ "$(report_bug_title 7)" == "conahcnuj: failed to triage a bug report discussion" ]] || exit 1
  [[ "$(report_bug_title 7)" == "$(report_bug_title 8)" ]] || exit 1
  [[ "$(report_bug_title 7)" != *"7"* ]] || exit 1
  BUG_REPORT_KIND="issue"
  [[ "$(report_bug_title 14)" == "conahcnuj: failed to resolve #14" ]] || exit 1
) || { echo "FAIL: the triage bug report title must not carry per-run details"; exit 1; }

# --- unit: the bug report body names the discussion under investigation -----
(
  unset CONAHCNUJ_REPO
  # shellcheck source=bin/conahcnuj.sh
  source "${DRIVER}"
  RUN_LOG_FILE="$(mktemp)"
  printf 'no available model recorded a triage verdict\n' > "${RUN_LOG_FILE}"
  BUG_REPORT_KIND="discussion"
  BUG_REPORT_INPUT=""
  BUG_REPORT_DISCUSSION="7"
  body="$(report_bug_body 1 "nahcnuj" "conahcnuj" "" "main" "abc1234" "first")"
  grep -q "bug report discussion #7" <<<"${body}" || exit 1
  grep -q 'conahcnuj --discussion 7' <<<"${body}" || exit 1
  grep -q "no available model recorded a triage verdict" <<<"${body}" || exit 1
  # An issue-driven run keeps its own context.
  BUG_REPORT_KIND="issue"
  BUG_REPORT_INPUT="14"
  body="$(report_bug_body 1 "nahcnuj" "conahcnuj" "14" "main" "abc1234" "first")"
  grep -q "nahcnuj/conahcnuj#14" <<<"${body}" || exit 1
) || { echo "FAIL: the triage bug report body does not describe what the run was doing"; exit 1; }

# --- unit: the filed issue is marked as triaged work -----------------------
# The driver prefixes the title (issue-driver.yml drives bot issues under this
# prefix only) and states where the report came from, so an issue nobody
# expected can be traced back to the thread that produced it.
(
  unset CONAHCNUJ_REPO
  WORK="${ROOT}/unit"
  mkdir -p "${WORK}"
  cd "${WORK}"
  # shellcheck source=bin/conahcnuj.sh
  source "${DRIVER}"
  BUG_REPORT_KIND="discussion"
  OPENCODE_LAST_MODEL="opencode/first"
  gh_api_fetch_discussion() {
    printf '%s|%s|%s|%s|%s|%s\n' \
      "$(printf 'conahcnuj: failed to resolve #14' | gh_api_b64)" \
      "$(printf 'the report body' | gh_api_b64)" \
      "https://github.com/nahcnuj/conahcnuj/discussions/7" \
      "Bug report" "D_kwDOCcCCCCC" "0"
  }
  gh_api_create_issue() {
    printf '%s\n' "${3}" > "${ROOT}/captured-issue-title.txt"
    printf '%s\n' "${4}" > "${ROOT}/captured-issue-body.txt"
    printf '42\n'
  }
  gh_api_reply_discussion() {
    printf '%s\n' "${4}" > "${ROOT}/captured-reply-body.txt"
    printf 'DC_kwDOEeEEEEE\n'
  }
  opencode_get_models() { printf 'opencode/first\n'; }
  opencode_run() {
    printf 'the investigation found a real defect\n\nroot cause: the fixture\n' > "${WORK}/.triage-issue"
  }
  (triage_discussion "nahcnuj" "conahcnuj" "7") || exit 1
)
grep -q "^conahcnuj-triage: the investigation found a real defect" "${ROOT}/captured-issue-title.txt" || {
  echo "FAIL: the filed issue is not marked as triaged work"; exit 1; }
grep -q "root cause: the fixture" "${ROOT}/captured-issue-body.txt" || {
  echo "FAIL: the investigation is missing from the issue body"; exit 1; }
grep -q "https://github.com/nahcnuj/conahcnuj/discussions/7" "${ROOT}/captured-issue-body.txt" || {
  echo "FAIL: the issue body does not link back to the report"; exit 1; }
grep -q "<!-- conahcnuj:triage issue=42 -->" "${ROOT}/captured-reply-body.txt" || {
  echo "FAIL: the reply has no triage marker, so a re-run would file a second issue"; exit 1; }
[[ ! -e "${ROOT}/unit/.triage-issue" ]] || { echo "FAIL: the verdict file was left in the work tree"; exit 1; }

echo "conahcnuj discussion triage passed"