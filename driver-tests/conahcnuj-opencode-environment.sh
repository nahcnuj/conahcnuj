#!/usr/bin/env bash
# verify_opencode_environment / opencode_environment_ok fail-fast guard (offline).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

# --- lib: opencode_environment_ok -------------------------------------------
# shellcheck source=lib/opencode.sh
. "${REPO}/lib/opencode.sh"

export OPENCODE_TEST_MODE=1
MOCK_OPENCODE_MODELS="$(printf 'prov/one\nprov/two')"
export MOCK_OPENCODE_MODELS
rc=0
opencode_environment_ok >/dev/null 2>"${HERE}/.env.err" || rc=$?
if [[ ${rc} -ne 0 ]] || [[ -s "${HERE}/.env.err" ]]; then
  echo "FAIL: available case failed (rc=${rc}): $(cat "${HERE}/.env.err")"; rm -f "${HERE}/.env.err"; exit 1
fi
rm -f "${HERE}/.env.err"

export MOCK_OPENCODE_MODELS=""
rc=0
err="$(opencode_environment_ok 2>&1 >/dev/null)" || rc=$?
if [[ ${rc} -eq 0 ]] || [[ "${err}" != *"no models available"* ]]; then
  echo "FAIL: empty model list not rejected: rc=${rc} err=${err}"; exit 1
fi

unset OPENCODE_TEST_MODE MOCK_OPENCODE_MODELS
opencode_command() { return 1; }
rc=0
err="$(opencode_environment_ok 2>&1 >/dev/null)" || rc=$?
if [[ ${rc} -eq 0 ]] || [[ "${err}" != *"no runnable opencode found"* ]]; then
  echo "FAIL: missing binary not rejected: rc=${rc} err=${err}"; exit 1
fi
unset -f opencode_command

# --- bin: verify_opencode_environment ----------------------------------------
TMPROOT="$(mktemp -d)"
trap 'rm -rf "${TMPROOT}"' EXIT
WORK="${TMPROOT}/repo"
mkdir -p "${WORK}"
git -C "${WORK}" init -q >/dev/null

CONAHCNUJ_IMPORT=1
CONAHCNUJ_TEST_MODE=0
# shellcheck source=bin/conahcnuj.sh
. "${REPO}/bin/conahcnuj.sh"

export OPENCODE_TEST_MODE=1
MOCK_OPENCODE_MODELS="$(printf 'prov/one\n')"
export MOCK_OPENCODE_MODELS
rc=0
( verify_opencode_environment ) >"${TMPROOT}/ok.log" 2>&1 || rc=$?
if [[ ${rc} -ne 0 ]] || [[ -s "${TMPROOT}/ok.log" ]]; then
  echo "FAIL: available case failed (rc=${rc}): $(cat "${TMPROOT}/ok.log")"; exit 1
fi

export MOCK_OPENCODE_MODELS=""
rc=0
( verify_opencode_environment ) >"${TMPROOT}/nomodels.log" 2>&1 || rc=$?
if [[ ${rc} -eq 0 ]] || ! grep -q "no models available" "${TMPROOT}/nomodels.log" || ! grep -q "opencode backend environment check failed" "${TMPROOT}/nomodels.log"; then
  echo "FAIL: empty model list not rejected: $(cat "${TMPROOT}/nomodels.log")"; exit 1
fi

unset OPENCODE_TEST_MODE MOCK_OPENCODE_MODELS
opencode_command() { return 1; }
rc=0
( verify_opencode_environment ) >"${TMPROOT}/nocmd.log" 2>&1 || rc=$?
if [[ ${rc} -eq 0 ]] || ! grep -q "no runnable opencode found" "${TMPROOT}/nocmd.log"; then
  echo "FAIL: missing binary not rejected: $(cat "${TMPROOT}/nocmd.log")"; exit 1
fi
unset -f opencode_command

# --- integration: driver fails fast at startup ------------------------------
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
cat > "${TAPE}" <<'EOF'
{"number": 14, "title": "test issue", "body": "dummy body", "labels": [], "state": "open"}

EOF

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
if grep -q "Bug report issue" "${LOG}"; then
  echo "FAIL: a bug report was filed for a configuration error"; cat "${LOG}"; exit 1
fi

echo "conahcnuj opencode environment guard passed"
