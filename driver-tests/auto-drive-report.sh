#!/usr/bin/env bash
# auto-drive-report.sh offline test (no secrets, no network).
#
# The weekly self-improvement workflow feeds this analyzer with the "Issue
# auto-drive" run logs and gates its driver dispatch on the meta line
# (runs=/findings=/actionable=). The test pins that contract: outcome
# classification, per-model round accounting, findings severity, run URLs, and
# the usage/exit-code behaviour the workflow relies on.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
REPORT="${REPO}/bin/auto-drive-report.sh"

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT

# --- usage errors -----------------------------------------------------------
rc=0
bash "${REPORT}" >/dev/null 2>&1 || rc=$?
[[ ${rc} -eq 1 ]] || { echo "FAIL: no arguments must exit 1 (got ${rc})"; exit 1; }

rc=0
bash "${REPORT}" "${ROOT}/no-such-path" >/dev/null 2>&1 || rc=$?
[[ ${rc} -eq 1 ]] || { echo "FAIL: unreadable path must exit 1 (got ${rc})"; exit 1; }

# --- empty input: a period without runs is a report, not an error -----------
mkdir -p "${ROOT}/empty"
out="$(bash "${REPORT}" "${ROOT}/empty")"
grep -q '<!-- auto-drive-report runs=0 findings=0 actionable=0 -->' <<<"${out}" \
  || { echo "FAIL: empty input must report runs=0"; exit 1; }
grep -q 'No run logs found' <<<"${out}" \
  || { echo "FAIL: empty input must say so in prose"; exit 1; }

# --- a clean week: no findings, actionable=0 (workflow must not dispatch) ---
mkdir -p "${ROOT}/clean"
cat > "${ROOT}/clean/run-101.log" <<'EOF'
2026-10-05T01:17:04.1234567Z ##[group]Run bash bin/conahcnuj.sh 21
2026-10-05T01:17:20.0000000Z opencode: trying model opencode/alpha
2026-10-05T01:18:40.0000000Z Model opencode/alpha completed the work.
2026-10-05T01:18:41.0000000Z Created PR #126 (feature/x -> main).
2026-10-05T01:19:00.0000000Z Review requested on PR #126 (reviewer: nahcnuj): https://github.com/nahcnuj/conahcnuj/pull/126
EOF
out="$(bash "${REPORT}" --runs-url-prefix https://github.com/nahcnuj/conahcnuj/actions/runs "${ROOT}/clean")"
grep -q '<!-- auto-drive-report runs=1 findings=0 actionable=0 -->' <<<"${out}" \
  || { echo "FAIL: a clean run must produce findings=0 actionable=0"; exit 1; }
grep -q 'No findings for this period.' <<<"${out}" \
  || { echo "FAIL: a clean run must say there are no findings"; exit 1; }
grep -q '| handed-off | 1 |' <<<"${out}" \
  || { echo "FAIL: the review hand-off outcome must be counted"; exit 1; }
grep -q '\[run-101.log\](https://github.com/nahcnuj/conahcnuj/actions/runs/101)' <<<"${out}" \
  || { echo "FAIL: run-<id>.log must link through --runs-url-prefix"; exit 1; }
grep -q '| opencode/alpha | 1 | 1 | 0 | 0 | 0 | 0 |' <<<"${out}" \
  || { echo "FAIL: per-model round table row is wrong"; exit 1; }

