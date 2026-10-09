#!/usr/bin/env bash
# conahcnuj - issue-driven autonomous development driver.
#
# Resolves a GitHub issue (or resumes a pull request) end-to-end. The coding
# agent's part is the change in the working tree and the answers it writes in
# review threads; the driver creates the branch, the commit, the push, the pull
# request and the review request. The agent labels its work: it writes the commit
# message (.commit-msg) and may choose the feature branch name (.branch-name;
# when the agent leaves none out, the driver picks one). A PR number given on
# the command line is detected and resumed automatically:
#   1. checks out the latest default branch and implements the issue with
#      opencode (handing the same session and working tree to another model
#      when one fails), committing only with the agent's .commit-msg
#   2. opens a PR, waits until every non-reviewer constraint (CI checks,
#      mergeability) passes, then assigns the repository owner as reviewer.
#      That hand-off to a human is the last thing a run owes the PR, so the
#      driver exits there; an already APPROVED PR exits earlier as "ready to
#      merge". Never auto-merges. The request is retried once, and the PR is
#      read back before a hand-off is called lost; only a PR that GitHub says
#      has nobody asked fails the run, while a hand-off that cannot be verified
#      at all ends the run with a warning (issues #134 / #139).
#   3. when the run was resumed with fresh review feedback (comments /
#      requested changes / security-review threads), addresses it, pushes a
#      Verified commit, re-requests review (the agent answers the reviewer in
#      the thread itself, so the driver posts no reply of its own), re-verifies
#      the non-reviewer constraints and exits
#   4. on an abnormal exit (timeout, no model completed the work, unexpected
#      errors) automatically files a bug report discussion in the repository so
#      a run the driver could not resolve is never silently lost. The report
#      carries the tail of the run's console output as a detailed error log
#   5. `--discussion <number>` instead triages a bug-report discussion: the
#      coding agent investigates the report and hands its verdict back through a
#      file (.triage-issue / .triage-verdict, the counterpart of .commit-msg),
#      then the driver either files the issue the normal flow above resolves or
#      posts the verdict on the thread. Reporting and triage are separate runs on
#      purpose: the investigation gets its own time budget, and nothing is filed
#      that the investigation did not confirm. A thread that already carries a
#      triage marker is left alone, so a re-run never opens a second issue.
#
# Usage: conahcnuj <issue-or-pr-number>
#        conahcnuj --discussion <discussion-number>
#
# Environment overrides (all optional):
#   CONAHCNUJ_REPO           owner/repo when no origin remote is available
#   CONAHCNUJ_MAX_SECONDS    overall time budget (default: 259200 = 72 h)
#   CONAHCNUJ_HANDOFF_RETRY_SECONDS  pause before the single review-request
#                            retry (default: 15 s; 0 disables the pause)
#   CONAHCNUJ_POLL_CONDITIONS_MIN/MAX  rate-limited poll window (default 15/300 s)
#   CONAHCNUJ_TEST_MODE=1    offline driver test (mock API tape + mock opencode)
#   CONAHCNUJ_COMMIT_MODEL   Co-Authored-By trailer value; when unset, the
#                            driver uses the plugin label (provider
#                            (model/effort)) or builds the same shape from
#                            the model id it recorded
#   CONAHCNUJ_OPENCODE_LOG_LEVEL  opencode --log-level for the run
#                            (default: WARN; DEBUG to debug a failing model)
#   CONAHCNUJ_CONTEXT_FILES  space-separated checkout files whose contents are
#                            collected into the prompt alongside the issue
#                            (default: README.md AGENTS.md; empty sends none)
#   CONAHCNUJ_BUG_REPORT_CATEGORY  discussion category for bug reports
#                            (default: Bug report)
#
# Polling honours GitHub rate limits: API retries wait on Retry-After /
# X-RateLimit-Reset headers (lib/rate-limit.sh), and poll loops sleep with
# jitter within their configured windows.

# opencode's JSON events are formatted as they arrive (lib/opencode-render.sh,
# one context header per block) onto stderr, so the console output stays
# readable and the bug report above carries that text. The formatter clips
# nothing: every line the model wrote and every line a command printed reaches
# the log.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_MODE="${CONAHCNUJ_TEST_MODE:-0}"

MAX_DURATION="${CONAHCNUJ_MAX_SECONDS:-259200}"
POLL_CONDITIONS_MIN="${CONAHCNUJ_POLL_CONDITIONS_MIN:-15}"
POLL_CONDITIONS_MAX="${CONAHCNUJ_POLL_CONDITIONS_MAX:-300}"
START_TIME="$(date +%s)"
# Snapshot a caller-supplied trailer value. apply_driver_commit_model exports
# CONAHCNUJ_COMMIT_MODEL for api-commit.sh, so a later commit must not treat
# that export as a new explicit override.
USER_COMMIT_MODEL="${CONAHCNUJ_COMMIT_MODEL:-}"

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
PR_CONTINUATION_COMMENTED_FILE="${PR_CONTINUATION_COMMENTED_FILE:-$(mktemp)}"

# Whether the last request_review_from_owner call could confirm the reviewer
# assignment. log_review_handoff words its final line after it, so the run log
# never claims a review request the run could not verify.
REVIEW_HANDOFF_CONFIRMED="true"

# What collect_initial_context gathered for this run (unresolved review threads
# of a resumed PR, the orientation files of the checkout). The issue / PR body
# is always in the prompt by itself; this is the rest of the deterministically
# collectable material, set once per run after the branch checkout and handed
# to every fresh prompt through implement().
COLLECTED_CONTEXT=""

