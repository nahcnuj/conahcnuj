#!/usr/bin/env bash
# Runs every driver test in this directory (offline: no secrets, no network).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Detect the opencode major version so each test file can run only the tests
# matching the installed backend (v1 or v2). The CI harness exports
# OPENCODE_VERSION=v1|v2; otherwise fall back to probing the real binary
# (defaulting to v2, the currently shipping CLI).
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

for t in "${HERE}"/*.sh; do
  [[ "$(basename "${t}")" == "run.sh" ]] && continue
  echo "Running: $(basename "${t}")"
  bash "${t}"
  echo "PASS: $(basename "${t}")"
done

echo "All tests passed"