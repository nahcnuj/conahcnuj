#!/usr/bin/env bash
# conahcnuj - issue-driven autonomous development driver.
#
# Resolves a GitHub issue (or resumes a pull request) end-to-end:
#   1. reads the issue, creates a feature branch off the latest default
#      branch and implements it with opencode (falling through every
#      available model until one produces changes)
#   2. opens a PR, waits until every non-reviewer constraint (CI checks,
#      mergeability) passes, then requests review
#   3. polls the review status; addresses comments / requested changes /
#      security-review threads, pushes and re-verifies non-reviewer
#      constraints, then replies on the PR
#   4. exits only when the PR is ready to merge
#
# Usage: conahcnuj <issue-or-pr-number> [--pr]
#
# Environment overrides (all optional):
#   CONAHCNUJ_REPO           owner/repo when no origin remote is available
#   CONAHCNUJ_MAX_SECONDS    overall time budget (default: 259200 = 72 h)
#   CONAHCNUJ_POLL_CONDITIONS_MIN/MAX  rate-limited poll window (default 15/300 s)
#   CONAHCNUJ_POLL_REVIEWS_MIN/MAX     review poll window (default 30/3600 s)
#   CONAHCNUJ_TEST_MODE=1    offline driver test (mock API tape + mock opencode)
#
# Polling honours GitHub rate limits: API retries wait on Retry-After /
# X-RateLimit-Reset headers (lib/rate-limit.sh), and poll loops sleep with
# jitter within their configured windows.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_MODE="${CONAHCNUJ_TEST_MODE:-0}"

MAX_DURATION="${CONAHCNUJ_MAX_SECONDS:-259200}"
POLL_CONDITIONS_MIN="${CONAHCNUJ_POLL_CONDITIONS_MIN:-15}"
POLL_CONDITIONS_MAX="${CONAHCNUJ_POLL_CONDITIONS_MAX:-300}"
POLL_REVIEWS_MIN="${CONAHCNUJ_POLL_REVIEWS_MIN:-30}"
POLL_REVIEWS_MAX="${CONAHCNUJ_POLL_REVIEWS_MAX:-3600}"
START_TIME="$(date +%s)"

# shellcheck source=lib/rate-limit.sh
. "${HERE}/../lib/rate-limit.sh"
# shellcheck source=lib/gh-api.sh
. "${HERE}/../lib/gh-api.sh"
# shellcheck source=lib/opencode.sh
. "${HERE}/../lib/opencode.sh"

if [[ "${TEST_MODE}" == "1" ]]; then
  # Offline tests must not sleep.
  rate_limit_poll_sleep() { :; }
fi

# Marker file so the PR body sync below runs at most once per driver process.
# A file (not a shell variable) because ensure_pr runs in a command-substitution
# subshell whose variable assignments would not survive back to the caller.
# Lazy existence is not enough (mktemp creates an empty file), so the marker is
# a "1" written into the file. Lives outside the work tree so it is never picked
# up by `git add -A`.
PR_BODY_SYNCED_FILE="${PR_BODY_SYNCED_FILE:-$(mktemp)}"

# True once the per-process PR body sync has already run.
pr_body_synced() {
  [[ "$(cat "${PR_BODY_SYNCED_FILE}" 2>/dev/null || true)" == "1" ]]
}
pr_body_mark_synced() {
  printf '1\n' > "${PR_BODY_SYNCED_FILE}"
}

# --- helpers ----------------------------------------------------------------

repo_detect() {
  if [[ -n "${CONAHCNUJ_REPO:-}" ]]; then
    printf '%s\n' "${CONAHCNUJ_REPO}"
    return 0
  fi
  local url
  url="$(git remote get-url origin 2>/dev/null || true)"
  if [[ -z "${url}" ]]; then
    echo "ERROR: cannot auto-detect owner/repo. Run inside a git work tree with an 'origin' remote, or set CONAHCNUJ_REPO=owner/repo." >&2
    exit 1
  fi
  printf '%s' "${url}" | sed -E 's#.*github\.com[:/]##; s#\.git$##'
}