# True once the per-process PR body sync has already run.
pr_body_synced() {
  [[ "$(cat "${PR_BODY_SYNCED_FILE}" 2>/dev/null || true)" == "1" ]]
}
pr_body_mark_synced() {
  printf '1\n' > "${PR_BODY_SYNCED_FILE}"
}
pr_continuation_commented() {
  [[ "$(cat "${PR_CONTINUATION_COMMENTED_FILE}" 2>/dev/null || true)" == "1" ]]
}
pr_continuation_mark_commented() {
  printf '1\n' > "${PR_CONTINUATION_COMMENTED_FILE}"
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
# .commit-msg and .branch-name, and a triage run's .triage-issue /
# .triage-verdict, are metadata, not code changes, so they are ignored: a model
# that writes nothing but one of those must not count as having produced work.
workdir_changed() {
  local dir="${1}" changes
  changes="$(git -C "${dir}" status --porcelain 2>/dev/null | grep -v '\.commit-msg' | grep -v '\.branch-name' | grep -v '\.triage-issue' | grep -v '\.triage-verdict' || true)"
  [[ -n "${changes}" ]]
}

# True when the current branch already carries commits on top of the default
# branch, i.e. an earlier run already implemented the issue. Used to skip the
# model fall-through (which would otherwise keep asking every model to do work
# that is already committed) and go straight to opening the PR.
branch_has_commits() {
  local default_oid="${1}" default_branch="${2}" ref count
  # Compare against the default branch's tip as freshly read from the API, not
  # the local origin/<default> ref: the driver never fetches the default
  # branch, so that ref goes stale once main advances through merged PRs. A
  # feature branch pinned at the real main tip would then look like it already
  # "has commits", the driver would skip implementation, and GitHub would
  # reject the PR (createPullRequest: UNPROCESSABLE, no commits between base
  # and head). That is what crashed the driver into the bug-report chain of
  # issues #33/#34.
  ref="${default_oid}"
  if ! git rev-parse --verify -q "${ref}^{commit}" >/dev/null 2>&1; then
    # The OID is not in this clone (offline tests feed a placeholder oid);
    # fall back to the local default-branch refs.
    ref="${default_branch}"
    if git rev-parse --verify -q "origin/${default_branch}" >/dev/null 2>&1; then
      ref="origin/${default_branch}"
    fi
  fi
  count="$(git rev-list --count "${ref}..HEAD" 2>/dev/null || printf '0')"
  [[ "${count}" -gt 0 ]]
}

# Shape a provider/model id like the plugin's label: `provider (model)`.
# Only the effort part is missing, which the driver never sees.
driver_model_value() {
  local id="${1}" provider rest
  provider="${id%%/*}"
  rest="${id#*/}"
  if [[ -n "${rest}" && "${rest}" != "${id}" ]]; then
    printf '%s (%s)' "${provider}" "${rest}"
  else
    printf '%s' "${id}"
  fi
}

# Pick the Co-Authored-By trailer value. An explicit CONAHCNUJ_COMMIT_MODEL
# wins. Otherwise use the label the OpenCode plugin wrote under os.tmpdir(), and
# fall back to the provider/model id that produced the working-tree change.
apply_driver_commit_model() {
  if [[ -n "${USER_COMMIT_MODEL}" ]]; then
    CONAHCNUJ_COMMIT_MODEL="${USER_COMMIT_MODEL}"
    export CONAHCNUJ_COMMIT_MODEL
    return 0
  fi
  CONAHCNUJ_COMMIT_MODEL=""
  if [[ -n "${CONAHCNUJ_MODEL_LABEL_FILE:-}" && -f "${CONAHCNUJ_MODEL_LABEL_FILE}" ]]; then
    local label
    label="$(head -n 1 "${CONAHCNUJ_MODEL_LABEL_FILE}" | tr -d '\r')"
    if [[ -n "${label}" ]]; then
      CONAHCNUJ_COMMIT_MODEL="${label}"
      export CONAHCNUJ_COMMIT_MODEL
      return 0
    fi
  fi
  if [[ -n "${OPENCODE_LAST_MODEL:-}" ]]; then
    CONAHCNUJ_COMMIT_MODEL="$(driver_model_value "${OPENCODE_LAST_MODEL}")"
    export CONAHCNUJ_COMMIT_MODEL
  fi
}

# Commit every working-tree change as a Verified commit, then sync the local
# branch to the remote head api-commit.sh created. The commit message always
# comes from the coding agent (.commit-msg); the driver never invents a fixed
# message, so when the agent left none out it refuses to commit. Test mode:
# plain local commit (no network / no secret) so flows can be exercised
# offline. api-commit.sh appends the Co-Authored-By trailer from
# CONAHCNUJ_COMMIT_MODEL; test mode adds the same trailer with a second -m
# paragraph.
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
  apply_driver_commit_model
  if [[ "${TEST_MODE}" == "1" ]]; then
    git config commit.gpgsign false
    if [[ -n "${CONAHCNUJ_COMMIT_MODEL:-}" ]] && ! printf '%s\n' "${message}" | grep -qiE '^[[:space:]]*co-authored-by:'; then
      git commit -q -m "${message}" -m "Co-Authored-By: ${CONAHCNUJ_COMMIT_MODEL}" 2>/dev/null || echo "WARNING: nothing to commit (test mode)" >&2
    else
      git commit -q -m "${message}" 2>/dev/null || echo "WARNING: nothing to commit (test mode)" >&2
    fi
    return 0
  fi
  bash "${HERE}/../gh-app/api-commit.sh" -m "${message}"
  local branch
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  git fetch origin "${branch}" >/dev/null 2>&1 || true
  git reset --hard "origin/${branch}" >/dev/null 2>&1 || true
}

# --- bug reporting ----------------------------------------------------------

# When the driver terminates abnormally it files a bug report in the
# repository's discussion category, so a failed run is never silently lost.
# Discussions rather than issues on purpose: an issue created by the driver
# re-triggers issue-driver.yml, which then tries to "resolve" the driver's own
# failure report as if it were planned work. A discussion is also the right home
# for an unplanned failure report. Best-effort only: the report must never
# change the exit code, never trigger an extra API call on a successful run, and
# must not recurse into another report (a failed report files nothing further).
BUG_REPORT_INPUT=""
BUG_REPORTED="0"
# What this run was working on. "issue" (default) drives an issue or PR;
# "discussion" triages a bug-report discussion. It picks the bug report's thread
# title, which is the driver's loop breaker: the triage title carries no number,
# so a repeated triage failure appends to the previous one instead of opening a
# thread whose creation would fire the discussion trigger again.
BUG_REPORT_KIND="issue"
BUG_REPORT_DISCUSSION=""
# Discussion category the reports are filed in. Its name and slug are matched
# case-insensitively, so both "Bug report" and "bug-report" work.
BUG_REPORT_CATEGORY="${CONAHCNUJ_BUG_REPORT_CATEGORY:-Bug report}"
# Set when implement() gave up because every model round died on an
# environment error (providers unreachable / credentials rejected). The bug
# report then words its opening and closing so the failure reads as the
# environment, not a driver defect (#149).
ENVIRONMENT_DOWN="0"
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

# Thread title of a bug report. Deliberately free of per-run details (exit
# code, timestamp): the title is what groups reports, so the same kind of
# failure always lands in the same thread and a repeat becomes a reply. Every
# per-run detail lives in the body instead.
# A triage run's title names no discussion either. That is what bounds the
# report -> triage -> report chain: a triage run that dies posts into the
# existing thread (a reply fires no discussion trigger), so the chain stops
# after one extra run instead of spawning a new triage run per failure.
report_bug_title() {
  local input="${1:-}"
  if [[ "${BUG_REPORT_KIND}" == "discussion" ]]; then
    printf 'conahcnuj: failed to triage a bug report discussion\n'
  elif [[ -n "${input}" ]]; then
    printf 'conahcnuj: failed to resolve #%s\n' "${input}"
  else
    printf 'conahcnuj: driver terminated abnormally\n'
  fi
}