# --- a bad week: mixed outcomes, one actionable finding ---------------------
mkdir -p "${ROOT}/mixed"
# Environment outage: informational, never dispatched on its own.
cat > "${ROOT}/mixed/run-202.log" <<'EOF'
opencode: trying model opencode/alpha
Model opencode/alpha failed before completing the work: environment error (provider unreachable or credentials rejected); giving up on provider opencode for the rest of this run.
Skipping opencode/beta: provider opencode already failed on an environment error, and no other of its models can change that.
ERROR: every model round died on an environment error (provider unreachable or credentials rejected; providers given up on: opencode). Nothing the driver can do about that -- re-run it once its providers are reachable.
Driver exited abnormally (code 1); filing a bug report issue in nahcnuj/conahcnuj.
Bug report issue #130 created: https://github.com/nahcnuj/conahcnuj/issues/130
EOF
# Time budget exhausted: actionable.
cat > "${ROOT}/mixed/run-203.log" <<'EOF'
opencode: trying model opencode/alpha
opencode exceeded the remaining driver time budget; stopping this model.
ERROR: time budget (3540s) exhausted while waiting. Exiting.
Driver exited abnormally (code 1); filing a bug report issue in nahcnuj/conahcnuj.
Bug report issue #131 created: https://github.com/nahcnuj/conahcnuj/issues/131
EOF
# Models produced no complete work at all: actionable.
cat > "${ROOT}/mixed/run-204.log" <<'EOF'
opencode: trying model opencode/alpha
Model opencode/alpha produced no complete work; handing off to the next model.
opencode: trying model opencode/beta
Model opencode/beta left the working tree unchanged and only wrote .commit-msg; handing off to the next model.
Handing off session ses_mock from opencode/alpha to opencode/beta.
ERROR: no available model completed the work (tried: opencode/alpha opencode/beta; handoffs: none).
Driver exited abnormally (code 1); filing a bug report issue in nahcnuj/conahcnuj.
Bug report issue #132 created: https://github.com/nahcnuj/conahcnuj/issues/132
EOF
out="$(bash "${REPORT}" --runs-url-prefix https://github.com/nahcnuj/conahcnuj/actions/runs "${ROOT}/mixed")"

grep -q '<!-- auto-drive-report runs=3 findings=4 actionable=2 -->' <<<"${out}" \
  || { echo "FAIL: mixed meta line is wrong"; echo "${out}" | sed -n '1,5p'; exit 1; }
grep -q '| environment-down | 1 |' <<<"${out}" \
  || { echo "FAIL: environment-down outcome missing"; exit 1; }
grep -q '| time-budget-exhausted | 1 |' <<<"${out}" \
  || { echo "FAIL: time-budget-exhausted outcome missing"; exit 1; }
grep -q '| no-model-completed | 1 |' <<<"${out}" \
  || { echo "FAIL: no-model-completed outcome missing"; exit 1; }
grep -q -- '- bug reports filed: 3' <<<"${out}" \
  || { echo "FAIL: bug report total is wrong"; exit 1; }
grep -q -- '- round budget stops: 1' <<<"${out}" \
  || { echo "FAIL: round budget stop total is wrong"; exit 1; }
grep -qF '### F1. [informational] environment-down' <<<"${out}" \
  || { echo "FAIL: the outage finding must be informational"; exit 1; }
grep -qF '### F2. [actionable] time-budget-exhausted' <<<"${out}" \
  || { echo "FAIL: the budget finding must be actionable"; exit 1; }
grep -qF '### F3. [actionable] no-model-completed' <<<"${out}" \
  || { echo "FAIL: the empty-round finding must be actionable"; exit 1; }
grep -qF '### F4. [informational] models with no completed round' <<<"${out}" \
  || { echo "FAIL: the model-selection finding must follow the run findings"; exit 1; }
grep -q 'url: https://github.com/nahcnuj/conahcnuj/actions/runs/203' <<<"${out}" \
  || { echo "FAIL: findings must link the offending run"; exit 1; }
grep -q 'ERROR: time budget (3540s) exhausted while waiting' <<<"${out}" \
  || { echo "FAIL: findings must quote log excerpts as evidence"; exit 1; }
grep -qE '.opencode/beta. \(1 round\(s\), 0 completed\)' <<<"${out}" \
  || { echo "FAIL: models without a completed round must be listed"; exit 1; }
grep -q '| opencode/alpha | 3 | 0 | 1 | 0 | 1 | 0 |' <<<"${out}" \
  || { echo "FAIL: mixed per-model row for alpha is wrong"; exit 1; }

echo "auto-drive-report test passed"
