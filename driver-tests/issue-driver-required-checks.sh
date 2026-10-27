#!/usr/bin/env bash
# Issue auto-drive "resume on a failed required check" test (offline).
#
# The driver resumes a PR whose required checks failed, but only if the workflow
# is wired to start it on that event. The wiring is declarative YAML, so this
# test pins the semantics that matter:
#   - the `on` side watches the CI workflow's `completed` run (the required
#     checks come from CI), not check_run / check_suite, which also fire for
#     this driver's own run and would recurse;
#   - the job `if` lets the run through only for a failed, pull_request-driven CI
#     run whose head is in this repository;
#   - CONAHCNUJ_INPUT (and the concurrency group) map the workflow_run's pull
#     request number, so the driver resumes the right PR.
#
# No secrets, no network.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
WORKFLOW="${REPO}/.github/workflows/issue-driver.yml"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[[ -f "${WORKFLOW}" ]] || fail "${WORKFLOW} does not exist"

# `on:` must watch the CI workflow's completion. The trigger keys sit at two
# spaces of indentation under `on:`.
grep -qE '^  workflow_run:' "${WORKFLOW}" || fail "the workflow does not trigger on workflow_run"
grep -qF 'workflows: [CI]' "${WORKFLOW}" || fail "workflow_run does not watch the CI workflow"
grep -qF 'types: [completed]' "${WORKFLOW}" || fail "workflow_run is not limited to completed runs"

# check_run / check_suite fire for the driver's own run too, so they must not be
# used as triggers (the comment may name them, the keys may not appear).
if grep -qE '^  check_run:' "${WORKFLOW}"; then
  fail "check_run is a trigger and would recurse through the driver's own run"
fi
if grep -qE '^  check_suite:' "${WORKFLOW}"; then
  fail "check_suite is a trigger and would recurse through the driver's own run"
fi

# The job `if` must gate workflow_run on a failed, pull_request-driven run of a
# same-repository branch, with a pull request to resume.
grep -qF "github.event.workflow_run.conclusion == 'failure'" "${WORKFLOW}" || fail "the job if does not require a failed CI run"
grep -qF "github.event.workflow_run.event == 'pull_request'" "${WORKFLOW}" || fail "the job if does not require a pull_request-driven CI run"
grep -qF 'github.event.workflow_run.head_repository.full_name == github.repository' "${WORKFLOW}" || fail "the job if does not keep fork pull requests out"
grep -qF 'github.event.workflow_run.pull_requests[0] != null' "${WORKFLOW}" || fail "the job if does not require a pull request to resume"

# The driver receives the PR number of the failed run.
grep -qF "github.event_name == 'workflow_run' && github.event.workflow_run.pull_requests[0].number" "${WORKFLOW}" || fail "CONAHCNUJ_INPUT / concurrency do not map the workflow_run pull request number"

echo "issue-driver required-check trigger wiring passed"
