#!/usr/bin/env bash
# resolve_agent_branch_name test (offline).
#
# When the coding agent writes .branch-name during the implementation round, the
# driver must use that name for the feature branch instead of its own derived
# one. A missing / blank / invalid .branch-name falls back to the driver name.
# Runs in TEST_MODE so no network or API is needed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

ROOT="$(mktemp -d)"
WORK="${ROOT}/repo"
trap 'rm -rf "${ROOT}"' EXIT
mkdir -p "${WORK}"

git -C "${WORK}" init -q
git -C "${WORK}" config user.email "test@example.com"
git -C "${WORK}" config user.name "test"
git -C "${WORK}" config commit.gpgsign false
printf 'base\n' > "${WORK}/file.txt"
git -C "${WORK}" add -A
git -C "${WORK}" commit -qm init
git -C "${WORK}" branch -M main
git -C "${WORK}" checkout -q -b "conahcnuj/10-issue"

export CONAHCNUJ_TEST_MODE=1
export CONAHCNUJ_IMPORT=1
# shellcheck source=bin/conahcnuj.sh
. "${REPO}/bin/conahcnuj.sh"

cd "${WORK}" || exit 1

DEFAULT_OID="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
CURRENT="conahcnuj/10-issue"

# 1. No .branch-name: the driver-derived name is kept.
out="$(resolve_agent_branch_name "nahcnuj" "conahcnuj" "${DEFAULT_OID}" "${CURRENT}")"
[[ "${out}" == "${CURRENT}" ]] || { echo "FAIL: expected ${CURRENT}, got ${out}" >&2; exit 1; }
echo "resolve_agent_branch_name (no .branch-name) -> driver name: passed"

# 2. Valid agent branch name is honoured (renamed locally).
printf 'feature/agent-choice\n' > .branch-name
out="$(resolve_agent_branch_name "nahcnuj" "conahcnuj" "${DEFAULT_OID}" "${CURRENT}")"
if [[ "${out}" != "feature/agent-choice" ]]; then
  echo "FAIL: expected feature/agent-choice, got ${out}" >&2
  exit 1
fi
if [[ "$(git -C "${WORK}" branch --show-current)" != "feature/agent-choice" ]]; then
  echo "FAIL: branch was not renamed to the agent's choice" >&2
  exit 1
fi
if [[ -e ".branch-name" ]]; then
  echo "FAIL: .branch-name must be consumed" >&2
  exit 1
fi
echo "resolve_agent_branch_name (agent .branch-name) -> renamed: passed"

# 3. Blank .branch-name: falls back to the current (already agent-named) branch.
printf '   \n' > .branch-name
out="$(resolve_agent_branch_name "nahcnuj" "conahcnuj" "${DEFAULT_OID}" "feature/agent-choice")"
[[ "${out}" == "feature/agent-choice" ]] || { echo "FAIL: expected feature/agent-choice, got ${out}" >&2; exit 1; }
if [[ -e ".branch-name" ]]; then
  echo "FAIL: blank .branch-name must be consumed" >&2
  exit 1
fi
echo "resolve_agent_branch_name (blank .branch-name) -> fallback: passed"

# 4. Invalid branch name: warns and keeps the current branch.
printf 'bad name with spaces\n' > .branch-name
out="$(resolve_agent_branch_name "nahcnuj" "conahcnuj" "${DEFAULT_OID}" "feature/agent-choice")"
[[ "${out}" == "feature/agent-choice" ]] || { echo "FAIL: invalid name must fall back, got ${out}" >&2; exit 1; }
if [[ "$(git -C "${WORK}" branch --show-current)" != "feature/agent-choice" ]]; then
  echo "FAIL: branch changed on an invalid .branch-name" >&2
  exit 1
fi
if [[ -e ".branch-name" ]]; then
  echo "FAIL: invalid .branch-name must be consumed" >&2
  exit 1
fi
echo "resolve_agent_branch_name (invalid .branch-name) -> fallback: passed"

echo "resolve_agent_branch_name passed"