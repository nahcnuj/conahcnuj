#!/usr/bin/env bash
# conahcnuj signal-exit test (offline).
#
# Ctrl-C from PowerShell reaches the driver as a signal: the WSL relaunch
# forwards it as TERM, so the driver exits 143 (or 130 for a direct SIGINT).
# That is a deliberate cancellation, not a driver defect, so it must not file a
# bug report issue (issue #203). gh_api_create_issue is stubbed to record any
# call; the stub writes a file because subshell variables would not survive.
#
# No secrets, no network.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
DRIVER="${REPO}/bin/conahcnuj.sh"

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT

export CONAHCNUJ_IMPORT=1

for signal_code in 130 143; do
  rm -f "${ROOT}/called.txt"
  (
    # shellcheck source=bin/conahcnuj.sh
    source "${DRIVER}"
    gh_api_create_issue() {
      printf 'called\n' > "${ROOT}/called.txt"
      printf '99\n'
    }
    RUN_LOG_FILE=""
    BUG_REPORT_INPUT="14"
    BUG_REPORTED="0"
    report_bug_on_exit "${signal_code}"
  )
  [[ -e "${ROOT}/called.txt" ]] && {
    echo "FAIL: exit ${signal_code} filed a bug report" >&2
    exit 1
  }
done

# A normal abnormal exit (a real driver failure) still files the report: the
# signal carve-out must not swallow genuine failures.
rm -f "${ROOT}/called.txt"
(
  # shellcheck source=bin/conahcnuj.sh
  source "${DRIVER}"
  gh_api_create_issue() {
    printf 'called\n' > "${ROOT}/called.txt"
    printf '99\n'
  }
  RUN_LOG_FILE=""
  BUG_REPORT_INPUT="14"
  BUG_REPORTED="0"
  report_bug_on_exit "1"
)
[[ -e "${ROOT}/called.txt" ]] || {
  echo "FAIL: a normal abnormal exit (1) did not file a bug report" >&2
  exit 1
}

echo "conahcnuj signal exit files no bug report passed"
