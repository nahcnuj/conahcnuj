#!/usr/bin/env bash
# Model trailer on api-commit.sh --dry-run. No token, no network.
# Usage: bash api-commit-trailer.sh <staged gh-app dir>
set -euo pipefail

STAGE="${1:?staged gh-app dir required}"
APICOMMIT="${STAGE}/api-commit.sh"

FIX="$(mktemp -d)"
trap 'rm -rf "${FIX}"' EXIT
git -C "${FIX}" init -q
git -C "${FIX}" config user.email "mock@test"
git -C "${FIX}" config user.name "mock"
git -C "${FIX}" config commit.gpgsign false
printf 'base\n' > "${FIX}/file.txt"
git -C "${FIX}" add -A
git -C "${FIX}" commit -qm init
printf 'change\n' >> "${FIX}/file.txt"
git -C "${FIX}" add -A

run_dry() {
  (
    cd "${FIX}"
    bash "${APICOMMIT}" o/r b -m "fix: record the sample" --dry-run
  )
}

OUT="$(CONAHCNUJ_COMMIT_MODEL='Grok 4.7 (medium)' run_dry)"
if [[ "${OUT}" != *"Message:    fix: record the sample"* ]]; then
  echo "FAIL: headline changed:" >&2
  echo "${OUT}" >&2
  exit 1
fi
if [[ "${OUT}" != *"Body:       Model: Grok 4.7 (medium)"* ]]; then
  echo "FAIL: model trailer missing:" >&2
  echo "${OUT}" >&2
  exit 1
fi
echo "PASS model label becomes a Model trailer"

OUT="$(run_dry)"
if [[ "${OUT}" == *"Body:"* ]]; then
  echo "FAIL: trailer added without a label:" >&2
  echo "${OUT}" >&2
  exit 1
fi
echo "PASS unset CONAHCNUJ_COMMIT_MODEL adds no trailer"

OUT="$(CONAHCNUJ_COMMIT_MODEL=$'Grok 4.7\n(medium)' run_dry)"
if [[ "${OUT}" != *"Body:       Model: Grok 4.7 (medium)"* ]]; then
  echo "FAIL: multiline label was not collapsed:" >&2
  echo "${OUT}" >&2
  exit 1
fi
echo "PASS multiline model label collapses to one trailer line"

OUT="$(
  cd "${FIX}"
  CONAHCNUJ_COMMIT_MODEL='other' bash "${APICOMMIT}" o/r b -m $'fix: kept\n\nModel: already' --dry-run
)"
if [[ "${OUT}" != *"Body:       Model: already"* ]] || [[ "${OUT}" == *"other"* ]]; then
  echo "FAIL: existing Model trailer was rewritten:" >&2
  echo "${OUT}" >&2
  exit 1
fi
echo "PASS existing Model trailer is kept"
