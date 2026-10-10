#!/usr/bin/env bash
# conahcnuj environment-failure test (offline).
#
# A model round that dies on an environment error (provider unreachable,
# credentials rejected, transport broken) says nothing about that particular
# model: no other model of the same provider can reach it either. The driver
# must not burn the rest of the model list on a dead provider, and when every
# round dies that way the run must end pointing at the environment instead of
# at a driver bug (#149).
#
# Two scenarios, one mocked API tape each (the shape matches
# conahcnuj-bugreport.sh):
#
#   1. two providers, both dead (every round environment-fails) -> the second
#      model of each provider is skipped, the run files a bug report whose log
#      carries the environment diagnosis and whose body says the environment
#      was at fault, not the driver
#   2. a provider whose model fails for a non-environment reason -> that
#      provider is NOT dropped and no environment diagnosis is printed
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

# Mocked response tape: fetch_issue, get_repo, find_pr_by_head_any (empty),
# create_issue. Reused by both runs (the sub-shell reopens it).
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"number": 14, "title": "test issue, providers down", "body": "dummy body", "labels": [], "state": "open"}
{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"number": 25}
EOF

export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export CONAHCNUJ_REPO="nahcnuj/conahcnuj"

LOG1="${ROOT}/run1.log"
RC1=0
(
  cd "${WORK}"
  CONAHCNUJ_MAX_SECONDS=120 \
    MOCK_OPENCODE_MODELS="$(printf '%s\n' envdown/a envdown/b netdown/c netdown/d)" \
    MOCK_OPENCODE_ENV_ERROR="envdown/a netdown/c" \
    bash "${DRIVER}" 14 < "${TAPE}"
) > "${LOG1}" 2>&1 || RC1=$?

echo "----- scenario 1: every round dies on an environment error -----"
cat "${LOG1}"
echo "--------------------------------------------------------------"

[[ ${RC1} -eq 1 ]] || { echo "FAIL: scenario 1 exited ${RC1} (expected 1)"; exit 1; }

# The first model of each provider ran and failed with an environment error...
grep -q "Model envdown/a failed before completing the work: environment error" "${LOG1}" || { echo "FAIL: envdown/a was not reported as an environment failure"; exit 1; }
grep -q "Model netdown/c failed before completing the work: environment error" "${LOG1}" || { echo "FAIL: netdown/c was not reported as an environment failure"; exit 1; }
# ...and the second model of each provider was skipped without a round.
grep -q "Skipping envdown/b: provider envdown already failed on an environment error" "${LOG1}" || { echo "FAIL: envdown/b was not skipped"; exit 1; }
grep -q "Skipping netdown/d: provider netdown already failed on an environment error" "${LOG1}" || { echo "FAIL: netdown/d was not skipped"; exit 1; }
grep -q "partial change from envdown/b" "${WORK}/conahcnuj.mock" && { echo "FAIL: envdown/b ran despite its dead provider"; exit 1; }
grep -q "partial change from netdown/d" "${WORK}/conahcnuj.mock" && { echo "FAIL: netdown/d ran despite its dead provider"; exit 1; }
# The run names the environment instead of blaming a driver defect.
grep -q "every model round died on an environment error" "${LOG1}" || { echo "FAIL: no environment diagnosis in the log"; exit 1; }
grep -q "Bug report issue #25 created" "${LOG1}" || { echo "FAIL: no bug report was filed"; exit 1; }

LOG2="${ROOT}/run2.log"
RC2=0
(
  cd "${WORK}"
  CONAHCNUJ_MAX_SECONDS=120 \
    MOCK_OPENCODE_MODELS="$(printf '%s\n' plain/one plain/two)" \
    MOCK_OPENCODE_ERROR="plain/one" \
    MOCK_OPENCODE_NOOP="plain/two" \
    bash "${DRIVER}" 14 < "${TAPE}"
) > "${LOG2}" 2>&1 || RC2=$?

echo "----- scenario 2: a non-environment failure keeps the provider -----"
cat "${LOG2}"
echo "---------------------------------------------------------------------"

[[ ${RC2} -eq 1 ]] || { echo "FAIL: scenario 2 exited ${RC2} (expected 1)"; exit 1; }

# A non-environment failure says nothing about the provider, so its next model
# is still tried and nothing is diagnosed as an environment problem.
grep -q "Model plain/one failed before completing the work; handing off to the next model" "${LOG2}" || { echo "FAIL: plain/one did not hand off"; exit 1; }
grep -q "opencode: mock no-op for plain/two" "${LOG2}" || { echo "FAIL: plain/two did not run after a non-environment failure"; exit 1; }
grep -q "Skipping" "${LOG2}" && { echo "FAIL: a provider was skipped on a non-environment failure"; exit 1; }
grep -q "every model round died on an environment error" "${LOG2}" && { echo "FAIL: environment diagnosis printed although a round failed non-environmentally"; exit 1; }