# Body of a bug report, posted as the first entry of a thread or as a reply.
# Args: code owner repo input branch oid occurrence ("first" | "again")
report_bug_body() {
  local code="${1}" owner="${2}" repo="${3}" input="${4:-}" branch="${5:-}" oid="${6:-}" occurrence="${7:-first}"
  local ended label log_tail log_block intro closing rerun
  ended="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || true)"
  label=""
  if [[ "${BUG_REPORT_KIND}" == "discussion" ]]; then
    # The discussion under investigation is the only context a triage run has.
    label="bug report discussion #${BUG_REPORT_DISCUSSION:-unknown}"
    rerun="conahcnuj --discussion ${BUG_REPORT_DISCUSSION:-<number>}"
  elif [[ -n "${input}" ]]; then
    # Fully-qualified so a report filed in one repository still points
    # unambiguously at the item being worked on in another one.
    label="${owner}/${repo}#${input} (invoked as \`conahcnuj ${input}\`)"
    rerun="conahcnuj ${input}"
  else
    label="unknown (no issue/PR number was given; repository: ${owner}/${repo})"
    rerun="conahcnuj <issue-or-pr-number>"
  fi
  if [[ "${ENVIRONMENT_DOWN}" == "1" ]]; then
    # #149: when every round died on an unreachable provider there is no driver
    # defect to look for, so the report says the environment, not the driver.
    intro="The conahcnuj driver stopped early: every model round died on an environment error (provider unreachable or credentials rejected), so no model ever got to work. This report was filed automatically to record the failed run (re-run: \`${rerun}\`)."
    closing="Nothing in the log below points at a driver defect: the run's providers were unreachable or their credentials were rejected for the whole run. Re-run the driver once its providers are reachable."
  elif [[ "${occurrence}" == "again" ]]; then
    intro="The conahcnuj driver terminated abnormally again on this failure, so this occurrence is appended to the existing thread instead of opening a new one (re-run: \`${rerun}\`)."
    closing="This thread collects every occurrence of the same failure: a repeat is appended as a reply. The driver exits this way only when it is unable to finish the run; a maintainer should investigate and pick the report up."
  else
    intro="The conahcnuj driver terminated abnormally and could not resolve the item it was working on. This report was filed automatically so the driver bug can be fixed (re-run: \`${rerun}\`)."
    closing="This thread collects every occurrence of the same failure: a repeat is appended as a reply. The driver exits this way only when it is unable to finish the run; a maintainer should investigate and pick the report up."
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
${intro}

## Occurrence

- Exit code: ${code} (how the conahcnuj driver process itself exited)
- Ended at: ${ended:-unknown}

## Context

- Target: ${label}
- Branch: ${branch:-unknown}
- HEAD: ${oid:-unknown}

## Error log

${log_block}

${closing}
EOF
}

