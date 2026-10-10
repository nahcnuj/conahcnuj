#!/usr/bin/env bash
# TODO.md progress-file lifecycle test (offline).
#
# The per-issue progress file TODO.md gates the pull request's draft state: the
# coding agent creates it when it starts an issue, updates it as work proceeds
# and deletes it once the issue is resolved and ready to hand over. While the
# file is present the driver creates the PR as a draft and never requests
# review; only once the file is gone does it mark the PR ready and hand it over.
# This is what keeps an unfinished issue (TODO.md still present) from being
# presented as a non-draft, ready pull request.
#
# Driven end to end against the mocked API tape and the mocked opencode. The
# mock's first round creates TODO.md; its next round deletes it (an agent that
# starts an issue, then finishes and cleans up).
#
# No secrets, no network.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
DRIVER="${REPO}/bin/conahcnuj.sh"

# --- gh_api_create_pr carries the draft flag into the mutation (direct) -----
# Test mode hides the GraphQL query, so stub gh_api_graphql to inspect it.
QUERY_REPORT="$(mktemp)"
trap 'rm -f "${QUERY_REPORT}"' EXIT
(  # subshell: sourcing gh-api.sh must not leak into the run below
  # shellcheck source=lib/gh-api.sh
  . "${REPO}/lib/gh-api.sh"
  gh_api_graphql() {
    local q="${1}"
    if [[ "${q}" == *createPullRequest* ]]; then
      printf '%s\n' "${q}" >> "${QUERY_REPORT}"
      printf '%s\n' '{"data":{"createPullRequest":{"pullRequest":{"number":321}}}}'
    else
      printf '%s\n' '{"data":{"repository":{"id":"R_x"}}}'
    fi
  }
  gh_api_create_pr "o" "r" "T" "B" "head" "base" true >/dev/null
  gh_api_create_pr "o" "r" "T" "B" "head" "base" false >/dev/null
)
grep -q 'draft: true' "${QUERY_REPORT}" || { echo "FAIL: draft PR creation did not put draft: true in the mutation"; exit 1; }
[[ "$(grep -c 'draft: true' "${QUERY_REPORT}")" == "1" ]] || { echo "FAIL: only the draft creation may set draft: true"; exit 1; }
echo "gh_api_create_pr honors the draft flag: passed"

# --- gh_api_convert_pr_to_draft issues the conversion mutation (direct) -----
(
  # shellcheck source=lib/gh-api.sh
  . "${REPO}/lib/gh-api.sh"
  gh_api_graphql() {
    local q="${1}"
    if [[ "${q}" == *convertPullRequestToDraft* ]]; then
      printf '%s\n' "${q}" >> "${QUERY_REPORT}"
      printf '%s\n' '{"data":{"convertPullRequestToDraft":{"pullRequest":{"isDraft":true}}}}'
    else
      printf '%s\n' '{"data":{"repository":{"pullRequest":{"id":"PR_x"}}}}'
    fi
  }
  gh_api_convert_pr_to_draft "o" "r" "321"
)
grep -q 'convertPullRequestToDraft' "${QUERY_REPORT}" || { echo "FAIL: convert-to-draft did not issue the conversion mutation"; exit 1; }
echo "gh_api_convert_pr_to_draft issues the mutation: passed"

# --- full run: TODO.md present -> draft PR; deleted -> ready + review -------
ROOT="$(mktemp -d)"
WORK="${ROOT}/repo"
trap 'rm -f "${QUERY_REPORT}"; rm -rf "${ROOT}"' EXIT
mkdir -p "${WORK}"

git -C "${WORK}" init -q
git -C "${WORK}" config user.email "test@example.com"
git -C "${WORK}" config user.name "test"
git -C "${WORK}" config commit.gpgsign false
printf 'base\n' > "${WORK}/file.txt"
printf '# Guide\nTODO fixture README\n' > "${WORK}/README.md"
git -C "${WORK}" add -A
git -C "${WORK}" commit -qm init

