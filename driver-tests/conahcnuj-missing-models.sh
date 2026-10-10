#!/usr/bin/env bash
# conahcnuj permanently-unavailable-model test (offline).
#
# A model round can die because the model itself is gone: the provider reports
# it as deprecated, removed or unavailable. That is a model-level condition,
# not an environment error: no other model of the provider is affected, so the
# driver must remember only that model as dead. It remembers it in the
# committed gh-app/missing-models list too, so the next run -- a fresh CI
# checkout with none of this run's process state -- skips the dead model
# before spending a round (and a log full of errors) on it (#209).
#
# Scenarios (mocked API tape, shape matches conahcnuj-bugreport.sh):
#   1. a list already names one model: it is skipped up front, never run; a
#      model that proves gone during the run is appended to the list
#   2. a second run over the same list skips every dead model without a round
#
# No secrets, no network.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
DRIVER="${REPO}/bin/conahcnuj.sh"

ROOT="$(mktemp -d)"
WORK="${ROOT}/repo"
MISSING="${ROOT}/missing-models"
trap 'rm -rf "${ROOT}"' EXIT
mkdir -p "${WORK}"

git -C "${WORK}" init -q
git -C "${WORK}" config user.email "test@example.com"
git -C "${WORK}" config user.name "test"
git -C "${WORK}" config commit.gpgsign false
printf 'base\n' > "${WORK}/file.txt"
git -C "${WORK}" add -A
git -C "${WORK}" commit -qm init

# fetch_issue, get_repo, find_pr_by_head_any (empty), create_issue. Reopened by
# each run's subshell.
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"number": 14, "title": "test issue, model gone", "body": "dummy body", "labels": [], "state": "open"}
{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"number": 25}
EOF

# A list that already remembers one dead model. The file exists, so a run may
# append to it.
printf '# known dead\npre/one\n' > "${MISSING}"

export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export CONAHCNUJ_REPO="nahcnuj/conahcnuj"
export CONAHCNUJ_MISSING_MODELS_FILE="${MISSING}"

LOG1="${ROOT}/run1.log"
RC1=0
(
  cd "${WORK}"
  CONAHCNUJ_MAX_SECONDS=120 \
    MOCK_OPENCODE_MODELS="$(printf '%s\n' pre/one gone/a gone/b)" \
    MOCK_OPENCODE_DEPRECATED="gone/a gone/b" \
    bash "${DRIVER}" 14 < "${TAPE}"
) > "${LOG1}" 2>&1 || RC1=$?

echo "----- scenario 1: remember and persist gone models -----"
cat "${LOG1}"
echo "--------------------------------------------------------"

[[ ${RC1} -eq 1 ]] || { echo "FAIL: scenario 1 exited ${RC1} (expected 1)"; exit 1; }

# The already-known model is skipped before any round: no attempt, no error.
grep -q "Skipping models remembered as permanently unavailable: pre/one" "${LOG1}" || { echo "FAIL: pre/one was not skipped up front"; exit 1; }
grep -q "opencode: trying model pre/one" "${LOG1}" && { echo "FAIL: pre/one was tried despite being remembered"; exit 1; }
grep -q "mock error for pre/one" "${LOG1}" && { echo "FAIL: pre/one ran a round despite being remembered"; exit 1; }

# The newly-gone models ran once and were diagnosed as model-level failures...
grep -q "opencode: trying model gone/a" "${LOG1}" || { echo "FAIL: gone/a was not tried"; exit 1; }
grep -q "Model gone/a failed before completing the work: the model itself is gone" "${LOG1}" || { echo "FAIL: gone/a was not diagnosed as gone"; exit 1; }
grep -q "Model gone/b failed before completing the work: the model itself is gone" "${LOG1}" || { echo "FAIL: gone/b was not diagnosed as gone"; exit 1; }
# ...and NOT as an environment problem (which would drop the whole provider).
grep -q "failed before completing the work: environment error" "${LOG1}" && { echo "FAIL: a gone model was reported as an environment error"; exit 1; }

# The list now remembers them (persisted across runs) and kept the first entry.
grep -qxF "gone/a" "${MISSING}" || { echo "FAIL: gone/a was not persisted to the list"; exit 1; }
grep -qxF "gone/b" "${MISSING}" || { echo "FAIL: gone/b was not persisted to the list"; exit 1; }
grep -qxF "pre/one" "${MISSING}" || { echo "FAIL: the pre-existing entry was lost"; exit 1; }