check_timeout() {
  local now elapsed
  now="$(date +%s)"
  elapsed=$((now - START_TIME))
  if [[ ${elapsed} -ge ${MAX_DURATION} ]]; then
    echo "ERROR: time budget (${MAX_DURATION}s) exhausted while waiting. Exiting." >&2
    exit 1
  fi
}

workdir_changed() {
  local dir="${1}"
  [[ -n "$(git -C "${dir}" status --porcelain 2>/dev/null || true)" ]]
}

# True when the current branch already carries commits on top of the default
# branch, i.e. an earlier run already implemented the issue. Used to skip the
# model fall-through (which would otherwise keep asking every model to do work
# that is already committed) and go straight to opening the PR.
branch_has_commits() {
  local default_branch="${1}" ref count
  ref="${default_branch}"
  if git rev-parse --verify -q "origin/${default_branch}" >/dev/null 2>&1; then
    ref="origin/${default_branch}"
  fi
  count="$(git rev-list --count "${ref}..HEAD" 2>/dev/null || printf '0')"
  [[ "${count}" -gt 0 ]]
}

# Commit every working-tree change as a Verified commit, then sync the local
# branch to the remote head api-commit.sh created. Test mode: plain local
# commit (no network / no secret) so flows can be exercised offline.
commit_changes() {
  local message="${1}"
  echo "Creating commit: ${message}" >&2
  git add -A
  if [[ "${TEST_MODE}" == "1" ]]; then
    git config commit.gpgsign false
    git commit -q -m "${message}" 2>/dev/null || echo "WARNING: nothing to commit (test mode)" >&2
    return 0
  fi
  bash "${HERE}/../gh-app/api-commit.sh" -m "${message}"
  local branch
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  git fetch origin "${branch}" >/dev/null 2>&1 || true
  git reset --hard "origin/${branch}" >/dev/null 2>&1 || true
}

# --- branches ---------------------------------------------------------------

issue_branch_name() {
  local num="${1}" title="${2}" slug
  slug="$(printf '%s' "${title}" | sed 's/[^a-zA-Z0-9]/-/g' | tr -s '-' | sed 's/^-//; s/-$//' | cut -c1-30)"
  [[ -n "${slug}" ]] || slug="issue"
  printf 'conahcnuj/%s-%s\n' "${num}" "${slug}"
}

# Pick the branch name to work on. GitHub only allows one PR per head branch
# (even a closed one), so a derived name that is already spent cannot host a new
# PR. Walk "<branch>", "<branch>-2", "<branch>-3", ... and take the first name
# that either has no PR at all (fresh branch) or has an OPEN PR (resume it).
next_free_branch() {
  local owner="${1}" repo="${2}" branch="${3}" cands cand info state i
  cands=("${branch}")
  for ((i = 2; i < 100; i++)); do
    cands+=("${branch}-${i}")
  done
  for cand in "${cands[@]}"; do
    info="$(gh_api_find_pr_by_head_any "${owner}" "${repo}" "${cand}")"
    if [[ -z "${info}" ]]; then
      printf '%s\n' "${cand}"
      return 0
    fi
    if [[ "${info#*|}" == "OPEN" ]]; then
      printf '%s\n' "${cand}"
      return 0
    fi
  done
  printf '%s\n' "${branch}"
}

# Create (or reuse) the feature branch off the default branch and check it out.
ensure_issue_branch() {
  local owner="${1}" repo="${2}" num="${3}" title="${4}" default_branch="${5}" default_oid="${6}" branch_override="${7:-}"
  local branch
  if [[ -n "${branch_override}" ]]; then
    branch="${branch_override}"
  else
    branch="$(issue_branch_name "${num}" "${title}")"
  fi
  echo "Feature branch: ${branch} (from ${default_branch})" >&2

  if [[ "${TEST_MODE}" == "1" ]]; then
    git checkout -B "${branch}" >/dev/null 2>&1 || git checkout -b "${branch}"
    printf '%s\n' "${branch}"
    return 0
  fi

  # This function's stdout is captured by the caller to obtain the branch
  # name, so every git command must keep its own output off stdout (send it to
  # stderr): `git checkout -B <branch> <remote>/<branch>` prints
  # "branch '<b>' set up to track ..." to stdout, which would otherwise be
  # captured as part of the branch name and break PR creation.
  git fetch origin "${branch}" >/dev/null 2>&1 || true
  if git rev-parse --verify -q "origin/${branch}" >/dev/null 2>&1; then
    git checkout -B "${branch}" "origin/${branch}" 1>&2
    echo "Using existing feature branch ${branch} (resume)." >&2
  else
    gh_api_create_branch "${owner}" "${repo}" "${branch}" "${default_oid}" >/dev/null 2>&1 || echo "WARNING: branch create returned an error for ${branch}; will try to fetch it." >&2
    git fetch origin "${branch}" 1>&2
    git checkout -B "${branch}" "origin/${branch}" 1>&2
    echo "Created feature branch ${branch}." >&2
  fi
  printf '%s\n' "${branch}"
}

