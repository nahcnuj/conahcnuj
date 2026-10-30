#!/usr/bin/env bash
# Runs every driver test in this directory (offline: no secrets, no network).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The tests assert the local (non-CI) behaviour of waiting for the reviewer's
# verdict unless a test opts into CI mode itself. GitHub Actions sets
# GITHUB_ACTIONS=true for the whole job, which would otherwise end every driver
# run at the review request instead.
unset GITHUB_ACTIONS CONAHCNUJ_GITHUB_ACTIONS CONAHCNUJ_CI

for t in "${HERE}"/*.sh; do
  [[ "$(basename "${t}")" == "run.sh" ]] && continue
  echo "Running: $(basename "${t}")"
  bash "${t}"
  echo "PASS: $(basename "${t}")"
done

echo "All tests passed"