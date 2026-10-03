#!/usr/bin/env bash
# Owner-approved auto-merge "which checks gate the merge" test (offline).
#
# The merge job and the driver used to wait for each other's check runs: the job
# merges only once every other check on the approved head is green (the driver's
# run included) while the driver counted the job's own check as a constraint
# (issue #115). Each side now skips the other by workflow name, so the filter
# inside the workflow's outstanding_checks() is what makes the merge reachable at
# all - and it is plain jq embedded in the YAML, so this test extracts that
# program and replays recorded payloads through it.
#
# No secrets, no network. Skipped where jq is unavailable.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
WORKFLOW="${REPO}/.github/workflows/owner-approved-auto-merge.yml"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq is not installed"; exit 0; }

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT

# The jq program lives in the `run:` block of the workflow (a reusable workflow
# may not read files from the calling repository, so it cannot be a script here).
# Pull it out between the marker argument and the line that closes the pipeline;
# an extraction that finds nothing fails loudly instead of testing nothing.
marker="--arg ignore \"\$IGNORED_WORKFLOWS\""
start="$(grep -nF -- "${marker}" "${WORKFLOW}" | head -1 | cut -d: -f1)"
if [[ -z "${start}" ]]; then
  echo "FAIL: could not find the jq filter in ${WORKFLOW}" >&2
  exit 1
fi
# ")'" as a variable, so the single quote needs no quoting trickery inside awk.
needle="$(printf ")'")"
end="$(awk -v s="${start}" -v needle="${needle}" 'NR > s && index($0, needle) > 0 { print NR; exit }' "${WORKFLOW}")"
if [[ -z "${end}" ]]; then
  echo "FAIL: the jq filter in ${WORKFLOW} is not terminated as expected" >&2
  exit 1
fi
FILTER="${ROOT}/filter.jq"
# The markers are the quotes around the program: the line before the program
# ends with one, the last line of the program is ")'" (the closing paren plus the
# quote that ends the shell argument).
sed -n "${start},${end}p" "${WORKFLOW}" | sed -e "1s/^.*'//" -e "\$s/'//" > "${FILTER}"
if [[ ! -s "${FILTER}" ]]; then
  echo "FAIL: the jq filter extracted from ${WORKFLOW} is empty" >&2
  exit 1
fi

# The query has to carry what the filter reads; the REST check-runs response has
# no workflow name, which is why the job queries the rollup instead.
for field in "workflowRun" "databaseId" "workflow { name }" "on StatusContext"; do
  if ! grep -q -- "${field}" "${WORKFLOW}"; then
    echo "FAIL: the merge query no longer asks for '${field}'" >&2
    exit 1
  fi
done

SELF_RUN=37135517310
DRIVER_RUN=37135435405
CI_RUN=37135435734

# filter <payload> <self run id> <ignored workflows>
filter() {
  jq -r --arg owner nahcnuj --arg name conahcnuj --arg sha deadbeef \
    --arg self_run "${2}" --arg ignore "${3}" -f "${FILTER}" "${1}" 2>&1
}

expect() {
  local label="${1}" want="${2}" got="${3}"
  if [[ "${got}" != "${want}" ]]; then
    echo "FAIL: ${label}" >&2
    printf 'want: %s\ngot:  %s\n' "${want}" "${got}" >&2
    exit 1
  fi
  echo "${label} passed"
}

expect_contains() {
  local label="${1}" haystack="${2}" needle="${3}"
  case "${haystack}" in
    *"${needle}"*) ;;
    *)
      echo "FAIL: ${label}: '${needle}' is not in '${haystack}'" >&2
      exit 1
      ;;
  esac
  echo "${label} passed"
}

check_run() {
  printf '{"__typename":"CheckRun","name":"%s","status":"%s","conclusion":%s,"checkSuite":{"workflowRun":{"databaseId":%s,"workflow":{"name":"%s"}}}}' \
    "${1}" "${2}" "${3}" "${4}" "${5}"
}