# Check out an existing PR's head branch (resume path).
ensure_pr_branch_head() {
  local owner="${1}" repo="${2}" head="${3}"
  echo "Checking out PR head branch ${head}..." >&2
  if [[ "${TEST_MODE}" == "1" ]]; then
    git checkout -B "${head}" >/dev/null 2>&1 || git checkout -b "${head}"
    return 0
  fi
  # Keep git's own output off stdout; callers capture this function's stdout.
  git fetch origin "${head}" 1>&2
  git checkout -B "${head}" "origin/${head}" 1>&2
}

# --- implementation ---------------------------------------------------------

# Run opencode with each available model until one produces working-tree
# changes. Records which models were tried in OPENCODE_USED_MODELS.
implement() {
  local title="${1}" body="${2}" extra="${3:-}" workdir model
  workdir="$(pwd)"
  echo "Implementing with available models..." >&2
  OPENCODE_USED_MODELS=""
  for model in $(opencode_get_models); do
    [[ -z "${model}" ]] && continue
    check_timeout
    opencode_run "${title}" "${body}" "${workdir}" "${model}" "${extra}" || true
    OPENCODE_USED_MODELS="${OPENCODE_USED_MODELS}${model} "
    if workdir_changed "${workdir}"; then
      echo "Model ${model} produced changes." >&2
      return 0
    fi
    echo "Model ${model} produced no changes; falling through to the next model." >&2
  done
  echo "ERROR: no available model produced changes (tried: ${OPENCODE_USED_MODELS:-none})." >&2
  return 1
}

# --- PR lifecycle -----------------------------------------------------------

# Reuse the open PR for this head branch, else create one. Both reuse paths keep
# the PR body derived from the linked issue ("Closes #<n>\n\n<issue body>"), so a
# PR that was created without a written body (or with a stale one) gets it set.
# The update runs at most once per driver process (PR_BODY_SYNCED_FILE) to avoid
# a PATCH on every poll iteration. Outputs PR number.
ensure_pr() {
  local owner="${1}" repo="${2}" pr="${3}" branch="${4}" base="${5}" title="${6}" body="${7}" closes="${8}"
  local pr_body
  # A resumed PR that is not linked to any issue must keep its body verbatim;
  # prefixing it with a bare "Closes #" would produce a malformed description.
  if [[ -n "${closes}" ]]; then
    pr_body="Closes #${closes}

${body}"
  else
    pr_body="${body}"
  fi
  if [[ -n "${pr}" ]]; then
    if [[ -n "${closes}" ]] && ! pr_body_synced; then
      echo "Syncing body of PR #${pr} with issue #${closes}." >&2
      gh_api_update_pr "${owner}" "${repo}" "${pr}" "${pr_body}"
      pr_body_mark_synced
    fi
    printf '%s\n' "${pr}"
    return 0
  fi
  local existing
  existing="$(gh_api_find_pr_by_head "${owner}" "${repo}" "${branch}")"
  if [[ -n "${existing}" ]]; then
    echo "Reusing open PR #${existing} for ${branch}." >&2
    if [[ -n "${closes}" ]] && ! pr_body_synced; then
      echo "Syncing body of PR #${existing} with issue #${closes}." >&2
      gh_api_update_pr "${owner}" "${repo}" "${existing}" "${pr_body}"
      pr_body_mark_synced
    fi
    printf '%s\n' "${existing}"
    return 0
  fi
  local num
  num="$(gh_api_create_pr "${owner}" "${repo}" "${title}" "${pr_body}" "${branch}" "${base}")"
  if [[ -z "${num}" ]]; then
    echo "ERROR: PR creation failed for ${branch} -> ${base}." >&2
    return 1
  fi
  echo "Created PR #${num} (${branch} -> ${base})." >&2
  printf '%s\n' "${num}"
}