LOG2="${ROOT}/run2.log"
RC2=0
(
  cd "${WORK}"
  CONAHCNUJ_MAX_SECONDS=120 \
    MOCK_OPENCODE_MODELS="$(printf '%s\n' pre/one gone/a gone/b)" \
    MOCK_OPENCODE_DEPRECATED="pre/one gone/a gone/b" \
    bash "${DRIVER}" 14 < "${TAPE}"
) > "${LOG2}" 2>&1 || RC2=$?

echo "----- scenario 2: a later run skips every remembered model -----"
cat "${LOG2}"
echo "---------------------------------------------------------------"

[[ ${RC2} -eq 1 ]] || { echo "FAIL: scenario 2 exited ${RC2} (expected 1)"; exit 1; }
grep -q "Skipping models remembered as permanently unavailable: pre/one gone/a gone/b" "${LOG2}" || { echo "FAIL: scenario 2 did not skip the remembered models"; exit 1; }
for m in pre/one gone/a gone/b; do
  grep -q "opencode: trying model ${m}" "${LOG2}" && { echo "FAIL: ${m} ran a round in scenario 2"; exit 1; }
done
grep -q "no available model completed the work (tried: none" "${LOG2}" || { echo "FAIL: scenario 2 did not report that nothing was tried"; exit 1; }

# ---------------------------------------------------------------------------
# Unit: opencode_round_is_model_gone classifies raw opencode error events, and
# it stays disjoint from opencode_round_is_environment.
# ---------------------------------------------------------------------------
# shellcheck source=lib/opencode.sh
source "${REPO}/lib/opencode.sh"

F="${ROOT}/events.jsonl"
printf '%s\n' '{"type":"error","error":{"name":"APIError","data":{"message":"AI_APICallError: Model exo-free has been deprecated."}}}' > "${F}"
opencode_round_is_model_gone "${F}" || { echo "FAIL: a deprecated-model error was not classified as gone"; exit 1; }
opencode_round_is_environment "${F}" && { echo "FAIL: a deprecated-model error was classified as environment"; exit 1; }

printf '%s\n' '{"type":"error","error":{"name":"APIError","data":{"message":"AI_APICallError: Upstream request failed: Model is unavailable."}}}' > "${F}"
opencode_round_is_model_gone "${F}" || { echo "FAIL: a model-unavailable error was not classified as gone"; exit 1; }
opencode_round_is_environment "${F}" && { echo "FAIL: a model-unavailable error was classified as environment"; exit 1; }

printf '%s\n' '{"type":"error","error":{"name":"APIError","data":{"message":"AI_APICallError: Cannot connect to API: Unable to connect"}}}' > "${F}"
opencode_round_is_model_gone "${F}" && { echo "FAIL: a connection failure was classified as a gone model"; exit 1; }

# Words in a model's own text must not count: the classification keys off
# error events only.
printf '%s\n' '{"type":"text","part":{"type":"text","text":"model has been deprecated and is unavailable"}}' > "${F}"
opencode_round_is_model_gone "${F}" && { echo "FAIL: text events were classified as a gone model"; exit 1; }

# The list helpers live in the driver. CONAHCNUJ_IMPORT guards main().
export CONAHCNUJ_IMPORT=1
# shellcheck source=bin/conahcnuj.sh
source "${DRIVER}"

# A missing list means nothing is remembered, and a run must not create one.
MISSING_MODELS_FILE="${ROOT}/never-created"
OPENCODE_DEAD_MODELS=""
load_missing_models
[[ -z "${OPENCODE_DEAD_MODELS}" ]] || { echo "FAIL: load_missing_models invented an entry"; exit 1; }
persist_missing_model "gone/x"
[[ -f "${ROOT}/never-created" ]] && { echo "FAIL: persist_missing_model created a list that did not exist"; exit 1; }
is_missing_model "gone/x" || { echo "FAIL: persist_missing_model did not remember in-process"; exit 1; }

# A malformed line (comment, blank, surrounding whitespace) is ignored, and a
# duplicate does not grow the in-process list.
printf '# comment\n\n  gone/y  \ngone/y\n' > "${ROOT}/list2"
MISSING_MODELS_FILE="${ROOT}/list2"
OPENCODE_DEAD_MODELS=""
load_missing_models
[[ "${OPENCODE_DEAD_MODELS}" == " gone/y" ]] || { echo "FAIL: load_missing_models parsed the list wrong (got:${OPENCODE_DEAD_MODELS})"; exit 1; }

echo "conahcnuj missing-model handling passed"
