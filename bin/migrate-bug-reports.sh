#!/usr/bin/env bash
# migrate-bug-reports.sh - move the driver's historical bug-report issues into
# the "Bug report" discussion category.
#
# The driver used to file a bug report as an issue (conahcnuj:<something>
# (exit N)). It now posts a discussion instead, so an existing report must be
# re-posted there as well. For every issue whose title starts with the old
# prefix this script:
#   1. posts the original report body as a discussion in the category
#      (appending a reply when a thread with the same title already exists,
#      which is what the driver does for repeated failures), with a link back
#      to the source issue
#   2. comments on the source issue with the discussion URL
#   3. closes the source issue as "not planned" (it was moved, not fixed)
#
# The thread title is the old issue title without its " (exit N)" suffix, so it
# matches the title the driver writes today and later failures of the same kind
# land in the migrated thread.
#
# Usage:
#   bash bin/migrate-bug-reports.sh [owner/repo] [--dry-run]
#
# Environment:
#   CONAHCNUJ_REPO                  owner/repo when no argument is given
#   CONAHCNUJ_BUG_REPORT_CATEGORY   discussion category (default: Bug report)
#   GH_APP_DIR                      dir holding app.env (default: ../gh-app)
#
# Writes go through the GitHub App installation token (gh-app/app.env), like
# every other write of this repository, so the App needs the "Discussions"
# permission (read & write) for the migration to succeed. Add --dry-run first to
# see what would be posted without touching anything.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/gh-api.sh
. "${HERE}/../lib/gh-api.sh"

DRY_RUN="0"
ARGS=()
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN="1" ;;
    -*) echo "Unknown option: ${arg}" >&2; exit 1 ;;
    *) ARGS+=("${arg}") ;;
  esac
done

repo_arg="${ARGS[0]:-${CONAHCNUJ_REPO:-}}"
if [[ -z "${repo_arg}" ]]; then
  repo_arg="nahcnuj/conahcnuj"
fi
owner="${repo_arg%%/*}"
repo="${repo_arg#*/}"
if [[ -z "${owner}" || -z "${repo}" || "${repo_arg}" != */* ]]; then
  echo "Usage: $0 [owner/repo] [--dry-run]" >&2
  exit 1
fi

# Title prefix the old bug reports carried.
PREFIX="conahcnuj:"
CATEGORY="${CONAHCNUJ_BUG_REPORT_CATEGORY:-Bug report}"

echo "Repository: ${owner}/${repo}"
echo "Category:   ${CATEGORY}"
if [[ "${DRY_RUN}" == "1" ]]; then
  echo "Mode:       dry run (nothing is posted, commented or closed)"
fi
echo

moved=0
failed=0
numbers="$(gh_api_list_issue_numbers "${owner}" "${repo}")" || {
  echo "ERROR: could not list the issues of ${owner}/${repo}." >&2
  exit 1
}
# A `for` loop (not `while read`, which would redirect stdin): every API call
# below reads the next mocked response from stdin in test mode, and a
# `while ... done <<< ...` loop would steal that stdin for itself.
for number in ${numbers}; do
  [[ -n "${number}" ]] || continue
  issue="$(gh_api_fetch_issue "${owner}" "${repo}" "${number}")"
  title_b64="$(printf '%s' "${issue}" | cut -d'|' -f1)"
  body_b64="$(printf '%s' "${issue}" | cut -d'|' -f2)"
  title="$(gh_api_unb64 "${title_b64}")"
  is_pr="$(printf '%s' "${issue}" | cut -d'|' -f4)"
  # Pull requests share the issue endpoint but are never bug reports.
  if [[ "${is_pr}" == "true" ]]; then
    continue
  fi
  if [[ "${title}" != "${PREFIX}"* ]]; then
    continue
  fi
  body="$(gh_api_unescape "$(gh_api_unb64 "${body_b64}")")"
  thread_title="${title% (exit *)}"
  issue_url="https://github.com/${owner}/${repo}/issues/${number}"
  echo "#${number} ${title}"

  if [[ "${DRY_RUN}" == "1" ]]; then
    echo "  would post \"${thread_title}\" (${#body} bytes of body) and close ${issue_url}"
    moved=$((moved + 1))
    continue
  fi

  post_body="${body}

---

_Moved from ${issue_url} (the driver files bug reports as discussions now)._"

  existing="$(gh_api_find_discussion_by_title "${owner}" "${repo}" "${CATEGORY}" "${thread_title}" || true)"
  if [[ -n "${existing}" ]]; then
    discussion_number="${existing%%|*}"
    discussion_id="$(printf '%s' "${existing}" | cut -d'|' -f2)"
    discussion_url="$(printf '%s' "${existing}" | cut -d'|' -f3)"
    if gh_api_reply_discussion "${owner}" "${repo}" "${discussion_id}" "${post_body}" >/dev/null; then
      echo "  appended to discussion #${discussion_number}"
    else
      echo "  FAILED: could not append to discussion #${discussion_number}" >&2
      failed=$((failed + 1))
      continue
    fi
  else
    created="$(gh_api_create_discussion "${owner}" "${repo}" "${CATEGORY}" "${thread_title}" "${post_body}" || true)"
    if [[ -z "${created}" ]]; then
      echo "  FAILED: could not create a discussion in ${CATEGORY}" >&2
      failed=$((failed + 1))
      continue
    fi
    discussion_number="${created%%|*}"
    discussion_url="${created#*|}"
    echo "  created discussion #${discussion_number}"
  fi

  if gh_api_post_comment "${owner}" "${repo}" "${number}" "This report moved to the Bug report discussion category: ${discussion_url}" >/dev/null; then
    gh_api_close_issue "${owner}" "${repo}" "${number}" "not_planned" || echo "  WARNING: could not close #${number}" >&2
    moved=$((moved + 1))
  else
    echo "  WARNING: could not comment on #${number}" >&2
  fi
done

echo
echo "Moved: ${moved}, failed: ${failed}"
if [[ "${failed}" -gt 0 ]]; then
  exit 1
fi
