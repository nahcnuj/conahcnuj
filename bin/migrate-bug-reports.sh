#!/usr/bin/env bash
# One-off migration (issue #126): move the driver's old auto-filed bug-report
# issues into the repository's "Bug report" Discussions category. Each issue
# whose title starts with "conahcnuj:" is re-posted to that category (a
# same-title discussion already there gets a comment, via file_bug_report),
# and a pointer comment is left on the original issue.
#
# Usage: bin/migrate-bug-reports.sh [owner repo]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CONAHCNUJ_IMPORT=1
# shellcheck source=bin/conahcnuj.sh
. "${HERE}/conahcnuj.sh"

owner="${1:-nahcnuj}"
repo="${2:-conahcnuj}"

list="$(gh_api_list_bug_report_issues "${owner}" "${repo}")"
if [[ -z "${list}" ]]; then
  echo "No bug-report issues to migrate."
  exit 0
fi

# fd 3 carries the work list: the API helpers read their mocked tape (in
# GH_API_TEST_MODE) or any piped input from stdin, so the list must not share
# that channel.
while IFS='|' read -r num title_b64 body_b64 html_url <&3; do
  [[ -n "${num}" ]] || continue
  title="$(gh_api_unb64 "${title_b64}")"
  body="$(gh_api_unb64 "${body_b64}")"
  echo "Migrating bug-report issue #${num}: ${title}" >&2
  kind="" num2="" url=""
  read -r kind num2 url < <(file_bug_report "${owner}" "${repo}" "${title}" "${body}") || true
  if [[ -z "${num2}" ]]; then
    echo "WARNING: could not re-post issue #${num} to Discussions; leaving it untouched." >&2
    continue
  fi
  echo "Re-posted as ${kind} #${num2}: ${url}" >&2
  if [[ -n "${html_url}" ]]; then
    gh_api_post_comment "${owner}" "${repo}" "${num}" "このエラー報告は Discussions の Bug report カテゴリへ移行されました: ${url}" >/dev/null || true
  fi
done 3<<<"${list}"