# Wait until every non-reviewer constraint (checks + mergeability) passes.
# Returns 0 when passable now, 1 when the PR needs new work.
poll_conditions() {
  local owner="${1}" repo="${2}" pr="${3}"
  while true; do
    check_timeout
    local cond state mergeable mss
    cond="$(gh_api_fetch_pr_conditions "${owner}" "${repo}" "${pr}")"
    state="$(printf '%s' "${cond}" | cut -d'|' -f1)"
    mergeable="$(printf '%s' "${cond}" | cut -d'|' -f2)"
    mss="$(printf '%s' "${cond}" | cut -d'|' -f3)"
    echo "PR #${pr} constraints: checks=${state} mergeable=${mergeable} mergeState=${mss}" >&2
    if [[ "${state}" == "SUCCESS" && "${mergeable}" == "MERGEABLE" ]]; then
      echo "All non-reviewer constraints pass." >&2
      return 0
    fi
    if [[ "${state}" == "FAILURE" || "${state}" == "ERROR" || "${mergeable}" == "CONFLICTING" || "${mss}" == "DIRTY" ]]; then
      echo "Constraints require changes (state=${state} mergeable=${mergeable})." >&2
      return 1
    fi
    rate_limit_poll_sleep "${POLL_CONDITIONS_MIN}" "${POLL_CONDITIONS_MAX}"
  done
}

# --- review fingerprint -----------------------------------------------------

# Main state machine. Handles both the fresh-issue path and the resume path;
# never exits until the PR is approved and every non-reviewer constraint
# passes ("ready to merge"). Never auto-merges.
drive() {
  local owner="${1}" repo="${2}" pr="${3}" branch="${4}" base="${5}" title="${6}" body="${7}" closes="${8}"
  local last_sig="" review_requested="false"

  while true; do
    check_timeout

    # Commit leftovers from a previously interrupted run.
    if workdir_changed "$(pwd)"; then
      commit_changes "conahcnuj: ${title}"
      # After committing our own fix, wait for CI to re-run instead of
      # immediately trying to implement (which would fail if nothing changed).
      continue
    fi

    pr="$(ensure_pr "${owner}" "${repo}" "${pr}" "${branch}" "${base}" "${title}" "${body}" "${closes}")"

    if ! poll_conditions "${owner}" "${repo}" "${pr}"; then
      # CI failed or the branch conflicts: implement again with that context.
      # When no model produces a change there is nothing new to push, so back
      # off before re-checking instead of hammering every model in a tight loop
      # (poll_conditions returns immediately on FAILURE).
      echo "PR #${pr}: constraints failing; fixing with a new implementation round." >&2
      local produced_change="false"
      if implement "${title}" "${body}" "The pull request's CI / merge constraints are currently failing. Fix whatever breaks them."; then
        produced_change="true"
      fi
      if workdir_changed "$(pwd)"; then
        commit_changes "conahcnuj: ${title} (fix constraints)"
        produced_change="true"
      fi
      if [[ "${produced_change}" != "true" ]]; then
        echo "No model produced changes for the failing constraints; backing off before re-checking." >&2
        rate_limit_poll_sleep "${POLL_CONDITIONS_MIN}" "${POLL_CONDITIONS_MAX}"
      fi
      continue
    fi

    echo "PR #${pr}: non-reviewer constraints satisfied." >&2
    if [[ "${review_requested}" != "true" ]]; then
      gh_api_request_review "${owner}" "${repo}" "${pr}" >/dev/null 2>&1 || echo "WARNING: could not request review on PR #${pr} (may already be requested)." >&2
      review_requested="true"
    fi

    # --- review phase ---
    local rv decision payload raw summary sig actionable
    rv="$(gh_api_fetch_reviews "${owner}" "${repo}" "${pr}")"
    decision="$(printf '%s' "${rv}" | cut -d'|' -f1)"
    payload="$(printf '%s' "${rv}" | cut -d'|' -f2)"
    raw="$(gh_api_unb64 "${payload}")"
    summary="$(printf '%s' "${raw}" | gh_api_review_summary)"
    sig="$(gh_api_review_fingerprint "${raw}")"
    echo "reviewDecision: ${decision:-NONE}" >&2

    if [[ "${decision}" == "APPROVED" ]]; then
      if poll_conditions "${owner}" "${repo}" "${pr}"; then
        echo "PR #${pr} is APPROVED and every non-reviewer constraint passes." >&2
        echo "Ready to merge: https://github.com/${owner}/${repo}/pull/${pr}" >&2
        exit 0
      fi
      echo "PR approved but constraints regressed; re-checking." >&2
      continue
    fi

    actionable="false"
    case "${decision}" in
      CHANGES_REQUESTED|COMMENTED|REVIEW_REQUIRED|"") actionable="true" ;;
    esac

    if [[ "${actionable}" == "true" && -n "${sig}" && "${sig}" != "${last_sig}" ]]; then
      last_sig="${sig}"
      echo "New review feedback detected; addressing it." >&2
      if ! implement "${title}" "${body}" "Address the pull request review feedback:

${summary}"; then
        if ! workdir_changed "$(pwd)"; then
          echo "No changes could be produced for this feedback; continuing to poll." >&2
          continue
        fi
      fi
      commit_changes "conahcnuj: ${title} (address review feedback)"
      if ! poll_conditions "${owner}" "${repo}" "${pr}"; then
        echo "Constraints failing after addressing feedback; fixing next cycle." >&2
        continue
      fi
      gh_api_request_review "${owner}" "${repo}" "${pr}" >/dev/null 2>&1 || echo "WARNING: could not request review on PR #${pr} (may already be requested)." >&2
      review_requested="true"
      gh_api_post_comment "${owner}" "${repo}" "${pr}" "Addressed the review feedback:

${summary}" >/dev/null
      echo "Replied on PR #${pr} after addressing review feedback." >&2
      # The reply is itself a new comment and would change the review payload,
      # so re-fingerprint the payload as it appears AFTER the reply. Otherwise
      # the next poll would treat our own comment as fresh reviewer feedback
      # and loop forever addressing the same thread.
      rv="$(gh_api_fetch_reviews "${owner}" "${repo}" "${pr}")"
      payload="$(printf '%s' "${rv}" | cut -d'|' -f2)"
      sig="$(gh_api_review_fingerprint "$(gh_api_unb64 "${payload}")")"
      last_sig="${sig}"
      continue
    fi

    echo "No new review feedback; waiting for reviewers..." >&2
    rate_limit_poll_sleep "${POLL_REVIEWS_MIN}" "${POLL_REVIEWS_MAX}"
  done
}

# --- entry points -----------------------------------------------------------

start_issue() {
  local owner="${1}" repo="${2}" num="${3}" issue="${4}"
  local title_b64 body_b64 title body
  title_b64="$(printf '%s' "${issue}" | cut -d'|' -f1)"
  body_b64="$(printf '%s' "${issue}" | cut -d'|' -f2)"
  title="$(gh_api_unb64 "${title_b64}")"
  body="$(gh_api_unb64 "${body_b64}")"
  echo "Issue #${num}: ${title}" >&2

  local repo_info default_branch default_oid
  repo_info="$(gh_api_get_repo "${owner}" "${repo}")"
  default_branch="$(printf '%s' "${repo_info}" | cut -d'|' -f1)"
  default_oid="$(printf '%s' "${repo_info}" | cut -d'|' -f2)"
  echo "Default branch: ${default_branch} (${default_oid:0:7})" >&2

  local branch base_branch
  base_branch="$(issue_branch_name "${num}" "${title}")"
  branch="$(next_free_branch "${owner}" "${repo}" "${base_branch}")"
  branch="$(ensure_issue_branch "${owner}" "${repo}" "${num}" "${title}" "${default_branch}" "${default_oid}" "${branch}")"

  # An earlier run may have already committed the implementation to this
  # branch. In that case there is nothing left to implement, so skip the
  # model fall-through and go straight to opening the PR for review. This is
  # what keeps the driver from spinning through every model asking for work
  # that is already done.
  if branch_has_commits "${default_branch}"; then
    echo "Branch ${branch} already has commits; skipping implement and opening the PR." >&2
  else
    if ! implement "${title}" "${body}"; then
      echo "ERROR: could not implement issue #${num} with any available model." >&2
      exit 1
    fi
    commit_changes "conahcnuj: implement issue #${num}: ${title}"
  fi

  drive "${owner}" "${repo}" "" "${branch}" "${default_branch}" "${title}" "${body}" "${num}"
}

