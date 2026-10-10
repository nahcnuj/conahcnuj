#!/usr/bin/env bash
# conahcnuj minimum-round-budget test (offline).
#
# A model round with only a few seconds of budget left is killed by the round
# timeout a moment later, counted as a failure, and handed off to the next model
# which then gets an even smaller slice - a futile chain that shows up as a long
# tail of "opencode exceeded the remaining driver time budget" stops and
# no-model-completed runs whose last models never got a usable budget. The
# driver must instead refuse to start a sub-minimum round and end the run with
# the honest "time budget exhausted" diagnosis (actionable finding
# time-budget-exhausted), not another model failure.
#
# Scenarios (mocked API tape as in conahcnuj-bugreport.sh):
#
#   1. the whole run budget is below the default minimum (60s) -> the very
#      first round is refused and the run ends as time-budget-exhausted, with a
#      bug report and no model round ever started
#   2. a comfortable run budget plus an explicitly oversized minimum -> the
#      same shutdown, proving the minimum (and its override) is the controlling
#      gate rather than a race on the elapsing wall clock
#   3. regression: a normal budget still runs rounds to the implementation
#      failure instead of tripping the guard
#
# No secrets, no network.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
DRIVER="${REPO}/bin/conahcnuj.sh"

ROOT="$(mktemp -d)"
WORK="${ROOT}/repo"
trap 'rm -rf "${ROOT}"' EXIT
mkdir -p "${WORK}"

git -C "${WORK}" init -q
git -C "${WORK}" config user.email "test@example.com"
git -C "${WORK}" config user.name "test"
git -C "${WORK}" config commit.gpgsign false
printf 'base\n' > "${WORK}/file.txt"
git -C "${WORK}" add -A
git -C "${WORK}" commit -qm init

# Mocked response tape, in call order: fetch_issue, get_repo,
# find_pr_by_head_any (empty), create_issue (25).
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"number": 14, "title": "test issue, no budget for a round", "body": "dummy body", "labels": [], "state": "open"}
{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"number": 25}
EOF

export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export MOCK_OPENCODE_MODELS="opencode/alpha opencode/beta"
export CONAHCNUJ_REPO="nahcnuj/conahcnuj"

# Assert one budget-shutdown run: exit 1, the shutdown diagnosis, a bug report,
# and no model round ever started.
assert_budget_shutdown() {
  local name="${1}" log="${2}" rc="${3}"
  echo "----- ${name}: run log -----"
  cat "${log}"
  echo "---------------------------------"
  [[ ${rc} -eq 1 ]] || { echo "FAIL: ${name} exited ${rc} (expected 1)"; exit 1; }
  grep -q "remain for another model round (minimum " "${log}" \
    || { echo "FAIL: ${name}: no minimum-round-budget message"; exit 1; }
  grep -q "time budget .* exhausted while waiting. Exiting." "${log}" \
    || { echo "FAIL: ${name}: the run must end as time-budget-exhausted"; exit 1; }
  grep -q "no available model completed the work" "${log}" \
    && { echo "FAIL: ${name}: the shutdown must not read as a model failure"; exit 1; }
  grep -q "opencode: trying model" "${log}" \
    && { echo "FAIL: ${name}: a sub-minimum round must not be started"; exit 1; }
  grep -q "Bug report issue #25 created" "${log}" \
    || { echo "FAIL: ${name}: no bug report was filed"; exit 1; }
}

# --- scenario 1: the whole run budget is below the default minimum -----------
LOG1="${ROOT}/budget-below-min.log"
RC1=0
(
  cd "${WORK}"
  CONAHCNUJ_MAX_SECONDS=80 bash "${DRIVER}" 14 < "${TAPE}"
) > "${LOG1}" 2>&1 || RC1=$?
assert_budget_shutdown "budget-below-min" "${LOG1}" "${RC1}"

# --- scenario 2: an explicitly oversized minimum with a healthy budget --------
LOG2="${ROOT}/min-override.log"
RC2=0
(
  cd "${WORK}"
  CONAHCNUJ_MAX_SECONDS=120 CONAHCNUJ_MIN_ROUND_SECONDS=1000000 \
    bash "${DRIVER}" 14 < "${TAPE}"
) > "${LOG2}" 2>&1 || RC2=$?
assert_budget_shutdown "min-override" "${LOG2}" "${RC2}"

# --- regression: a normal budget still runs rounds to the real failure -------
LOG3="${ROOT}/budget-normal.log"
RC3=0
(
  cd "${WORK}"
  CONAHCNUJ_MAX_SECONDS=120 \
    MOCK_OPENCODE_MODELS="opencode/alpha" \
    MOCK_OPENCODE_NOOP="opencode/alpha" \
    bash "${DRIVER}" 14 < "${TAPE}"
) > "${LOG3}" 2>&1 || RC3=$?
echo "----- budget-normal: run log -----"
cat "${LOG3}"
echo "---------------------------------"
[[ ${RC3} -eq 1 ]] || { echo "FAIL: budget-normal exited ${RC3} (expected 1)"; exit 1; }
grep -q "could not implement issue #14" "${LOG3}" \
  || { echo "FAIL: budget-normal: implementation must still run and fail once"; exit 1; }
grep -q "exhausted while waiting. Exiting." "${LOG3}" \
  && { echo "FAIL: budget-normal: the budget guard fired without a reason"; exit 1; }

echo "conahcnuj minimum-round-budget handling passed"