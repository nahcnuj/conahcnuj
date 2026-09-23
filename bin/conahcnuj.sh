#!/usr/bin/env bash
# conahcnuj - issue-driven autonomous development driver.
#
# Resolves a GitHub issue (or resumes a pull request) end-to-end. The coding
# agent, not the driver, decides how the work is presented: it writes the
# commit message (.commit-msg) and may choose the feature branch name
# (.branch-name; when the agent leaves none out, the driver picks one). A PR
# number given on the command line is detected and resumed automatically:
#   1. checks out the latest default branch and implements the issue with
#      opencode (falling through every available model until one produces
#      changes), committing only with the agent's .commit-msg
#   2. opens a PR, waits until every non-reviewer constraint (CI checks,
#      mergeability) passes, then requests review
#   3. polls the review status; addresses comments / requested changes /
#      security-review threads, pushes and re-verifies non-reviewer
#      constraints, then replies on the PR
#   4. exits only when the PR is ready to merge
#   5. on an abnormal exit (timeout, no model produced changes, unexpected
#      errors) automatically files a bug report issue in the repository so a
#      run the driver could not resolve is never silently lost. The report
#      carries the tail of the run's console output as a detailed error log
#
# Usage: conahcnuj <issue-or-pr-number>
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

# --- Windows relaunch -------------------------------------------------------

# The configured Git Bash: environment override > gh-app/app.env > the
# committed app.env.example. A placeholder means "not configured", so fall
# back to the standard Git for Windows location, like setup-git.sh does.
driver_bash_exe() {
  local env_file line
  if [[ -n "${BASH_EXE:-}" ]]; then
    printf '%s\n' "${BASH_EXE}"
    return 0
  fi
  env_file="${GH_APP_DIR:-${HERE}/../gh-app}/app.env"
  if [[ ! -f "${env_file}" ]]; then
    env_file="${HERE}/../gh-app/app.env.example"
  fi
  if [[ -f "${env_file}" ]]; then
    line="$(sed -n 's/^[[:space:]]*BASH_EXE[[:space:]]*=[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p' "${env_file}" | head -1)"
    if [[ -n "${line}" && "${line}" != "<your-bash-exe>" ]]; then
      printf '%s\n' "${line}"
      return 0
    fi
  fi
  printf '%s\n' "C:/Program Files/Git/bin/bash.exe"
}

# True when the driver must re-launch itself under the configured Git Bash.
# On Windows, `bash conahcnuj <n>` from PowerShell can resolve to WSL bash,
# where the MSYS-style PRIVATE_KEY_PATH (/c/Users/...) and the Windows git
# credential helper do not exist, so the driver cannot load the private key
# (issue #31). Skipped when already running Git Bash (MSYSTEM), when not under
# WSL, or when the configured bash cannot be reached from WSL.
driver_needs_relaunch() {
  [[ -z "${MSYSTEM:-}" ]] || return 1
  [[ -n "${WSL_DISTRO_NAME:-}" ]] || return 1
  command -v wslpath >/dev/null 2>&1 || return 1
  local bash_exe bash_mnt
  bash_exe="$(driver_bash_exe)"
  bash_mnt="$(wslpath -u "${bash_exe}" 2>/dev/null || true)"
  if [[ -z "${bash_mnt}" || ! -x "${bash_mnt}" ]]; then
    echo "WARNING: BASH_EXE ${bash_exe} is not reachable from WSL; continuing (paths may not resolve)." >&2
    return 1
  fi
  return 0
}