# EXIT trap. The exit code is captured in the trap string ($? is not preserved
# inside a function call), so the report always knows why the run died; on a
# successful run (code 0) the report does nothing, so the happy-path flow tests
# need no extra tape entry. The trap must never change the exit code.
report_bug_on_exit() {
  local code="${1:-}"
  local owner="nahcnuj" repo="conahcnuj" input="${BUG_REPORT_INPUT:-}"
  local branch oid title body existing created number url discussion_id
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
  title="$(report_bug_title "${input}")"
  echo "Driver exited abnormally (code ${code}); filing a bug report in ${owner}/${repo} discussions (category: ${BUG_REPORT_CATEGORY})." >&2

  # Same kind of failure => same thread. An identical title means this failure
  # was already reported, so append the occurrence instead of starting a second
  # thread on the same bug.
  existing="$(gh_api_find_discussion_by_title "${owner}" "${repo}" "${BUG_REPORT_CATEGORY}" "${title}" || true)"
  if [[ -n "${existing}" ]]; then
    number="${existing%%|*}"
    discussion_id="$(printf '%s' "${existing}" | cut -d'|' -f2)"
    url="$(printf '%s' "${existing}" | cut -d'|' -f3)"
    body="$(report_bug_body "${code}" "${owner}" "${repo}" "${input}" "${branch}" "${oid}" "again")"
    if gh_api_reply_discussion "${owner}" "${repo}" "${discussion_id}" "${body}" >/dev/null; then
      echo "Bug report appended to discussion #${number}: ${url}" >&2
      BUG_REPORTED="1"
      run_log_cleanup
      return 0
    fi
    echo "WARNING: could not append the bug report to discussion #${number} (exit code ${code})." >&2
    BUG_REPORTED="1"
    run_log_cleanup
    return 0
  fi

  body="$(report_bug_body "${code}" "${owner}" "${repo}" "${input}" "${branch}" "${oid}" "first")"
  if created="$(gh_api_create_discussion "${owner}" "${repo}" "${BUG_REPORT_CATEGORY}" "${title}" "${body}")" && [[ -n "${created}" ]]; then
    number="${created%%|*}"
    url="${created#*|}"
    echo "Bug report discussion #${number} created: ${url}" >&2
    BUG_REPORTED="1"
    run_log_cleanup
    return 0
  fi
  echo "WARNING: could not file a bug report discussion (exit code ${code})." >&2
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

# Fetch <branch> from origin and check out its head. A failed fetch stops the
# run instead of falling back to whatever origin/<branch> happens to hold: such
# a checkout "succeeds" at a stale commit, the driver then reads the branch as
# "not implemented yet" and hands a fresh implementation round to a model, which
# re-implements what is already committed and commits that second copy on top of
# the real branch head. A lost branch head is far more expensive than a stopped
# run (the stopped run files a bug report, issue #115).
checkout_branch_head() {
  local branch="${1}"
  # git's own output goes to stderr: callers capture this script's stdout, and
  # `git checkout -B <b> origin/<b>` prints "branch '<b>' set up to track ..."
  # to stdout, which would be captured as part of a branch name.
  if ! git fetch origin "${branch}" 1>&2; then
    echo "ERROR: could not fetch ${branch} from origin; refusing to work on a stale branch head." >&2
    return 1
  fi
  git checkout -B "${branch}" "origin/${branch}" 1>&2
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
  # name, so every git command must keep its own output off stdout (checkout_branch_head
  # sends git's output to stderr).
  if git rev-parse --verify -q "origin/${branch}" >/dev/null 2>&1; then
    # `|| return 1` rather than relying on errexit: this function runs inside a
    # command substitution, where bash does not honour it, and every command
    # after the checkout would otherwise run on the stale head.
    checkout_branch_head "${branch}" || return 1
    echo "Using existing feature branch ${branch} (resume)." >&2
  else
    gh_api_create_branch "${owner}" "${repo}" "${branch}" "${default_oid}" >/dev/null 2>&1 || echo "WARNING: branch create returned an error for ${branch}; will try to fetch it." >&2
    checkout_branch_head "${branch}" || return 1
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
  checkout_branch_head "${head}"
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

# --- collected context ------------------------------------------------------

# Gather the material the first model round would otherwise have to look up
# itself, so a run starts from what is already known: the review threads a
# resumed PR still has open, and the orientation files of the checkout
# (README.md / AGENTS.md by default; CONAHCNUJ_CONTEXT_FILES takes a
# space-separated list, an explicitly empty value sends no files). Only
# deterministically collectable information goes in - the prompt labels it
# Collected context and shows it as data, never as instruction, so the agent
# contract stays the single paragraph that says how to work. Read after the
# branch checkout: the files must come from the head the agent will work on.
# Args: owner repo [pr]. Prints the sections; empty when there is nothing.
collect_initial_context() {
  local owner="${1}" repo="${2}" pr="${3:-}"
  local out="" labels="" rv payload raw threads
  if [[ -n "${pr}" ]]; then
    rv="$(gh_api_fetch_reviews "${owner}" "${repo}" "${pr}")"
    payload="$(printf '%s' "${rv}" | cut -d'|' -f2)"
    raw="$(gh_api_unb64 "${payload}")"
    threads="$(printf '%s' "${raw}" | gh_api_unresolved_threads)"
    if [[ -n "${threads}" ]]; then
      out="Unresolved review threads on PR #${pr}:
${threads}"
      labels="unresolved review threads of PR #${pr}"
    fi
  fi

  local file_list file content
  # No colon in the expansion: an explicitly empty CONAHCNUJ_CONTEXT_FILES
  # means "collect no files at all", while an unset one keeps the default.
  file_list="${CONAHCNUJ_CONTEXT_FILES-README.md AGENTS.md}"
  while IFS= read -r file; do
    [[ -f "${file}" ]] || continue
    content="$(cat -- "${file}")"
    [[ -n "${content}" ]] || continue
    if [[ -n "${out}" ]]; then
      out="${out}

"
    fi
    out="${out}${file}:
${content}"
    labels="${labels:+${labels}, }${file}"
  done < <(printf '%s\n' "${file_list}" | tr ' ' '\n')

  echo "Collected context up front: ${labels:-nothing}" >&2
  printf '%s\n' "${out}"
}

# --- implementation ---------------------------------------------------------

# Run opencode until one model completes the work. A failed model hands its
# session and working tree to the next model. Records tried models and handoffs.
# A model that left the tree untouched and only wrote .commit-msg is logged as
# such, because the run log is where that shows up.
#
# A round that dies on an environment error (provider unreachable, credentials
# rejected) says nothing about the model: no other model of the same provider
# can reach it either, so the provider is given up on and its remaining models
# are skipped. When every failure was environmental, the run ends with that
# diagnosis and the bug report says so, instead of blaming the driver for an
# environment that was down all along (#149).
implement() {
  local title="${1}" body="${2}" extra="${3:-}" workdir model previous_model="" run_failed run_timeout now wrote_message provider
  local dead_providers="" failed_rounds=0 env_failed_rounds=0 ran_without_failure=0
  ENVIRONMENT_DOWN="0"
  workdir="$(pwd)"
  echo "Implementing with available models..." >&2
  OPENCODE_USED_MODELS=""
  OPENCODE_HANDOFFS=""
  OPENCODE_SESSION_ID=""
  for model in $(opencode_get_models); do
    [[ -z "${model}" ]] && continue
    check_timeout
    provider="${model%%/*}"
    if [[ " ${dead_providers} " == *" ${provider} "* ]]; then
      echo "Skipping ${model}: provider ${provider} already failed on an environment error, and no other of its models can change that." >&2
      continue
    fi
    now="$(date +%s)"
    run_timeout=$((MAX_DURATION - (now - START_TIME) - 30))
    (( run_timeout > 0 )) || run_timeout=1
    if [[ -n "${OPENCODE_SESSION_ID}" ]]; then
      echo "Handing off session ${OPENCODE_SESSION_ID} from ${previous_model} to ${model}." >&2
      OPENCODE_HANDOFFS="${OPENCODE_HANDOFFS}${previous_model}->${model} "
    elif [[ -n "${previous_model}" ]]; then
      echo "Session handoff was unavailable after ${previous_model}; ${model} will continue from the working tree." >&2
    fi
    run_failed="false"
    if ! CONAHCNUJ_RUN_TIMEOUT_SECONDS="${run_timeout}" opencode_run "${title}" "${body}" "${workdir}" "${model}" "${extra}" "${OPENCODE_SESSION_ID}" "${previous_model}" "${COLLECTED_CONTEXT}"; then
      run_failed="true"
    fi
    OPENCODE_USED_MODELS="${OPENCODE_USED_MODELS}${model} "
    wrote_message="false"
    if [[ -s "${workdir}/.commit-msg" ]]; then
      wrote_message="true"
    fi
    if workdir_changed "${workdir}" && [[ "${wrote_message}" == "true" ]]; then
      echo "Model ${model} completed the work." >&2
      OPENCODE_LAST_MODEL="${model}"
      return 0
    fi
    rm -f "${workdir}/.commit-msg"
    previous_model="${model}"
    if [[ "${run_failed}" == "true" ]]; then
      failed_rounds=$((failed_rounds + 1))
      if [[ "${OPENCODE_ROUND_ENVIRONMENT}" == "true" ]]; then
        env_failed_rounds=$((env_failed_rounds + 1))
        dead_providers="${dead_providers} ${provider}"
        echo "Model ${model} failed before completing the work: environment error (provider unreachable or credentials rejected); giving up on provider ${provider} for the rest of this run." >&2
      else
        echo "Model ${model} failed before completing the work; handing off to the next model." >&2
      fi
    else
      ran_without_failure=$((ran_without_failure + 1))
      if [[ "${wrote_message}" == "true" ]]; then
        echo "Model ${model} left the working tree unchanged and only wrote .commit-msg; handing off to the next model." >&2
      else
        echo "Model ${model} produced no complete work; handing off to the next model." >&2
      fi
    fi
  done
  echo "ERROR: no available model completed the work (tried: ${OPENCODE_USED_MODELS:-none}; handoffs: ${OPENCODE_HANDOFFS:-none})." >&2
  if [[ "${failed_rounds}" -gt 0 && "${env_failed_rounds}" -eq "${failed_rounds}" && "${ran_without_failure}" -eq 0 ]]; then
    ENVIRONMENT_DOWN="1"
    echo "ERROR: every model round died on an environment error (provider unreachable or credentials rejected; providers given up on: ${dead_providers# }). Nothing the driver can do about that -- re-run it once its providers are reachable." >&2
  fi
  return 1
}

# --- bug report triage -------------------------------------------------------
# The counterpart of the bug report: a report is filed as a discussion, and a
# discussion triggers a triage run that investigates it and files the issue when
# the report holds up. The issue then goes through the normal flow above, so the
# triage run stops at the issue: implementation is a separate run with its own
# time budget.

# Title prefix of every issue a triage run files. issue-driver.yml lets
# bot-authored issues through under this prefix only, so a triaged report becomes
# planned work while all other bot issues stay skipped (recursion guard).
TRIAGE_ISSUE_PREFIX="conahcnuj-triage: "

# Run opencode until one model records a triage verdict: .triage-issue (the
# report is a real defect, file an issue) or .triage-verdict (file none). The
# verdict file is the triage counterpart of .commit-msg, so the driver never has
# to interpret free-form model output. Same fall-through contract as implement(),
# session handoff included, so a model that dies mid-investigation hands its
# findings to the next one.
investigate() {
  local title="${1}" body="${2}" extra="${3:-}" workdir model previous_model="" run_failed run_timeout now
  workdir="$(pwd)"
  echo "Investigating the report with available models..." >&2
  OPENCODE_USED_MODELS=""
  OPENCODE_HANDOFFS=""
  OPENCODE_SESSION_ID=""
  for model in $(opencode_get_models); do
    [[ -z "${model}" ]] && continue
    check_timeout
    now="$(date +%s)"
    run_timeout=$((MAX_DURATION - (now - START_TIME) - 30))
    (( run_timeout > 0 )) || run_timeout=1
    if [[ -n "${OPENCODE_SESSION_ID}" ]]; then
      echo "Handing off session ${OPENCODE_SESSION_ID} from ${previous_model} to ${model}." >&2
      OPENCODE_HANDOFFS="${OPENCODE_HANDOFFS}${previous_model}->${model} "
    elif [[ -n "${previous_model}" ]]; then
      echo "Session handoff was unavailable after ${previous_model}; ${model} will continue from the working tree." >&2
    fi
    run_failed="false"
    if ! CONAHCNUJ_RUN_TIMEOUT_SECONDS="${run_timeout}" opencode_run "${title}" "${body}" "${workdir}" "${model}" "${extra}" "${OPENCODE_SESSION_ID}" "${previous_model}" "" "triage"; then
      run_failed="true"
    fi
    OPENCODE_USED_MODELS="${OPENCODE_USED_MODELS}${model} "
    if [[ -s "${workdir}/.triage-issue" || -s "${workdir}/.triage-verdict" ]]; then
      echo "Model ${model} completed the investigation." >&2
      OPENCODE_LAST_MODEL="${model}"
      return 0
    fi
    # No verdict is not a verdict: drop whatever partial file was left so the
    # next model starts from a clean slate.
    rm -f "${workdir}/.triage-issue" "${workdir}/.triage-verdict"
    previous_model="${model}"
    if [[ "${run_failed}" == "true" ]]; then
      echo "Model ${model} failed before recording a verdict; handing off to the next model." >&2
    else
      echo "Model ${model} recorded no verdict; handing off to the next model." >&2
    fi
  done
  echo "ERROR: no available model recorded a triage verdict (tried: ${OPENCODE_USED_MODELS:-none}; handoffs: ${OPENCODE_HANDOFFS:-none})." >&2
  return 1
}

# Reply posted on the thread when the investigation filed an issue. The marker is
# what makes triage idempotent: a later run reads it back from the thread's
# comments (gh_api_fetch_discussion) and refuses to file a second issue.
triage_issue_reply() {
  local number="${1}" url="${2}" title="${3}"
  cat <<EOF
<!-- conahcnuj:triage issue=${number} -->
The conahcnuj driver investigated this report and filed [issue #${number}](${url}): ${title}

The issue carries the findings of the investigation and is worked on like any other issue here: the driver opens a pull request for it and asks a human reviewer for approval before anything is merged.

Reply in this thread if the report needs correcting; the issue is where the fix is tracked.
EOF
}

# Reply posted on the thread when the investigation filed nothing. No `issue=`
# marker, so a re-run may look at the report again (useful after someone adds
# the missing details a needs-information verdict asks for).
triage_verdict_reply() {
  local verdict="${1}" reasoning="${2}"
  cat <<EOF
<!-- conahcnuj:triage verdict=${verdict} -->
The conahcnuj driver investigated this report and filed no issue for it.

${reasoning}

If this verdict is wrong, add what is missing in this thread: a later run investigates the report again.
EOF
}

# Investigate one bug-report discussion and act on the verdict.
# Args: owner repo discussion number
triage_discussion() {
  local owner="${1}" repo="${2}" num="${3}"
  local discussion title_b64 body_b64 url category id triaged title body
  discussion="$(gh_api_fetch_discussion "${owner}" "${repo}" "${num}")" || {
    echo "ERROR: could not read discussion #${num} of ${owner}/${repo}." >&2
    exit 1
  }
  title_b64="$(printf '%s' "${discussion}" | cut -d'|' -f1)"
  body_b64="$(printf '%s' "${discussion}" | cut -d'|' -f2)"
  url="$(printf '%s' "${discussion}" | cut -d'|' -f3)"
  category="$(printf '%s' "${discussion}" | cut -d'|' -f4)"
  id="$(printf '%s' "${discussion}" | cut -d'|' -f5)"
  triaged="$(printf '%s' "${discussion}" | cut -d'|' -f6)"
  title="$(gh_api_unb64 "${title_b64}")"
  body="$(gh_api_unb64 "${body_b64}")"

  if [[ -z "${id}" ]]; then
    echo "ERROR: discussion #${num} does not exist in ${owner}/${repo}." >&2
    exit 1
  fi
  # Only bug reports are triaged. The workflow filters on the category too; this
  # keeps a manual run from turning an unrelated thread into an issue.
  if [[ "${category,,}" != "${BUG_REPORT_CATEGORY,,}" ]]; then
    echo "Discussion #${num} is in the '${category}' category, not '${BUG_REPORT_CATEGORY}'; nothing to triage." >&2
    exit 0
  fi
  if [[ -n "${triaged}" && "${triaged}" != "0" ]]; then
    echo "Discussion #${num} was already triaged into issue #${triaged}; nothing to do." >&2
    exit 0
  fi

  echo "Discussion #${num}: ${title}" >&2
  echo "Discussion: ${url}" >&2
  if ! investigate "${title}" "${body}" "The report lives at ${url} (bug report discussion #${num} in ${owner}/${repo}). Quote it when you describe the defect.

Look at the open issues and pull requests before concluding that the defect is new: when one of them already tracks the same defect (a report about a driver failure that is itself still open, for instance), answer already-tracked with that reference instead of filing a duplicate."; then
    echo "ERROR: could not investigate discussion #${num} with any available model." >&2
    exit 1
  fi

  local model="${OPENCODE_LAST_MODEL:-unknown}" reply
  if [[ -s ".triage-issue" ]]; then
    local issue_title issue_body number issue_url
    issue_title="$(head -n 1 .triage-issue | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    # Everything after the title line is the issue body. Trailing whitespace and
    # the blank line the agent left under the title are dropped; blank lines
    # inside the body are kept (markdown needs them).
    issue_body="$(tail -n +2 .triage-issue | sed -e 's/[[:space:]]*$//' -e '/./,$!d')"
    rm -f .triage-issue .triage-verdict
    if [[ -z "${issue_title}" ]]; then
      echo "ERROR: the investigation produced an issue without a title; nothing can be filed." >&2
      exit 1
    fi
    issue_body="${issue_body}

---

Reported in the Bug report discussion: ${url}

_Filed automatically by the conahcnuj triage run (model: ${model}). The discussion thread keeps the original report; the investigation above is what this issue is based on._"
    if ! number="$(gh_api_create_issue "${owner}" "${repo}" "${TRIAGE_ISSUE_PREFIX}${issue_title}" "${issue_body}")" || [[ -z "${number}" ]]; then
      echo "ERROR: could not file an issue for discussion #${num}." >&2
      exit 1
    fi
    issue_url="https://github.com/${owner}/${repo}/issues/${number}"
    echo "Filed issue #${number} for discussion #${num}: ${issue_url}" >&2
    # The reply carries the triage marker, so it is what makes the next run skip
    # this thread; an empty comment id means it did not land.
    reply="$(gh_api_reply_discussion "${owner}" "${repo}" "${id}" "$(triage_issue_reply "${number}" "${issue_url}" "${issue_title}")" || true)"
    if [[ -n "${reply}" ]]; then
      echo "Replied on discussion #${num} with the issue link." >&2
    else
      echo "WARNING: could not reply on discussion #${num}; the issue is #${number}, but the next triage run would not see it as handled." >&2
    fi
    exit 0
  fi

  if [[ -s ".triage-verdict" ]]; then
    local verdict reasoning
    verdict="$(head -n 1 .triage-verdict | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    reasoning="$(tail -n +2 .triage-verdict | sed -e 's/[[:space:]]*$//' -e '/./,$!d')"
    rm -f .triage-issue .triage-verdict
    if [[ -z "${verdict}" ]]; then
      echo "ERROR: the investigation recorded a verdict without a label; posting it as-is is not useful." >&2
      exit 1
    fi
    echo "Verdict for discussion #${num}: ${verdict} (no issue filed)." >&2
    reply="$(gh_api_reply_discussion "${owner}" "${repo}" "${id}" "$(triage_verdict_reply "${verdict}" "${reasoning}")" || true)"
    if [[ -n "${reply}" ]]; then
      echo "Replied on discussion #${num} with the verdict." >&2
    else
      echo "WARNING: could not reply on discussion #${num} with the verdict." >&2
    fi
    exit 0
  fi

  echo "ERROR: the investigation left neither .triage-issue nor .triage-verdict." >&2
  exit 1
}

# --- PR lifecycle -----------------------------------------------------------

post_pr_continuation_comment() {
  local owner="${1}" repo="${2}" pr="${3}"
  if gh_api_post_comment "${owner}" "${repo}" "${pr}" "<!-- conahcnuj-continuation -->
PR #${pr} の処理を継続するには、Issue auto-drive を手動実行してください。

[継続するにはこちらをクリック](https://github.com/${owner}/${repo}/actions/workflows/issue-driver.yml/dispatch?inputs%5Bnumber%5D=${pr})" >/dev/null; then
    return 0
  fi
  echo "WARNING: could not post the continuation comment for PR #${pr}." >&2
  return 1
}

# Remove standalone closing-reference lines ("Closes #<n>", "Fixes #<n>",
# "Resolves #<n>", also comma-separated lists) from a body and collapse the
# blank lines the removal leaves behind, so the driver's own single
# "Closes #<n>" prefix is the only closing reference in the PR body (#143).
strip_closing_references() {
  printf '%s\n' "${1}" | sed -E '/^[[:space:]]*([Cc]lose[sd]?|[Ff]ix(e[sd])?|[Rr]esolve[sd]?)[[:space:]]+#[0-9]+([[:space:]]*,[[:space:]]*#[0-9]+)*[[:space:]]*$/d' | awk '/^$/{blank++; if(blank>1) next; print; next} {blank=0; print}'
}

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
    # Drop closing-reference lines the issue body may already carry so the PR
    # body has exactly one "Closes #<n>" (#143).
    body="$(strip_closing_references "${body}")"
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
# Returns 0 when passable now, 1 when the PR needs new work. Exits when the PR
# left the open state while we were waiting: there is nothing left to drive then,
# and polling on would only end in a spurious bug report.
poll_conditions() {
  local owner="${1}" repo="${2}" pr="${3}"
  while true; do
    check_timeout
    local cond state mergeable mss pr_state
    cond="$(gh_api_fetch_pr_conditions "${owner}" "${repo}" "${pr}")"
    state="$(printf '%s' "${cond}" | cut -d'|' -f1)"
    mergeable="$(printf '%s' "${cond}" | cut -d'|' -f2)"
    mss="$(printf '%s' "${cond}" | cut -d'|' -f3)"
    pr_state="$(printf '%s' "${cond}" | cut -d'|' -f4)"
    echo "PR #${pr} constraints: checks=${state} mergeable=${mergeable} mergeState=${mss}" >&2
    # The auto-merge workflow merges the PR once CI is green and no longer
    # waits for this run's own check, so the PR can be merged out from under
    # the poll. Report that as the end of the road instead of looping on a PR
    # that can never become MERGEABLE again.
    case "${pr_state}" in
      MERGED)
        echo "PR #${pr} is merged while waiting; nothing left to do." >&2
        exit 0
        ;;
      CLOSED)
        echo "PR #${pr} is closed without merge while waiting; nothing left to do." >&2
        exit 1
        ;;
    esac
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

# Hand the PR over to a human: the repository owner is assigned as reviewer,
# which is the last deliverable of a run. A reviewer who cannot be assigned
# (GitHub refuses e.g. the author of the PR) or a request that is already
# pending must not fail the run, so fall back to the unnamed ask-for-review.
# Each attempt is retried once: the endpoint is idempotent (asking for the same
# reviewer twice records no second request), and a single failure is not proof
# of anything — a transport error or a 5xx that arrives after GitHub recorded
# the request is indistinguishable from a refusal. Both POSTs reporting a
# failure is not proof that nobody was asked either, so the PR is read back
# before the hand-off is called lost: issue #134 died with "could not request
# review" on a PR GitHub had just recorded a review_requested event for, and
# issue #139 died the same way two minutes after GitHub had recorded the owner
# as the reviewer of PR #138 — a run whose work was complete, reported as a
# driver failure. Args: owner repo pr
request_review_from_owner() {
  local owner="${1}" repo="${2}" pr="${3}" requested="" read_state="answered"
  REVIEW_HANDOFF_CONFIRMED="true"
  if request_review_with_retry "${owner}" "${repo}" "${pr}" "${owner}"; then
    echo "Assigned ${owner} as reviewer on PR #${pr}." >&2
    return 0
  fi
  if request_review_with_retry "${owner}" "${repo}" "${pr}"; then
    echo "Review requested on PR #${pr} (${owner} is not assignable; asked for review instead)." >&2
    return 0
  fi
  # Reading the PR back is the only remaining evidence. Its answer has to be
  # read for what it is: a reviewer listed means the hand-off happened, an empty
  # answer means GitHub really has nobody asked, and an unreadable PR means the
  # driver cannot tell the two apart. Only the empty answer is proof of a lost
  # hand-off, so only that fails the run.
  if ! requested="$(gh_api_requested_reviewers "${owner}" "${repo}" "${pr}" 2>/dev/null)"; then
    read_state="unreadable"
  fi
  if [[ -n "${requested}" ]]; then
    echo "Review already requested on PR #${pr} (${requested//$'\n'/, }); the request call reported a failure but GitHub has it, so the hand-off is done." >&2
    return 0
  fi
  if [[ "${read_state}" == "unreadable" ]]; then
    REVIEW_HANDOFF_CONFIRMED="false"
    echo "WARNING: no review request on PR #${pr} was accepted and the PR could not be read back either, so nobody can be confirmed as asked. The PR is complete and waits for a human, so the run ends here instead of filing a bug report for an unverifiable hand-off." >&2
    return 0
  fi
  echo "ERROR: could not request review on PR #${pr}." >&2
  return 1
}

# One review-request call, retried once after a short pause. stderr is kept so
# gh_api_call's "-> <status>: <body>" reaches the run log: without it a failed
# hand-off explains nothing in the bug report. Args: owner repo pr [reviewer]
request_review_with_retry() {
  local owner="${1}" repo="${2}" pr="${3}" reviewer="${4:-}" attempt
  for attempt in 1 2; do
    if gh_api_request_review "${owner}" "${repo}" "${pr}" "${reviewer}" >/dev/null; then
      return 0
    fi
    if [[ "${attempt}" -eq 1 ]]; then
      echo "Review request on PR #${pr} reported a failure; retrying once." >&2
      hand_off_retry_pause
    fi
  done
  return 1
}

# Pause before the review-request retry. Offline runs never sleep, and 0 (or any
# value that is not a number) disables the pause.
hand_off_retry_pause() {
  local seconds="${CONAHCNUJ_HANDOFF_RETRY_SECONDS:-15}"
  if [[ "${TEST_MODE}" == "1" ]]; then
    return 0
  fi
  if [[ "${seconds}" =~ ^[0-9]+$ ]] && (( seconds > 0 )); then
    sleep "${seconds}"
  fi
  return 0
}

# Final line of a run whose PR now waits on a human reviewer. The wording
# depends on whether the reviewer assignment was actually confirmed, so the log
# never claims a request that the run could not verify.
log_review_handoff() {
  local owner="${1}" repo="${2}" pr="${3}" reviewer="${4}"
  if [[ "${REVIEW_HANDOFF_CONFIRMED}" == "true" ]]; then
    echo "Review requested on PR #${pr} (reviewer: ${reviewer}): https://github.com/${owner}/${repo}/pull/${pr}" >&2
  else
    echo "PR #${pr} is ready for a human reviewer: https://github.com/${owner}/${repo}/pull/${pr}" >&2
  fi
}

# --- review fingerprint -----------------------------------------------------

# Main state machine. Handles both the fresh-issue path and the resume path.
# Never auto-merges, and never waits for an approval: it exits once the review
# request is on the PR ("ready to merge" when the PR is already APPROVED).
drive() {
  local owner="${1}" repo="${2}" pr="${3}" branch="${4}" base="${5}" title="${6}" body="${7}" closes="${8}"
  local last_sig=""

  while true; do
    check_timeout

    # Commit leftovers from a previously interrupted run. Only possible while
    # the interrupted run's agent had already written its .commit-msg: the
    # driver never invents a commit message, so a dirty tree without one (e.g.
    # when the branch is resumed / already implemented and no implement round
    # ran in this process, leaving scratch files behind) has nothing the driver
    # may commit. It keeps polling the PR instead of crashing over files it was
    # never asked to commit.
    if workdir_changed "$(pwd)" && [[ -f ".commit-msg" ]]; then
      commit_changes
      # After committing our own fix, wait for CI to re-run instead of
      # immediately trying to implement (which would fail if nothing changed).
      continue
    fi

    if ! pr="$(ensure_pr "${owner}" "${repo}" "${pr}" "${branch}" "${base}" "${title}" "${body}" "${closes}")"; then
      # PR creation failed (GitHub refuses a PR with no diff between base and
      # head, a vanished head ref, ...). There is nothing to gain by retrying
      # as-is, so run an implementation round to give the branch real work and
      # loop back. Dying here would just file the recursive "failed to resolve
      # #N" bug report chain (issues #33/#34).
      echo "PR could not be created for ${branch} -> ${base}; running an implementation round." >&2
      local produced_change="false"
      if implement "${title}" "${body}" "The pull request for ${branch} could not be opened; GitHub rejects a PR with no changes between the branches. Make a real change so the PR can be created."; then
        produced_change="true"
      fi
      if workdir_changed "$(pwd)"; then
        commit_changes
        produced_change="true"
      fi
      if [[ "${produced_change}" != "true" ]]; then
        echo "No changes could be produced to open the PR; backing off before retrying." >&2
        rate_limit_poll_sleep "${POLL_CONDITIONS_MIN}" "${POLL_CONDITIONS_MAX}"
      fi
      continue
    fi

    if ! pr_continuation_commented; then
      if post_pr_continuation_comment "${owner}" "${repo}" "${pr}"; then
        pr_continuation_mark_commented
      fi
    fi

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
        echo "No model completed work for the failing constraints; backing off before re-checking." >&2
        rate_limit_poll_sleep "${POLL_CONDITIONS_MIN}" "${POLL_CONDITIONS_MAX}"
      fi
      continue
    fi

    echo "PR #${pr}: non-reviewer constraints satisfied." >&2

    # --- review phase ---
    # Asking for review is what a run hands over to a human, so the review
    # request (not an approval) is the last thing the driver produces. The
    # approval, and the merge owner-approved-auto-merge chains off it, are the
    # reviewer's part to give: the driver reports and exits instead of polling.
    local rv decision payload raw summary sig actionable
    rv="$(gh_api_fetch_reviews "${owner}" "${repo}" "${pr}")"
    decision="$(printf '%s' "${rv}" | cut -d'|' -f1)"
    payload="$(printf '%s' "${rv}" | cut -d'|' -f2)"
    raw="$(gh_api_unb64 "${payload}")"
    summary="$(printf '%s' "${raw}" | gh_api_review_summary)"
    sig="$(gh_api_review_fingerprint "${raw}")"
    echo "reviewDecision: ${decision:-NONE}" >&2

    if [[ "${decision}" == "APPROVED" ]]; then
      echo "Ready to merge: https://github.com/${owner}/${repo}/pull/${pr}" >&2
      exit 0
    fi

    actionable="false"
    case "${decision}" in
      CHANGES_REQUESTED|COMMENTED|REVIEW_REQUIRED|"") actionable="true" ;;
    esac

    if [[ "${actionable}" == "true" && -n "${sig}" && "${sig}" != "${last_sig}" ]]; then
      last_sig="${sig}"
      echo "New review feedback detected; addressing it." >&2
      # The coding agent answers the reviewer in the thread itself (the reply
      # endpoint and every thread comment id are in the summary), besides any
      # code change the feedback asks for. The driver no longer posts its own
      # "Addressed the review feedback" comment: the in-thread replies are how
      # the reviewer learns what happened. Because the fingerprint drops
      # bot-authored comments, those replies never look like fresh feedback.
      local reply_help="Address the pull request review feedback. Reply in each unresolved thread below, saying what you changed or answering the question. Post the reply with the GitHub API (POST https://api.github.com/repos/${owner}/${repo}/pulls/${pr}/comments/<comment_id>/replies is the reply endpoint; \${GH_TOKEN} is set) using the comment id shown for each thread, and make code changes where the feedback asks for them."
      if ! implement "${title}" "${body}" "${reply_help}

${summary}"; then
        echo "No working-tree change was produced for this feedback; keeping whatever thread replies were already made." >&2
      fi
      if workdir_changed "$(pwd)"; then
        commit_changes
      fi
      # Hand the PR back to the reviewer before polling the non-reviewer
      # constraints: the reviewer can start looking at the replies the moment
      # the round is over, and the constraints are re-verified while they do.
      request_review_from_owner "${owner}" "${repo}" "${pr}" || exit 1
      if ! poll_conditions "${owner}" "${repo}" "${pr}"; then
        echo "Constraints failing after addressing feedback; fixing next cycle." >&2
        continue
      fi
      log_review_handoff "${owner}" "${repo}" "${pr}" "${owner}"
      exit 0
    fi

    request_review_from_owner "${owner}" "${repo}" "${pr}" || exit 1
    log_review_handoff "${owner}" "${repo}" "${pr}" "${owner}"
    exit 0
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

  # Only after the checkout, so the files below are read from the head the
  # agent will work on. An issue has no PR yet, hence no review threads.
  COLLECTED_CONTEXT="$(collect_initial_context "${owner}" "${repo}")"

  # An earlier run may have already committed the implementation to this
  # branch. In that case there is nothing left to implement, so skip the
  # model fall-through and go straight to opening the PR for review. This is
  # what keeps the driver from spinning through every model asking for work
  # that is already done.
  if branch_has_commits "${default_oid}" "${default_branch}"; then
    echo "Branch ${branch} already has commits; skipping implement and opening the PR." >&2
  elif workdir_changed "$(pwd)" && [[ -f ".commit-msg" ]]; then
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
      iss_body="$(strip_closing_references "${iss_body}")"
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
  # The PR's still-open review threads are gathered here, once, instead of
  # waiting for the review phase to hand them over mid-run.
  COLLECTED_CONTEXT="$(collect_initial_context "${owner}" "${repo}" "${pr}")"
  drive "${owner}" "${repo}" "${pr}" "${head}" "${base}" "${title}" "${body}" "${closes}"
}

main() {
  # On Windows, re-run under the configured Git Bash when this shell is WSL
  # (see driver_relaunch) so every helper shares the same path space.
  if driver_needs_relaunch; then
    driver_relaunch "$@" || true
  fi

  if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <issue-or-pr-number> | $0 --discussion <discussion-number>" >&2
    exit 1
  fi
  # --discussion triages a bug-report discussion instead of resolving an issue.
  # Parsed before repo_detect so a bad option never starts a run.
  local mode="issue" input="${1}"
  if [[ "${input}" == "--discussion" ]]; then
    mode="discussion"
    input="${2:-}"
    if ! [[ "${input}" =~ ^[1-9][0-9]*$ ]]; then
      echo "Usage: $0 --discussion <discussion-number> (got: '${2:-}')" >&2
      exit 1
    fi
  elif [[ "${input}" == -* ]]; then
    echo "Unknown option: ${input}" >&2
    exit 1
  elif ! [[ "${input}" =~ ^[1-9][0-9]*$ ]]; then
    echo "Not an issue, pull request or discussion number: ${input}" >&2
    exit 1
  fi

  local repo_info owner repo
  repo_info="$(repo_detect)"
  owner="${repo_info%%/*}"
  repo="${repo_info#*/}"
  echo "Repository: ${owner}/${repo}" >&2

  # File a bug report discussion when the run terminates abnormally. Registered
  # only once owner/repo and the input are known: a usage error or a failed
  # repo detection has no target to report to and stays quiet.
  BUG_REPORT_INPUT="${input}"
  BUG_REPORT_KIND="${mode}"
  if [[ "${mode}" == "discussion" ]]; then
    BUG_REPORT_INPUT=""
    BUG_REPORT_DISCUSSION="${input}"
  fi
  trap 'bug_exit_code=$?; report_bug_on_exit "${bug_exit_code}"' EXIT

  # Capture the run's stderr into a log so an abnormal exit can attach a
  # detailed error log to the bug report (see run_log_start).
  run_log_start

  if [[ "${TEST_MODE}" != "1" ]]; then
    bash "${HERE}/../gh-app/setup-git.sh"
  fi

  if [[ "${mode}" == "discussion" ]]; then
    triage_discussion "${owner}" "${repo}" "${input}"
  else
    local issue is_pr
    issue="$(gh_api_fetch_issue "${owner}" "${repo}" "${input}")"
    is_pr="$(printf '%s' "${issue}" | cut -d'|' -f4)"
    if [[ "${is_pr}" == "true" ]]; then
      echo "Input #${input} is a pull request; resuming it in place." >&2
      resume_pr "${owner}" "${repo}" "${input}"
    else
      start_issue "${owner}" "${repo}" "${input}" "${issue}"
    fi
  fi
}

# SOURCEABLE: tests set CONAHCNUJ_IMPORT=1 to source this file (instead of
# invoking main) so driver internals such as ensure_pr can be unit-tested.
if [[ "${CONAHCNUJ_IMPORT:-0}" != "1" ]]; then
  main "$@"
fi
