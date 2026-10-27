#!/usr/bin/env bash
# weekly-self-improvement.yml must check out the branch tip, not the event's
# github.sha. A re-run reuses the original SHA, so a fix merged after the first
# attempt would be invisible to the re-run and it would reproduce the old
# failure. That is exactly how the "Body is too long" fix (#190 / PR #191) was
# still failing on re-run: issue #194 "unresolved yet" carries a re-run whose
# head was the pre-fix 08b0743. Pinning a `ref:` on the checkout step makes
# schedule and workflow_dispatch resolve the current commit of github.ref.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
WF="${REPO}/.github/workflows/weekly-self-improvement.yml"

[[ -f "${WF}" ]] || { echo "FAIL: missing ${WF}"; exit 1; }

# Walk the checkout step: from its `uses:` line, look at the following lines
# until the next step (a list item at the same indentation, "      - ") for a
# `ref:` input. The step may also be written as a multi-line mapping, so the
# scan starts at the `uses: actions/checkout@` line wherever it is.
awk '
  /uses:[[:space:]]*actions\/checkout@/ { inblock = 1; next }
  inblock && /^      - / { inblock = 0 }
  inblock && /^[[:space:]]*ref:[[:space:]]*[^[:space:]]/ { found = 1 }
  END { exit !found }
' "${WF}" \
  || { echo "FAIL: the weekly workflow checkout must set ref: (re-runs reuse github.sha)"; exit 1; }

# The ref must be the workflow's own ref (branch tip on schedule, selected ref
# on workflow_dispatch), not a frozen SHA.
grep -Eq '^[[:space:]]*ref:[[:space:]]*\$\{\{[[:space:]]*github\.ref[[:space:]]*\}\}' "${WF}" \
  || { echo "FAIL: checkout ref must be github.ref so re-runs take the branch tip"; exit 1; }

echo "weekly-workflow checkout-ref test passed"