# One JSON document per GitHub API call, in call order:
#   fetch_issue, get_repo, find_pr_by_head_any (empty), find_pr_by_head (empty),
#   create_pr repo-id lookup, create_pr (123) as a draft, continuation comment,
#   body sync PATCH (second loop), ready_for_review (TODO.md gone),
#   fetch_reviews (nothing to act on), request_review, conditions (SUCCESS).
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"number": 10, "title": "TODO.md progress", "body": "# 背景\nTODO.md lifecycle. ", "labels": [], "state": "open"}
{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"data":{"repository":{"id":"R_kgDOXmplR3p"}}}
{"data":{"createPullRequest":{"pullRequest":{"number":123}}}}
{"id":776}
{}
{}
{"data":{"repository":{"pullRequest":{"reviewDecision":"REVIEW_REQUIRED","reviews":{"nodes":[]},"comments":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
{}
{"data":{"repository":{"pullRequest":{"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}}}}}
EOF

export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export MOCK_OPENCODE_MODELS="opencode/a"
# The mock writes TODO.md on its first round and deletes it on the next.
export MOCK_OPENCODE_TODO="opencode/a"
export MOCK_OPENCODE_STATE_DIR="${ROOT}/state"
export CONAHCNUJ_REPO="nahcnuj/conahcnuj"
unset CONAHCNUJ_COMMIT_MODEL CONAHCNUJ_MODEL_LABEL_FILE CONAHCNUJ_SESSION_MODEL \
  CONAHCNUJ_RUN_TIMEOUT_SECONDS OPENCODE_LAST_MODEL

LOG="${ROOT}/run.log"
RC=0
(
  cd "${WORK}"
  CONAHCNUJ_MAX_SECONDS=120 bash "${DRIVER}" 10 < "${TAPE}"
) > "${LOG}" 2>&1 || RC=$?

echo "----- conahcnuj TODO.md run log -----"
cat "${LOG}"
echo "-------------------------------------"

[[ ${RC} -eq 0 ]] || { echo "FAIL: driver exited ${RC} (expected 0)"; exit 1; }
# The PR was opened as a draft because TODO.md was present, and the run never
# requested review while it was.
grep -q "Created draft PR #123" "${LOG}" || { echo "FAIL: the PR was not created as a draft while TODO.md existed"; exit 1; }
grep -q "TODO.md is still present; the issue is not finished. Keeping PR #123 a draft and continuing the work." "${LOG}" || { echo "FAIL: the driver did not keep working while TODO.md was present"; exit 1; }
grep -q "TODO.md is gone; marking PR #123 ready for review." "${LOG}" || { echo "FAIL: the driver did not mark the PR ready after TODO.md was deleted"; exit 1; }
# Ordering: draft creation -> ready -> review hand-off. No review request may
# precede the ready transition.
DRAFT_LINE="$(grep -n "Created draft PR #123" "${LOG}" | head -1 | cut -d: -f1)"
READY_LINE="$(grep -n "TODO.md is gone; marking PR #123 ready for review." "${LOG}" | head -1 | cut -d: -f1)"
ASSIGNED_LINE="$(grep -n "Assigned nahcnuj as reviewer on PR #123" "${LOG}" | head -1 | cut -d: -f1)"
[[ -n "${DRAFT_LINE}" && -n "${READY_LINE}" && "${DRAFT_LINE}" -lt "${READY_LINE}" ]] || { echo "FAIL: the draft must be created before it is made ready"; exit 1; }
[[ -n "${ASSIGNED_LINE}" && "${READY_LINE}" -lt "${ASSIGNED_LINE}" ]] || { echo "FAIL: the review request must come after the PR is made ready"; exit 1; }

# TODO.md is gone from the branch head once the run hands the PR over.
[[ ! -f "${WORK}/TODO.md" ]] || { echo "FAIL: TODO.md must be deleted from the working tree"; exit 1; }
if git -C "${WORK}" cat-file -e "HEAD:TODO.md" 2>/dev/null; then
  echo "FAIL: TODO.md must not exist at the handed-over branch head"; exit 1
fi
# init + first round (creates TODO.md) + finishing round (deletes it).
[[ "$(git -C "${WORK}" log --oneline | wc -l)" == "3" ]] || { echo "FAIL: expected init + start + finish commits"; exit 1; }

echo "conahcnuj TODO.md lifecycle passed"
