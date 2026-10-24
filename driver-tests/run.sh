#!/usr/bin/env bash
# Runs every driver test in this directory (offline: no secrets, no network).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for t in "${HERE}"/*.sh; do
  [[ "$(basename "${t}")" == "run.sh" ]] && continue
  # docker-run-real.sh needs a working Docker daemon and a network/build;
  # it is exercised by the dedicated docker-runner CI job instead.
  [[ "$(basename "${t}")" == "docker-run-real.sh" ]] && continue
  echo "Running: $(basename "${t}")"
  bash "${t}"
  echo "PASS: $(basename "${t}")"
done

echo "All tests passed"