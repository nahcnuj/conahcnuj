#!/usr/bin/env bash
# Max effort mode behaviour (offline).
#
# `--max-effort` / CONAHCNUJ_MAX_EFFORT / CONAHCNUJ_EFFORT=max must make the
# driver pass the V2 `provider/model#max` suffix to opencode (highest effort),
# while a normal run must use the bare model, so effort never decreases. No
# secrets, no network.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

# shellcheck source=lib/opencode.sh
. "${REPO}/lib/opencode.sh"

# 1. opencode_effort_variant
export CONAHCNUJ_MAX_EFFORT="1"
unset CONAHCNUJ_EFFORT
out="$(opencode_effort_variant)"
[[ "${out}" == "max" ]] || { echo "FAIL: MAX_EFFORT=1 did not yield max (got '${out}')"; exit 1; }

unset CONAHCNUJ_MAX_EFFORT CONAHCNUJ_EFFORT
out="$(opencode_effort_variant)"
[[ -z "${out}" ]] || { echo "FAIL: normal mode yielded '${out}' (expected empty)"; exit 1; }

export CONAHCNUJ_MAX_EFFORT=""
unset CONAHCNUJ_EFFORT
out="$(opencode_effort_variant)"
[[ -z "${out}" ]] || { echo "FAIL: empty MAX_EFFORT yielded '${out}' (expected empty)"; exit 1; }

export CONAHCNUJ_EFFORT="true"
unset CONAHCNUJ_MAX_EFFORT
out="$(opencode_effort_variant)"
[[ -z "${out}" ]] || { echo "FAIL: CONAHCNUJ_EFFORT=true leaked through (got '${out}')"; exit 1; }

export CONAHCNUJ_EFFORT="max"
unset CONAHCNUJ_MAX_EFFORT
out="$(opencode_effort_variant)"
[[ "${out}" == "max" ]] || { echo "FAIL: CONAHCNUJ_EFFORT=max did not yield max (got '${out}')"; exit 1; }

export CONAHCNUJ_EFFORT="high"
out="$(opencode_effort_variant)"
[[ -z "${out}" ]] || { echo "FAIL: arbitrary level 'high' leaked through (got '${out}')"; exit 1; }
unset CONAHCNUJ_EFFORT

echo "opencode_effort_variant (max effort) passed"

# 2. opencode_run mock output carries the variant only in max mode.
export OPENCODE_TEST_MODE=1
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

export CONAHCNUJ_MAX_EFFORT="1"
unset CONAHCNUJ_EFFORT
out="$(opencode_run "Issue" "Body" "${tmp}" "opencode/m" 2>/dev/null)"
[[ "${out}" == *"--model opencode/m#max"* ]] || { echo "FAIL: max mode did not pass model#max"; echo "${out}" | head -1; exit 1; }

unset CONAHCNUJ_MAX_EFFORT CONAHCNUJ_EFFORT
out="$(opencode_run "Issue" "Body" "${tmp}" "opencode/m" 2>/dev/null)"
[[ "${out}" == *"--model opencode/m "* ]] || { echo "FAIL: normal mode did not use the bare model"; echo "${out}" | head -1; exit 1; }
[[ "${out}" != *"#max"* ]] || { echo "FAIL: normal mode unexpectedly passed #max"; echo "${out}" | head -1; exit 1; }

echo "opencode_run (max effort variant) passed"
