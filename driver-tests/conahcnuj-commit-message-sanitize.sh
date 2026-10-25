#!/usr/bin/env bash
# A .commit-msg that is not plain UTF-8 must not break the commit or the API.
#
# The agent can leave a file encoded as UTF-16 (a BOM plus NUL bytes between
# every ASCII character). Reading it with `message="$(head -1 .commit-msg)"`
# made bash print "ignored null byte in input", drop the NULs, and leave the
# UTF-16 BOM behind as invalid UTF-8. That string went into the commit
# message, GitHub answered 400 "Problems parsing JSON", and even the bug
# report failed because its body is built from the same run log.
#
# commit_changes must strip NULs without the warning and coerce the message to
# valid UTF-8, so the commit lands with the intended text. No secrets, no
# network (TEST_MODE does a local commit).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
DRIVER="${REPO}/bin/conahcnuj.sh"
# Source the driver (main() is skipped) in both blocks below.
export CONAHCNUJ_IMPORT=1

ROOT="$(mktemp -d)"
WORK="${ROOT}/repo"
trap 'rm -rf "${ROOT}"' EXIT
mkdir -p "${WORK}"

git -C "${WORK}" init -q
git -C "${WORK}" config user.email "test@example.com"
git -C "${WORK}" config user.name "test"
git -C "${WORK}" config commit.gpgsign false
printf 'base\n' > "${WORK}/f.txt"
git -C "${WORK}" add -A
git -C "${WORK}" commit -qm init
printf 'change\n' >> "${WORK}/f.txt"

# UTF-16LE BOM followed by "fix: keep it" (NUL after every ASCII byte).
printf '\377\376f\000i\000x\000:\000 \000k\000e\000e\000p\000 \000i\000t\000\n\000' > "${WORK}/.commit-msg"

(
  cd "${WORK}"
  # The wrapping session (the conahcnuj opencode plugin) exports these for the
  # real driver runs; the exact-message check below must not see a trailer.
  # They have to go before source: the driver snapshots CONAHCNUJ_COMMIT_MODEL
  # into USER_COMMIT_MODEL while being sourced.
  unset CONAHCNUJ_COMMIT_MODEL CONAHCNUJ_MODEL_LABEL_FILE OPENCODE_LAST_MODEL \
    CONAHCNUJ_SESSION_MODEL
  # shellcheck source=bin/conahcnuj.sh
  source "${DRIVER}"
  TEST_MODE=1
  commit_changes 2> "${ROOT}/commit.log"
)

if grep -q "ignored null byte" "${ROOT}/commit.log"; then
  echo "FAIL: reading .commit-msg still warns about a null byte" >&2
  cat "${ROOT}/commit.log" >&2
  exit 1
fi

MESSAGE="$(git -C "${WORK}" log -1 --pretty=%B)"
if [[ "${MESSAGE}" != "fix: keep it" ]]; then
  echo "FAIL: commit message was not sanitized: '${MESSAGE}'" >&2
  exit 1
fi
if printf '%s' "${MESSAGE}" | LC_ALL=C grep -q '[[:cntrl:]]'; then
  echo "FAIL: a control byte survived into the commit message" >&2
  exit 1
fi

# The run log is the bug report's body: invalid bytes there must not reach the
# API payload either, or the report for a failed run is lost to the same 400.
(
  # shellcheck source=bin/conahcnuj.sh
  source "${DRIVER}"
  gh_api_create_issue() {
    printf '%s' "${4}" > "${ROOT}/body.txt"
    printf '99\n'
  }
  RUN_LOG_FILE="${ROOT}/run.log"
  printf 'before \377\376 after\n' > "${RUN_LOG_FILE}"
  BUG_REPORT_INPUT="14"
  BUG_REPORTED="0"
  report_bug_on_exit "1"
)
if LC_ALL=C grep -q $'\377\376' "${ROOT}/body.txt"; then
  echo "FAIL: invalid UTF-8 reached the bug-report body" >&2
  exit 1
fi
grep -q "before  after" "${ROOT}/body.txt" || {
  echo "FAIL: the sanitized run log did not survive into the report" >&2
  cat "${ROOT}/body.txt" >&2
  exit 1
}

echo "conahcnuj commit-message sanitize passed"