# Re-run the driver under the configured Git Bash so every helper (the
# /c/... private key path, the Windows credential helper, opencode) sees the
# path space it was written for. Passes the script back to Git Bash as a
# Windows path (wslpath -m) and keeps the original arguments.
driver_relaunch() {
  local bash_exe bash_mnt self self_win
  bash_exe="$(driver_bash_exe)"
  bash_mnt="$(wslpath -u "${bash_exe}")"
  self="${0}"
  if [[ "${self}" != /* && "${self}" != */* ]]; then
    self="$(command -v "${self}" 2>/dev/null || true)"
  fi
  if [[ -z "${self}" ]]; then
    echo "WARNING: could not resolve \$0 (${0}) to relaunch; continuing under WSL." >&2
    return 1
  fi
  self_win="$(wslpath -m "${self}" 2>/dev/null || true)"
  if [[ -z "${self_win}" ]]; then
    echo "WARNING: could not convert \${0} (${self}) to a Windows path; continuing under WSL." >&2
    return 1
  fi
  echo "Re-launching under ${bash_exe} so the GitHub App paths resolve." >&2
  exec "${bash_mnt}" "${self_win}" "$@"
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

# True when the working tree holds real changes. The coding agent's
# .commit-msg and .branch-name are metadata, not code changes, so they are
# ignored: a model that writes nothing but a commit message or a branch name
# must not count as having produced work.
workdir_changed() {
  local dir="${1}" changes
  changes="$(git -C "${dir}" status --porcelain 2>/dev/null | grep -v '\.commit-msg' | grep -v '\.branch-name' || true)"
  [[ -n "${changes}" ]]
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
# branch to the remote head api-commit.sh created. The commit message always
# comes from the coding agent (.commit-msg); the driver never invents a fixed
# message, so when the agent left none out it refuses to commit. Test mode:
# plain local commit (no network / no secret) so flows can be exercised
# offline.
commit_changes() {
  local message
  # .branch-name is metadata, never part of the implementation.
  rm -f .branch-name
  if [[ ! -f ".commit-msg" ]]; then
    echo "ERROR: the coding agent left no .commit-msg; refusing to commit with a fixed message." >&2
    return 1
  fi
  message="$(head -1 .commit-msg)"
  rm -f .commit-msg
  if [[ -z "${message}" ]]; then
    echo "ERROR: .commit-msg is empty; the coding agent must write a commit message." >&2
    return 1
  fi
  echo "Using coding agent's commit message: ${message}" >&2
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

# --- bug reporting ----------------------------------------------------------

# When the driver terminates abnormally it files a bug report issue in the
# repository it was working on, so a failed run is never silently lost and the
# next driver invocation can pick the report up (the driver resolves issues).
# Best-effort only: the report must never change the exit code, never trigger
# an extra API call on a successful run, and must not recurse into another
# report (a failed report files nothing further).
BUG_REPORT_INPUT=""
BUG_REPORTED="0"
# Exit code captured by the EXIT trap at runtime ($? is not preserved across a
# function call). Pre-declared so the trap string's reference is valid.
bug_exit_code=""
# Run-log capture. RUN_LOG_FILE receives a copy of the driver's stderr during
# the run so an abnormal exit can attach its tail to the bug report as a
# detailed error log; see run_log_start(). RUN_TEE_PID holds the background
# reader that copies the stream, so the EXIT trap can wait for a complete log.
RUN_LOG_FILE=""
RUN_TEE_PID=""

# Capture the driver's stderr into RUN_LOG_FILE while keeping it visible on the
# saved stderr (fd3). A FIFO feeds a background line-reader that appends each
# line to the log file synchronously; a plain `exec 2> >(tee ...)` could not
# guarantee the file is flushed by the time the EXIT trap reads it, because tee
# buffers its file output. run_log_finalize() closes the FIFO write end and
# waits for the reader so the report always sees a complete log;
# run_log_cleanup() removes the scratch files. Best-effort only: if the FIFO
# cannot be created the run continues without a capture.
run_log_start() {
  RUN_LOG_FILE="$(mktemp)"
  RUN_TEE_PID=""
  local pipe
  pipe="${RUN_LOG_FILE}.pipe"
  if ! mkfifo "${pipe}" 2>/dev/null; then
    echo "WARNING: could not create the run log FIFO; the bug report will carry no error log." >&2
    rm -f "${RUN_LOG_FILE}"
    RUN_LOG_FILE=""
    return 0
  fi
  exec 3>&2
  (
    exec 0<"${pipe}"
    while IFS= read -r line; do
      line="${line%$'\r'}"
      printf '%s\n' "${line}" >> "${RUN_LOG_FILE}" || true
      printf '%s\n' "${line}" >&3 || true
    done
  ) &
  RUN_TEE_PID=$!
  exec 2>"${pipe}"
}

# Make the captured log complete and reap the background reader: close the
# FIFO write end (fd2) so the reader sees EOF, wait for it to drain and exit,
# then restore fd2 from the saved fd3. Safe to call when no capture is active.
run_log_finalize() {
  if [[ -z "${RUN_TEE_PID:-}" ]]; then
    return 0
  fi
  exec 2>&-
  wait "${RUN_TEE_PID}" 2>/dev/null || true
  RUN_TEE_PID=""
  exec 2>&3
}

# Remove the run-log scratch files. Safe to call when no capture is active.
run_log_cleanup() {
  if [[ -n "${RUN_LOG_FILE:-}" ]]; then
    rm -f "${RUN_LOG_FILE}" "${RUN_LOG_FILE}.pipe" 2>/dev/null || true
    RUN_LOG_FILE=""
  fi
}

report_bug_title() {
  local code="${1}" input="${2:-}"
  if [[ -n "${input}" ]]; then
    printf 'conahcnuj: failed to resolve #%s (exit %s)\n' "${input}" "${code}"
  else
    printf 'conahcnuj: driver terminated abnormally (exit %s)\n' "${code}"
  fi
}

report_bug_body() {
  local code="${1}" owner="${2}" repo="${3}" input="${4:-}" branch="${5:-}" oid="${6:-}"
  local ended label log_tail log_block
  ended="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || true)"
  label=""
  if [[ -n "${input}" ]]; then
    # Fully-qualified so a report filed in one repository still points
    # unambiguously at the item being worked on in another one.
    label="${owner}/${repo}#${input} (invoked as \`conahcnuj ${input}\`)"
  else
    label="unknown (no issue/PR number was given; repository: ${owner}/${repo})"
  fi
  log_tail="$(tail -n 100 "${RUN_LOG_FILE}" 2>/dev/null || true)"
  if [[ -n "${log_tail}" ]]; then
    log_block="\`\`\`text
${log_tail}
\`\`\`"
  else
    log_block="_No driver output was captured before the exit._"
  fi
  cat <<EOF
The conahcnuj driver terminated abnormally and could not resolve the item it was working on. This issue was filed automatically so the driver bug can be fixed (re-run: conahcnuj ${input}).

## Context

- Issue/PR: ${label}
- Branch: ${branch:-unknown}
- HEAD: ${oid:-unknown}
- Exit code: ${code} (how the conahcnuj driver process itself exited)
- Ended at: ${ended:-unknown}

## Error log

${log_block}

The driver exits this way only when it is unable to finish the run; a maintainer should investigate and pick this report up.
EOF
}

# EXIT trap. The exit code is captured in the trap string ($? is not preserved
# inside a function call), so the report always knows why the run died; on a
# successful run (code 0) the report does nothing, so the happy-path flow tests
# need no extra tape entry. The trap must never change the exit code.
report_bug_on_exit() {
  local code="${1:-}"
  local owner="${BUG_REPORT_OWNER:-}" repo="${BUG_REPORT_REPO:-}" input="${BUG_REPORT_INPUT:-}"
  local branch oid title body num
  # Complete the run log (close the FIFO, reap the reader) so report_bug_body
  # sees the whole console output, then always clean up, successful run or not.
  run_log_finalize
  if [[ -z "${code}" || "${code}" == "0" || "${BUG_REPORTED}" == "1" ]]; then
    run_log_cleanup
    return 0
  fi
  if [[ -z "${owner}" || -z "${repo}" ]]; then
    echo "WARNING: abnormal exit (${code}) but no owner/repo is known; skipping the bug report." >&2
    BUG_REPORTED="1"
    run_log_cleanup
    return 0
  fi
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  oid="$(git rev-parse --short HEAD 2>/dev/null || true)"
  title="$(report_bug_title "${code}" "${input}")"
  body="$(report_bug_body "${code}" "${owner}" "${repo}" "${input}" "${branch}" "${oid}")"
  echo "Driver exited abnormally (code ${code}); filing a bug report issue in ${owner}/${repo}." >&2
  if num="$(gh_api_create_issue "${owner}" "${repo}" "${title}" "${body}")"; then
    if [[ -n "${num}" ]]; then
      echo "Bug report issue #${num} created: https://github.com/${owner}/${repo}/issues/${num}" >&2
      BUG_REPORTED="1"
      run_log_cleanup
      return 0
    fi
  fi
  echo "WARNING: could not file a bug report issue (exit code ${code})." >&2
  BUG_REPORTED="1"
  run_log_cleanup
  return 0
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

# Let the coding agent choose the feature branch. If the implementation round
# wrote .branch-name, use that name (renaming the local branch and, in real
# mode, creating the remote branch under it); otherwise keep the driver-derived
# name. A blank / malformed / already-in-use name falls back to ${current}.
# Prints the final branch name.
resolve_agent_branch_name() {
  local owner="${1}" repo="${2}" default_oid="${3}" current="${4}" want
  if [[ ! -f ".branch-name" ]]; then
    printf '%s\n' "${current}"
    return 0
  fi
  # Trim leading/trailing whitespace only; internal spaces stay and are then
  # rejected by git check-ref-format rather than silently altered.
  want="$(head -1 .branch-name | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  rm -f .branch-name
  if [[ -z "${want}" ]]; then
    echo "WARNING: .branch-name is empty; keeping the driver-derived branch ${current}." >&2
    printf '%s\n' "${current}"
    return 0
  fi
  if ! git check-ref-format --branch "${want}" >/dev/null 2>&1; then
    echo "WARNING: invalid branch name '${want}' in .branch-name; keeping ${current}." >&2
    printf '%s\n' "${current}"
    return 0
  fi
  if [[ "${want}" == "${current}" ]]; then
    printf '%s\n' "${current}"
    return 0
  fi
  if [[ "${TEST_MODE}" != "1" ]]; then
    if ! gh_api_create_branch "${owner}" "${repo}" "${want}" "${default_oid}" >/dev/null 2>&1; then
      echo "WARNING: could not create the remote branch ${want} (name in use?); keeping ${current}." >&2
      printf '%s\n' "${current}"
      return 0
    fi
    git fetch origin "${want}" 1>&2
    git checkout -B "${want}" "origin/${want}" 1>&2
  else
    git checkout -B "${want}" >/dev/null 2>&1
  fi
  echo "Using the coding agent's feature branch: ${want}" >&2
  printf '%s\n' "${want}"
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
    # Trim trailing whitespace from issue body to avoid extra blank lines
    body="$(printf '%s' "${body}" | sed 's/[[:space:]]*$//')"
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
    # Fallback: if checks pass but mergeable is empty (API parsing issue),
    # assume mergeable since CI passes.
    if [[ "${state}" == "SUCCESS" && -z "${mergeable}" ]]; then
      echo "Checks pass but mergeable state unknown; assuming MERGEABLE." >&2
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
      commit_changes
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
        commit_changes
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
      commit_changes
      if ! poll_conditions "${owner}" "${repo}" "${pr}"; then
        echo "Constraints failing after addressing feedback; fixing next cycle." >&2
        continue
      fi
      gh_api_request_review "${owner}" "${repo}" "${pr}" >/dev/null 2>&1 || echo "WARNING: could not request review on PR #${pr} (may already be requested)." >&2
      review_requested="true"
      gh_api_post_comment "${owner}" "${repo}" "${pr}" "Addressed the review feedback:

${summary}" >/dev/null || echo "WARNING: could not post the review-feedback reply on PR #${pr}." >&2
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
  body="$(gh_api_unescape "$(gh_api_unb64 "${body_b64}")")"
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
  elif workdir_changed "$(pwd)"; then
    echo "Working tree has uncommitted changes; committing them as the implementation." >&2
    commit_changes
  else
    if ! implement "${title}" "${body}"; then
      echo "ERROR: could not implement issue #${num} with any available model." >&2
      exit 1
    fi
    branch="$(resolve_agent_branch_name "${owner}" "${repo}" "${default_oid}" "${branch}")"
    commit_changes
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
  body="$(gh_api_unescape "$(gh_api_unb64 "${body_b64}")")"
  echo "PR #${pr}: state=${state} head=${head} base=${base}" >&2

  # When the PR body is still just the auto-generated "Closes #<n>" stub, derive
  # a real description from the linked issue so the resumed PR gets a written body.
  if [[ -n "${closes}" ]] && [[ "${body}" == "Closes #${closes}" || "${body}" == "Closes #${closes}"$'\n' ]]; then
    local iss iss_body
    iss="$(gh_api_fetch_issue "${owner}" "${repo}" "${closes}")"
    iss_body="$(gh_api_unescape "$(printf '%s' "${iss}" | cut -d'|' -f2 | gh_api_unb64)")"
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
  # On Windows, re-run under the configured Git Bash when this shell is WSL
  # (see driver_relaunch) so every helper shares the same path space.
  if driver_needs_relaunch; then
    driver_relaunch "$@" || true
  fi

  if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <issue-or-pr-number>" >&2
    exit 1
  fi
  local input="${1}" repo_info owner repo
  if [[ "${input}" == -* ]]; then
    echo "Unknown option: ${input}" >&2
    exit 1
  fi

  repo_info="$(repo_detect)"
  owner="${repo_info%%/*}"
  repo="${repo_info#*/}"
  echo "Repository: ${owner}/${repo}" >&2

  # File a bug report issue when the run terminates abnormally. Registered only
  # once owner/repo and the input are known: a usage error or a failed repo
  # detection has no target to report to and stays quiet.
  BUG_REPORT_OWNER="${owner}"
  BUG_REPORT_REPO="${repo}"
  BUG_REPORT_INPUT="${input}"
  trap 'bug_exit_code=$?; report_bug_on_exit "${bug_exit_code}"' EXIT

  # Capture the run's stderr into a log so an abnormal exit can attach a
  # detailed error log to the bug report (see run_log_start).
  run_log_start

  if [[ "${TEST_MODE}" != "1" ]]; then
    bash "${HERE}/../gh-app/setup-git.sh"
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