resume_pr() {
  local owner="${1}" repo="${2}" pr="${3}"
  local ps state title_b64 body_b64 head base closes title body
  ps="$(gh_api_fetch_pr_state "${owner}" "${repo}" "${pr}")"
  state="$(printf '%s' "${ps}" | cut -d'|' -f2)"
  title_b64="$(printf '%s' "${ps}" | cut -d'|' -f3)"
  body_b64="$(printf '%s' "${ps}" | cut -d'|' -f4)"
  head="$(printf '%s' "${ps}" | cut -d'|' -f9)"
  base="$(printf '%s' "${ps}" | cut -d'|' -f10)"
  closes="$(printf '%s' "${ps}" | cut -d'|' -f12)"
  title="$(gh_api_unb64 "${title_b64}")"
  body="$(gh_api_unb64 "${body_b64}")"
  echo "PR #${pr}: state=${state} head=${head} base=${base}" >&2

  # When the PR body is still just the auto-generated "Closes #<n>" stub, derive
  # a real description from the linked issue so the resumed PR gets a written body.
  if [[ -n "${closes}" ]] && [[ "${body}" == "Closes #${closes}" || "${body}" == "Closes #${closes}"$'\n' ]]; then
    local iss iss_body
    iss="$(gh_api_fetch_issue "${owner}" "${repo}" "${closes}")"
    iss_body="$(printf '%s' "${iss}" | cut -d'|' -f2 | gh_api_unb64)"
    if [[ -n "${iss_body}" ]]; then
      echo "PR body is just the closing stub; reusing issue #${closes} as the PR body." >&2
      body="${iss_body}"
    fi
  fi

  case "${state}" in
    MERGED)
      echo "PR #${pr} is already merged. Nothing to do." >&2
      exit 0
      ;;
    CLOSED)
      echo "PR #${pr} is closed without merge. Nothing to do." >&2
      exit 1
      ;;
    OPEN|"") ;;
    *)
      echo "ERROR: unknown PR state: ${state}" >&2
      exit 1
      ;;
  esac

  ensure_pr_branch_head "${owner}" "${repo}" "${head}"
  drive "${owner}" "${repo}" "${pr}" "${head}" "${base}" "${title}" "${body}" "${closes}"
}

main() {
  if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <issue-or-pr-number> [--pr]" >&2
    exit 1
  fi
  local input="${1}" as_pr="${2:-}" repo_info owner repo
  if [[ "${as_pr}" != "--pr" && ${#as_pr} -gt 0 ]]; then
    echo "Unknown option: ${as_pr} (use --pr to resume a pull request)" >&2
    exit 1
  fi

  repo_info="$(repo_detect)"
  owner="${repo_info%%/*}"
  repo="${repo_info#*/}"
  echo "Repository: ${owner}/${repo}" >&2

  if [[ "${TEST_MODE}" != "1" ]]; then
    bash "${HERE}/../gh-app/setup-git.sh"
  fi

  if [[ "${as_pr}" == "--pr" ]]; then
    resume_pr "${owner}" "${repo}" "${input}"
    return 0
  fi

  local issue is_pr
  issue="$(gh_api_fetch_issue "${owner}" "${repo}" "${input}")"
  is_pr="$(printf '%s' "${issue}" | cut -d'|' -f4)"
  if [[ "${is_pr}" == "true" ]]; then
    echo "Input #${input} is a pull request; resuming it in place." >&2
    resume_pr "${owner}" "${repo}" "${input}"
  else
    start_issue "${owner}" "${repo}" "${input}" "${issue}"
  fi
}

# SOURCEABLE: tests set CONAHCNUJ_IMPORT=1 to source this file (instead of
# invoking main) so driver internals such as ensure_pr can be unit-tested.
if [[ "${CONAHCNUJ_IMPORT:-0}" != "1" ]]; then
  main "$@"
fi