rollup() {
  # rollup <nodes json> <"null" for a commit without checks> <hasNextPage>
  printf '{"data":{"repository":{"object":{"statusCheckRollup":%s}}}}' \
    "$(if [[ "${2}" == "null" ]]; then
        printf 'null'
      else
        printf '{"contexts":{"pageInfo":{"hasNextPage":%s},"nodes":%s}}' "${3}" "${1}"
      fi)"
}

# The state PR #117's head commit really was in: the driver's run still running,
# the merge job's own check FAILED (it had timed out waiting for the driver) and
# every CI job green. Nothing is left to wait for, so the merge must go ahead -
# this is the case that used to be impossible.
nodes="[$(check_run 'Attempt to resolve issue' IN_PROGRESS null "${DRIVER_RUN}" 'Issue auto-drive'),$(check_run 'enable / enable' COMPLETED '"FAILURE"' "${SELF_RUN}" 'Owner-approved auto-merge'),$(check_run 'Lint shell scripts (ubuntu-latest)' COMPLETED '"SUCCESS"' "${CI_RUN}" 'CI'),$(check_run 'Typecheck opencode plugin' COMPLETED '"SUCCESS"' "${CI_RUN}" 'CI')]"
rollup "${nodes}" obj false > "${ROOT}/deadlock.json"
expect "the driver and the failed merge check are not waited for" "" "$(filter "${ROOT}/deadlock.json" "${SELF_RUN}" 'Issue auto-drive')"

# This run's own check stays pending on the approved head whatever workflow it
# belongs to (a caller may name its workflow anything, even "CI").
nodes="[$(check_run 'enable / enable' IN_PROGRESS null "${SELF_RUN}" 'CI'),$(check_run 'Mock tests (no secrets / no network) (ubuntu-latest)' COMPLETED '"SUCCESS"' "${CI_RUN}" 'CI')]"
rollup "${nodes}" obj false > "${ROOT}/self.json"
expect "this run's own check is not waited for" "" "$(filter "${ROOT}/self.json" "${SELF_RUN}" 'Issue auto-drive')"

# Real CI is still the only thing that holds the merge back.
nodes="[$(check_run 'Attempt to resolve issue' IN_PROGRESS null "${DRIVER_RUN}" 'Issue auto-drive'),$(check_run 'Mock tests (no secrets / no network) (ubuntu-latest)' IN_PROGRESS null "${CI_RUN}" 'CI')]"
rollup "${nodes}" obj false > "${ROOT}/ci-pending.json"
expect "a pending CI check is waited for" \
  "$(printf 'pending\tcheck\tMock tests (no secrets / no network) (ubuntu-latest)\tIN_PROGRESS')" \
  "$(filter "${ROOT}/ci-pending.json" "${SELF_RUN}" 'Issue auto-drive')"

nodes="[$(check_run 'Attempt to resolve issue' COMPLETED '"SUCCESS"' "${DRIVER_RUN}" 'Issue auto-drive'),$(check_run 'install.ps1 deployment test' COMPLETED '"FAILURE"' "${CI_RUN}" 'CI')]"
rollup "${nodes}" obj false > "${ROOT}/ci-failed.json"
expect "a failed CI check fails the merge" \
  "$(printf 'failed\tcheck\tinstall.ps1 deployment test\tFAILURE')" \
  "$(filter "${ROOT}/ci-failed.json" "${SELF_RUN}" 'Issue auto-drive')"

# Legacy commit statuses ride in the same rollup, and a check run with no
# workflow behind it (an external app) still counts.
nodes='[{"__typename":"StatusContext","context":"ci/jenkins","state":"SUCCESS"},{"__typename":"StatusContext","context":"ci/lint","state":"PENDING"},{"__typename":"StatusContext","context":"ci/legacy","state":"FAILURE"},{"__typename":"CheckRun","name":"external linter","status":"COMPLETED","conclusion":"FAILURE","checkSuite":null}]'
rollup "${nodes}" obj false > "${ROOT}/statuses.json"
expect "commit statuses and unattributed checks still count" \
  "$(printf 'pending\tstatus\tci/lint\tPENDING\nfailed\tstatus\tci/legacy\tFAILURE\nfailed\tcheck\texternal linter\tFAILURE')" \
  "$(filter "${ROOT}/statuses.json" "${SELF_RUN}" 'Issue auto-drive')"

