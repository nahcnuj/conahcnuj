#!/usr/bin/env bash
# Co-Authored-By trailer on api-commit.sh --dry-run. No token, no network.
# Usage: bash api-commit-trailer.sh <staged gh-app dir>
set -euo pipefail

STAGE="${1:?staged gh-app dir required}"
APICOMMIT="${STAGE}/api-commit.sh"

# A wrapping agent session (the conahcnuj opencode plugin) exports
# CONAHCNUJ_COMMIT_MODEL; the label-unset cases below must not see it.
unset CONAHCNUJ_COMMIT_MODEL

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

OUT="$(CONAHCNUJ_COMMIT_MODEL='xai (grok-4.7/medium)' run_dry)"
if [[ "${OUT}" != *"Message:    fix: record the sample"* ]]; then
  echo "FAIL: headline changed:" >&2
  echo "${OUT}" >&2
  exit 1
fi
if [[ "${OUT}" != *"Body:       Co-Authored-By: xai (grok-4.7/medium)"* ]]; then
  echo "FAIL: attribution trailer missing:" >&2
  echo "${OUT}" >&2
  exit 1
fi
echo "PASS model value becomes a Co-Authored-By trailer"

OUT="$(run_dry)"
if [[ "${OUT}" == *"Body:"* ]]; then
  echo "FAIL: trailer added without a value:" >&2
  echo "${OUT}" >&2
  exit 1
fi
echo "PASS unset CONAHCNUJ_COMMIT_MODEL adds no trailer"

OUT="$(CONAHCNUJ_COMMIT_MODEL=$'xai (grok-4.7\nmedium)' run_dry)"
if [[ "${OUT}" != *"Body:       Co-Authored-By: xai (grok-4.7 medium)"* ]]; then
  echo "FAIL: multiline value was not collapsed:" >&2
  echo "${OUT}" >&2
  exit 1
fi
echo "PASS multiline model value collapses to one trailer line"

OUT="$(
  cd "${FIX}"
  CONAHCNUJ_COMMIT_MODEL='Co-Authored-By: openai (gpt-5/medium)' bash "${APICOMMIT}" o/r b -m "fix: record the sample" --dry-run
)"
if [[ "${OUT}" != *"Body:       Co-Authored-By: openai (gpt-5/medium)"* ]]; then
  echo "FAIL: a value that already carries the key was doubled:" >&2
  echo "${OUT}" >&2
  exit 1
fi
echo "PASS a carried trailer key is not repeated"

OUT="$(
  cd "${FIX}"
  CONAHCNUJ_COMMIT_MODEL='xai (grok-4.7/medium)' bash "${APICOMMIT}" o/r b -m $'fix: kept\n\nCo-Authored-By: someone <someone@example.com>' --dry-run
)"
if [[ "${OUT}" != *"Body:       Co-Authored-By: someone <someone@example.com>"* ]] || [[ "${OUT}" == *"grok-4.7"* ]]; then
  echo "FAIL: existing Co-Authored-By trailer was rewritten:" >&2
  echo "${OUT}" >&2
  exit 1
fi
echo "PASS existing Co-Authored-By trailer is kept"
