#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for t in "${HERE}"/tests/*.sh; do
  [[ "$(basename "${t}")" == "run.sh" ]] && continue
  echo "Running: $(basename "${t}")"
  bash "${t}"
  echo "PASS: $(basename "${t}")"
done

echo "All tests passed"