#!/usr/bin/env bash
# migrate-bug-reports.sh offline test (no secrets, no network).
#
# Feeds the migration script a mocked API tape: one old bug-report issue
# (re-posted as a reply to an existing thread), one pull request and one
# ordinary issue (both skipped). Asserts the report lands in the discussion,
# the source issue gets a pointer comment and is closed, and --dry-run posts
# nothing.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
SCRIPT="${REPO}/bin/migrate-bug-reports.sh"

export GH_API_TEST_MODE=1

MOCK_CATEGORIES='{"data":{"repository":{"id":"R_kgDOXmplR3p","discussionCategories":{"nodes":[{"id":"DIC_kwDOBBBBBB","name":"Bug report","slug":"bug-report"}]}}}}'
MOCK_THREADS='{"data":{"repository":{"discussions":{"nodes":[{"number":7,"id":"D_kwDOCcCCCCC","title":"conahcnuj: failed to resolve #13","url":"https://github.com/nahcnuj/conahcnuj/discussions/7"}]}}}}'

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT

# --- live run ---------------------------------------------------------------
# Tape, in call order: issue list, fetch #25 (old bug report), category +
# threads (find the existing thread), reply, issue comment, issue close,
# fetch #26 (a PR, skipped), fetch #27 (an ordinary issue, skipped).
TAPE="${ROOT}/tape.txt"
{
  printf '%s\n' '[{"number":25},{"number":26},{"number":27}]'
  printf '%s\n' '{"number": 25, "title": "conahcnuj: failed to resolve #13 (exit 1)", "body": "old report body", "labels": [], "state": "open"}'
  printf '%s\n' "${MOCK_CATEGORIES}"
  printf '%s\n' "${MOCK_THREADS}"
  printf '%s\n' '{"data":{"addDiscussionComment":{"comment":{"id":"DC_kwDOEeEEEEE"}}}}'
  printf '%s\n' '{"id":777}'
  printf '%s\n' '{}'
  printf '%s\n' '{"number": 26, "title": "conahcnuj: failed to resolve #13 (exit 1)", "body": "x", "pull_request": {}}'
  printf '%s\n' '{"number": 27, "title": "Some ordinary feature request", "body": "y", "labels": [], "state": "open"}'
} > "${TAPE}"

LOG="${ROOT}/run.log"
bash "${SCRIPT}" nahcnuj/conahcnuj < "${TAPE}" > "${LOG}" 2>&1
echo "----- migrate live run log -----"
cat "${LOG}"
echo "--------------------------------"

grep -q "#25 conahcnuj: failed to resolve #13 (exit 1)" "${LOG}" || { echo "FAIL: the old bug report was not picked up"; exit 1; }
grep -q "appended to discussion #7" "${LOG}" || { echo "FAIL: the report was not appended to the existing thread"; exit 1; }
grep -q "Moved: 1, failed: 0" "${LOG}" || { echo "FAIL: wrong migration summary"; exit 1; }
# The PR (#26) and the ordinary issue (#27) must be left alone: no second move.
grep -q "#26" "${LOG}" && { echo "FAIL: the pull request was touched"; exit 1; }
grep -q "#27" "${LOG}" && { echo "FAIL: the ordinary issue was touched"; exit 1; }

# --- dry run ----------------------------------------------------------------
# Tape: only the listing and the fetches are needed; nothing may be posted.
DRY_TAPE="${ROOT}/dry-tape.txt"
{
  printf '%s\n' '[{"number":25}]'
  printf '%s\n' '{"number": 25, "title": "conahcnuj: failed to resolve #13 (exit 1)", "body": "old report body", "labels": [], "state": "open"}'
} > "${DRY_TAPE}"

DRY_LOG="${ROOT}/dry.log"
bash "${SCRIPT}" nahcnuj/conahcnuj --dry-run < "${DRY_TAPE}" > "${DRY_LOG}" 2>&1
echo "----- migrate dry run log -----"
cat "${DRY_LOG}"
echo "-------------------------------"

grep -q "dry run (nothing is posted" "${DRY_LOG}" || { echo "FAIL: dry run was not announced"; exit 1; }
grep -q 'would post "conahcnuj: failed to resolve #13"' "${DRY_LOG}" || { echo "FAIL: dry run did not preview the thread title"; exit 1; }
grep -q "Moved: 1, failed: 0" "${DRY_LOG}" || { echo "FAIL: wrong dry-run summary"; exit 1; }
grep -qE "appended to discussion|created discussion" "${DRY_LOG}" && { echo "FAIL: dry run posted something"; exit 1; }

echo "migrate-bug-reports passed"
