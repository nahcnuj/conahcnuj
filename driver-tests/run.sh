#!/usr/bin/env bash
# Runs every driver test in this directory (offline: no secrets, no network).
# The opencode version is detected once and only the matching test file
# (opencode.sh for v1, opencode-v2.sh for v2) is executed — the other is
# skipped because its expectations (CLI flags, mock output) are specific to
# the other backend.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect the opencode major version so only the test file matching the
# installed backend runs. The CI harness exports OPENCODE_VERSION=v1|v2;
# otherwise fall back to probing the real binary (defaulting to v2, the
# currently shipping CLI).
if [[ -z "${OPENCODE_VERSION:-}" ]]; then
  OPENCODE_VERSION="v2"
  if oc="$(command -v opencode 2>/dev/null || command -v opencode.exe 2>/dev/null || echo "")" && [[ -n "${oc}" ]]; then
    ver="$("${oc}" --version 2>/dev/null | tr -d '\r' | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -1)" || true
    if [[ -n "${ver}" ]]; then
      major="${ver%%.*}"
      if [[ "${major}" -eq 0 ]]; then
        OPENCODE_VERSION="v1"
      fi
    fi
  fi
fi
export OPENCODE_VERSION

# Pick the test file matching the detected opencode major version.
if [[ "${OPENCODE_VERSION}" == "v1" ]]; then
  TEST_FILE="${HERE}/opencode.sh"
else
  TEST_FILE="${HERE}/opencode-v2.sh"
fi

echo "Running: $(basename "${TEST_FILE}") (OPENCODE_VERSION=${OPENCODE_VERSION})"
bash "${TEST_FILE}"
echo "PASS: $(basename "${TEST_FILE}")"

echo "All tests passed"