# A context type this jq does not know yet: wait rather than call it green.
rollup '[{"__typename":"SomethingNew","name":"future check"}]' obj false > "${ROOT}/future.json"
expect "an unknown context type is waited for" \
  "$(printf 'pending\tstatus\tfuture check\tunknown')" \
  "$(filter "${ROOT}/future.json" "${SELF_RUN}" 'Issue auto-drive')"

# Nothing enumerable means "unknown", not "green": a truncated page or a commit
# without checks must never be merged blind.
rollup '[]' null false > "${ROOT}/no-checks.json"
expect "a commit without checks is waited for" \
  "$(printf 'pending\tcheck\t(no enumerable check list)\tpending')" \
  "$(filter "${ROOT}/no-checks.json" "${SELF_RUN}" 'Issue auto-drive')"

rollup "[$(check_run 'Lint shell scripts' COMPLETED '"SUCCESS"' "${CI_RUN}" 'CI')]" obj true > "${ROOT}/paged.json"
expect "an unpageable check list is waited for" \
  "$(printf 'pending\tcheck\t(no enumerable check list)\tpending')" \
  "$(filter "${ROOT}/paged.json" "${SELF_RUN}" 'Issue auto-drive')"

# A payload without the commit at all (bad token, wrong repository, API error)
# must fail the job loudly rather than look like "no checks".
printf '{"data":{"repository":{"object":null}}}\n' > "${ROOT}/no-commit.json"
if filter "${ROOT}/no-commit.json" "${SELF_RUN}" 'Issue auto-drive' >/dev/null 2>&1; then
  echo "FAIL: a missing commit object was read as 'nothing to wait for'" >&2
  exit 1
fi
echo "a missing commit object fails the job passed"

# An empty ignore list turns the filter off again (same escape hatch the driver
# has for CONAHCNUJ_OWN_WORKFLOWS).
nodes="[$(check_run 'Attempt to resolve issue' COMPLETED '"CANCELLED"' "${DRIVER_RUN}" 'Issue auto-drive')]"
rollup "${nodes}" obj false > "${ROOT}/cancelled.json"
expect "an empty ignore list waits for the driver after all" \
  "$(printf 'failed\tcheck\tAttempt to resolve issue\tCANCELLED')" \
  "$(filter "${ROOT}/cancelled.json" "${SELF_RUN}" '')"

# Both sides of the deadlock have to keep skipping each other. Read the defaults
# straight out of the sources, so a rename on one side fails here instead of
# deadlocking the next run.
driver_marker="CONAHCNUJ_OWN_WORKFLOWS=\"\${CONAHCNUJ_OWN_WORKFLOWS-"
merge_marker="IGNORED_WORKFLOWS=\"\${IGNORED_WORKFLOWS:-"
driver_defaults="$(grep -m1 -F -- "${driver_marker}" "${REPO}/lib/gh-api.sh")"
merge_defaults="$(grep -m1 -F -- "${merge_marker}" "${WORKFLOW}")"
driver_list="${driver_defaults#*"CONAHCNUJ_OWN_WORKFLOWS-"}"
driver_list="${driver_list%\"}}"
merge_list="${merge_defaults#*"${merge_marker#*IGNORED_WORKFLOWS=}"}"
merge_list="${merge_list%\"}}"
if [[ -z "${driver_list}" || -z "${merge_list}" ]]; then
  echo "FAIL: could not read the skipped-workflow defaults (driver: '${driver_list}', merge: '${merge_list}')" >&2
  exit 1
fi
# The driver may not wait for the merge job's run and the merge job may not wait
# for the driver's: that is the whole deadlock. Both directions are asserted, and
# the fixtures above prove each skip actually drops the check. The merge job does
# not need itself in its own ignore list - its check is already excluded by run id.
expect_contains "the driver skips the merge job's workflow" "${driver_defaults}" "Owner-approved auto-merge"
expect_contains "the driver skips its own workflow" "${driver_defaults}" "Issue auto-drive"
expect_contains "the merge job skips the driver's workflow" "${merge_defaults}" "Issue auto-drive"
echo "both sides skip the same workflows passed"

echo "auto-merge outstanding-checks filter passed"