# ---------------------------------------------------------------------------
# Unit: the bug report words the failure as the environment (or not) based on
# ENVIRONMENT_DOWN. Capture the body through a stubbed gh_api_create_issue.
# ---------------------------------------------------------------------------
export CONAHCNUJ_IMPORT=1
# shellcheck source=bin/conahcnuj.sh
source "${DRIVER}"
gh_api_create_issue() {
  printf '%s\n' "${4}" > "${ROOT}/captured-env.txt"
  printf '99\n'
}

(
  ENVIRONMENT_DOWN=1
  RUN_LOG_FILE="$(mktemp)"
  printf '%s\n' "ERROR: every model round died on an environment error (provider unreachable or credentials rejected; providers given up on: envdown netdown)." > "${RUN_LOG_FILE}"
  BUG_REPORT_INPUT="14"
  BUG_REPORTED="0"
  report_bug_on_exit "1"
)
grep -q "stopped early on issue #14: every model round died on an environment error" "${ROOT}/captured-env.txt" || { echo "FAIL: environment opener missing from the bug report"; exit 1; }
grep -q "Nothing in the log below points at a driver defect" "${ROOT}/captured-env.txt" || { echo "FAIL: environment closing missing from the bug report"; exit 1; }
grep -q "the driver bug can be fixed" "${ROOT}/captured-env.txt" && { echo "FAIL: the environment report still blames a driver bug"; exit 1; }

(
  ENVIRONMENT_DOWN=0
  RUN_LOG_FILE="$(mktemp)"
  printf '%s\n' "ERROR: could not implement issue #14 with any available model." > "${RUN_LOG_FILE}"
  BUG_REPORT_INPUT="14"
  BUG_REPORTED="0"
  report_bug_on_exit "1"
)
grep -q "the driver bug can be fixed" "${ROOT}/captured-env.txt" || { echo "FAIL: the generic report no longer asks for a driver fix"; exit 1; }

# ---------------------------------------------------------------------------
# Unit: opencode_round_is_environment classifies raw opencode error events.
# ---------------------------------------------------------------------------
# shellcheck source=lib/opencode.sh
source "${REPO}/lib/opencode.sh"

F="${ROOT}/events.jsonl"
printf '%s\n' '{"type":"error","error":{"name":"ProviderAuthError","data":{"message":"xAI token refresh failed (400): {\"error\":\"invalid_grant\",\"error_description\":\"Invalid or unknown refresh token\"}"}}}' > "${F}"
opencode_round_is_environment "${F}" || { echo "FAIL: a token refresh failure was not classified as environment"; exit 1; }

printf '%s\n' '{"type":"error","error":{"name":"APIError","data":{"message":"AI_APICallError: Cannot connect to API: Unable to connect"}}}' > "${F}"
opencode_round_is_environment "${F}" || { echo "FAIL: a connection failure was not classified as environment"; exit 1; }

printf '%s\n' '{"type":"error","error":{"name":"AbortError","data":{"message":"The user aborted the request."}}}' > "${F}"
opencode_round_is_environment "${F}" && { echo "FAIL: a non-environment error was classified as environment"; exit 1; }

# Words in a model's own text must not count: the classification keys off
# error events only.
printf '%s\n' '{"type":"text","part":{"type":"text","text":"eConnRefused token refresh failed cannot connect to API"}}' > "${F}"
opencode_round_is_environment "${F}" && { echo "FAIL: text events were classified as environment"; exit 1; }

# A model-level condition says nothing about the provider: a model that is
# unavailable, deprecated or does not exist must not drop its provider (the
# upstream wrapper may still prefix the model condition, e.g. "Upstream request
# failed: Model is unavailable.", so the model signal must win over the wrapper).
printf '%s\n' '{"type":"error","error":{"name":"APIError","data":{"message":"AI_APICallError: Upstream request failed: Model is unavailable."}}}' > "${F}"
opencode_round_is_environment "${F}" && { echo "FAIL: a model-unavailable error was classified as environment"; exit 1; }

printf '%s\n' '{"type":"error","error":{"name":"APIError","data":{"message":"AI_APICallError: Model exo-free has been deprecated."}}}' > "${F}"
opencode_round_is_environment "${F}" && { echo "FAIL: a deprecated-model error was classified as environment"; exit 1; }

: > "${F}"
opencode_round_is_environment "${F}" && { echo "FAIL: an empty event stream was classified as environment"; exit 1; }

echo "conahcnuj environment-failure handling passed"