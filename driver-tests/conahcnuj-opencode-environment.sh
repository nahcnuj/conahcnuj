#!/usr/bin/env bash
# conahcnuj opencode-backend environment guard test (offline).
#
# The driver's very first action (before repository detection, branch
# creation, commits or pull requests) is to confirm that the coding-agent
# backend (opencode) is actually usable: a runnable binary that exposes at
# least one model. Discovering a broken backend only after a branch, an empty
# initial commit and a draft PR exist wastes the whole run and files a
# misleading bug report, so the check fails fast and prints the diagnosis on
# stderr instead. Because it is a configuration/setup error it stops before the
# bug-report trap is registered: no bug-report issue is filed (#149 / #841).
#
# Two layers are exercised:
#
#   1. lib/opencode.sh :: opencode_environment_ok
#      - backend available (test mode, non-empty model list) -> success, no output
#      - backend exposes no model (empty list)               -> failure, names "no models available"
#      - no runnable opencode binary                         -> failure, names "no runnable opencode found"
#
#   2. bin/conahcnuj.sh :: verify_opencode_environment (sourced via CONAHCNUJ_IMPORT)
#      - same three situations, asserting the unified messages and exit codes
#
#   3. end-to-end: bin/conahcnuj.sh invoked with an empty model list must exit
#      non-zero, print the unified environment-check failure, and must NOT file
#      a bug report (the trap is not registered yet at that point).
#
# No secrets, no network.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

# --- 1. lib/opencode.sh :: opencode_environment_ok --------------------------
# shellcheck source=lib/opencode.sh
. "${REPO}/lib/opencode.sh"

# Available backend: test mode reports a non-empty model list, so the check
# must succeed silently.
export OPENCODE_TEST_MODE=1
MOCK_OPENCODE_MODELS="$(printf 'prov/one\nprov/two')"
export MOCK_OPENCODE_MODELS
rc=0
err_file="${HERE}/.env.err"
opencode_environment_ok >/dev/null 2>"${err_file}" || rc=$?
if [[ ${rc} -ne 0 ]] || [[ -s "${err_file}" ]]; then
  echo "FAIL: available backend rejected (rc=${rc}): $(cat "${err_file}")"; rm -f "${err_file}"; exit 1
fi
rm -f "${err_file}"

# Empty model list: the backend is reachable but exposes nothing, so the check
# must fail and name the missing models.
export MOCK_OPENCODE_MODELS=""
rc=0
err="$(opencode_environment_ok 2>&1 >/dev/null)" || rc=$?
if [[ ${rc} -eq 0 ]] || [[ "${err}" != *"no models available"* ]]; then
  echo "FAIL: empty model list not rejected: rc=${rc} err=${err}"; exit 1
fi

# Missing binary: with test mode off, override opencode_command so the lookup
# fails and confirm the check names the missing binary.
unset OPENCODE_TEST_MODE MOCK_OPENCODE_MODELS
opencode_command() { return 1; }
rc=0
err="$(opencode_environment_ok 2>&1 >/dev/null)" || rc=$?
if [[ ${rc} -eq 0 ]] || [[ "${err}" != *"no runnable opencode found"* ]]; then
  echo "FAIL: missing binary not rejected: rc=${rc} err=${err}"; exit 1
fi
unset -f opencode_command

# --- 2. bin/conahcnuj.sh :: verify_opencode_environment ---------------------
TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT
WORK="${TMPROOT}/repo"
mkdir -p "${WORK}"
git -C "${WORK}" init -q >/dev/null

CONAHCNUJ_IMPORT=1
CONAHCNUJ_TEST_MODE=0
# shellcheck source=bin/conahcnuj.sh
. "${REPO}/bin/conahcnuj.sh"

# Available backend: must succeed silently.
export OPENCODE_TEST_MODE=1
MOCK_OPENCODE_MODELS="$(printf 'prov/one\n')"
export MOCK_OPENCODE_MODELS
rc=0
if ! ( verify_opencode_environment ) >"${TMPROOT}/ok.log" 2>&1; then rc=$?; fi
if [[ ${rc} -ne 0 ]] || [[ -s "${TMPROOT}/ok.log" ]]; then
  echo "FAIL: available backend rejected (rc=${rc}): $(cat "${TMPROOT}/ok.log")"; exit 1
fi

# Empty model list: must fail and carry both the unified lib message and the
# bin-level explanation.
export MOCK_OPENCODE_MODELS=""
rc=0
if ( verify_opencode_environment ) >"${TMPROOT}/nomodels.log" 2>&1; then rc=0; else rc=$?; fi
if [[ ${rc} -eq 0 ]] || ! grep -q "no models available" "${TMPROOT}/nomodels.log" || ! grep -q "opencode backend environment check failed" "${TMPROOT}/nomodels.log"; then
  echo "FAIL: empty model list not rejected: $(cat "${TMPROOT}/nomodels.log")"; exit 1
fi

# Missing binary: must fail naming the missing binary.
unset OPENCODE_TEST_MODE MOCK_OPENCODE_MODELS
opencode_command() { return 1; }
rc=0
if ( verify_opencode_environment ) >"${TMPROOT}/nocmd.log" 2>&1; then rc=0; else rc=$?; fi
if [[ ${rc} -eq 0 ]] || ! grep -q "no runnable opencode found" "${TMPROOT}/nocmd.log"; then
  echo "FAIL: missing binary not rejected: $(cat "${TMPROOT}/nocmd.log")"; exit 1
fi
unset -f opencode_command

# --- 3. end-to-end: driver fails fast at startup ----------------------------
WORK2="${TMPROOT}/repo2"
mkdir -p "${WORK2}"
git -C "${WORK2}" init -q >/dev/null
git -C "${WORK2}" config user.email "test@example.com"
git -C "${WORK2}" config user.name "test"
git -C "${WORK2}" config commit.gpgsign false
printf 'base\n' > "${WORK2}/file.txt"
git -C "${WORK2}" add -A
git -C "${WORK2}" commit -qm init >/dev/null

TAPE="${TMPROOT}/tape.txt"
printf '{"number": 14, "title": "test issue", "body": "dummy body", "labels": [], "state": "open"}\n' > "${TAPE}"

LOG="${TMPROOT}/run.log"
RC=0
(
  cd "${WORK2}"
  CONAHCNUJ_TEST_MODE=1 \
  CONAHCNUJ_REPO="nahcnuj/conahcnuj" \
  GH_API_TEST_MODE=1 \
  OPENCODE_TEST_MODE=1 \
  MOCK_OPENCODE_MODELS="" \
  bash "${REPO}/bin/conahcnuj.sh" 14 < "${TAPE}"
) > "${LOG}" 2>&1 || RC=$?

if [[ ${RC} -eq 0 ]] || ! grep -q "opencode backend environment check failed" "${LOG}"; then
  echo "FAIL: driver did not fail fast: rc=${RC}"; cat "${LOG}"; exit 1
fi
# The guard runs before the bug-report trap is registered, so a configuration
# error must never be reported as a driver bug.
if grep -q "Bug report issue" "${LOG}"; then
  echo "FAIL: a bug report was filed for a configuration error"; cat "${LOG}"; exit 1
fi
# The guard runs before repository detection, so no repository line is printed.
if grep -q "Repository:" "${LOG}"; then
  echo "FAIL: repository detection ran before the environment guard"; cat "${LOG}"; exit 1
fi

echo "conahcnuj opencode environment guard passed"
