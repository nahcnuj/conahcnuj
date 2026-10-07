#!/usr/bin/env bash
# Runs every driver test in this directory (offline: no secrets, no network).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for t in "${HERE}"/*.sh; do
  [[ "$(basename "${t}")" == "run.sh" ]] && continue
  echo "Running: $(basename "${t}")"
  bash "${t}"
  echo "PASS: $(basename "${t}")"
done

echo "All tests passed"