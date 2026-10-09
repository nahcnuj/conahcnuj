#!/usr/bin/env bash
# conahcnuj deprecated-model test (offline).
#
# A model that opencode still lists but has been deprecated ("Model X has been
# deprecated.") is permanent and model-specific: it will never come back, so
# the driver must remember that one model as dead and never run it again, while
# keeping the rest of its provider usable (a deprecated model is NOT an
# environment error, so no provider is dropped for it). Without this, a
# deprecated model like opencode/exo-free is re-tried on every implement() pass
# within a run, wasting a round each time (#209).
#
# Two parts:
#   1. unit: implement() round 1 meets a deprecated model then a live one; the
#      live model of the same provider still runs and the tree is committed
#   2. unit: a second implement() round in the same process skips the
#      now-dead model and only runs the remaining ones
# Plus classifier checks: "has been deprecated" event lines classify as
# deprecated, and never as an environment failure.
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

export CONAHCNUJ_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export CONAHCNUJ_IMPORT=1
export CONAHCNUJ_REPO="nahcnuj/conahcnuj"
# shellcheck source=bin/conahcnuj.sh
source "${DRIVER}"

# The first model the provider lists is deprecated; the second is alive.
export MOCK_OPENCODE_MODELS="opencode/exo-free
opencode/working"
export MOCK_OPENCODE_DEPRECATED="opencode/exo-free"

LOG1="${ROOT}/round1.log"
# Same process, no subshell: the dead-model list must survive across rounds.
cd "${WORK}"
implement "deprecated model" "a deprecated model must not kill its provider" 2>"${LOG1}"

echo "----- implement round 1 -----"
cat "${LOG1}"
echo "-----------------------------"

# The deprecated round is permanent but model-specific: it is remembered, and
# the same provider's next model still runs.
grep -q "Model opencode/exo-free has been deprecated (permanently unavailable); skipping it for the rest of this run" "${LOG1}" || { echo "FAIL: the deprecated model was not diagnosed"; exit 1; }
grep -q "giving up on provider opencode" "${LOG1}" && { echo "FAIL: a deprecated model dropped its whole provider"; exit 1; }
grep -q "Model opencode/working completed the work" "${LOG1}" || { echo "FAIL: a live model of the same provider did not run after the deprecated one"; exit 1; }
[[ "${OPENCODE_DEAD_MODELS}" == *"opencode/exo-free"* ]] || { echo "FAIL: the deprecated model was not remembered"; exit 1; }

# A second implement() pass in the same process must skip the dead model and
# only run the remaining ones (here: a no-op) instead of trying exo-free again.
# The driver commits (and so consumes .commit-msg) between rounds; mirror that.
rm -f "${WORK}/.commit-msg"
export MOCK_OPENCODE_MODELS="opencode/exo-free
opencode/other-noop"
export MOCK_OPENCODE_NOOP="opencode/other-noop"
LOG2="${ROOT}/round2.log"
RC2=0
implement "deprecated model" "second implement round" 2>"${LOG2}" || RC2=$?

echo "----- implement round 2 -----"
cat "${LOG2}"
echo "-----------------------------"

[[ ${RC2} -eq 1 ]] || { echo "FAIL: round 2 exited ${RC2} (expected 1: no live model produced work)"; exit 1; }
grep -q "Skipping opencode/exo-free: it is permanently unavailable (deprecated); no point running it again" "${LOG2}" || { echo "FAIL: the remembered-deprecated model was not skipped in round 2"; exit 1; }
grep -q "opencode: mock no-op for opencode/other-noop" "${LOG2}" || { echo "FAIL: a later model did not run after the deprecated one was skipped"; exit 1; }

# Classifier: the raw "has been deprecated." event is deprecated, not an
# environment error; a text event that merely quotes the words is neither.
F="${ROOT}/events.jsonl"
printf '%s\n' '{"type":"error","error":{"name":"AI_APICallError","data":{"message":"Model exo-free has been deprecated."}}}' > "${F}"
opencode_round_is_deprecated "${F}" || { echo "FAIL: 'has been deprecated' was not classified as deprecated"; exit 1; }
opencode_round_is_environment "${F}" && { echo "FAIL: a deprecated model was classified as an environment failure"; exit 1; }

printf '%s\n' '{"type":"error","error":{"name":"APIError","data":{"message":"AI_APICallError: Cannot connect to API: Unable to connect"}}}' > "${F}"
opencode_round_is_deprecated "${F}" && { echo "FAIL: a connection failure was classified as deprecated"; exit 1; }
opencode_round_is_environment "${F}" || { echo "FAIL: a connection failure was not classified as environment"; exit 1; }

printf '%s\n' '{"type":"text","part":{"type":"text","text":"has been deprecated cannot connect to API"}}' > "${F}"
opencode_round_is_deprecated "${F}" && { echo "FAIL: text events were classified as deprecated"; exit 1; }
opencode_round_is_environment "${F}" && { echo "FAIL: text events were classified as environment"; exit 1; }

echo "conahcnuj deprecated-model handling passed"