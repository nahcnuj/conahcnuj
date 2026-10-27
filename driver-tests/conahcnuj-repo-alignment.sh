#!/usr/bin/env bash
# verify_repo_alignment test (offline).
#
# When the run's target (CONAHCNUJ_REPO) and the local origin remote point at
# different GitHub repositories, the feature branch is created on the target
# while fetches and Verified commits go through origin: the fetch of the fresh
# branch fails or the commits land in the wrong repository (issue #309). The
# guard stops such a run with a clear error before any work is lost, and stays
# out of the way when the two agree, when the origin is not GitHub (offline
# tests use local paths), or when no target is given.
#
# Sources bin/conahcnuj.sh via CONAHCNUJ_IMPORT=1 (main() must not run) and
# calls verify_repo_alignment directly, so no network is needed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

ROOT="$(mktemp -d)"
WORK="${ROOT}/repo"
trap 'rm -rf "${ROOT}"' EXIT

git init -q "${WORK}"
git -C "${WORK}" config user.email "test@example.com"
git -C "${WORK}" config user.name "test"
git -C "${WORK}" config commit.gpgsign false

cd "${WORK}" || exit 1
CONAHCNUJ_IMPORT=1
CONAHCNUJ_TEST_MODE=0
# shellcheck source=bin/conahcnuj.sh
. "${REPO}/bin/conahcnuj.sh"

# 1. A GitHub origin that agrees with the target: the guard passes.
git -C "${WORK}" remote add origin "https://github.com/nahcnuj/conahcnuj.git"
(
  verify_repo_alignment "nahcnuj/conahcnuj"
) >"${ROOT}/ok.log" 2>&1 || {
  echo "FAIL: an aligned origin/target pair was rejected: $(cat "${ROOT}/ok.log")" >&2
  exit 1
}

# 2. A GitHub origin that disagrees with the target (the #309 scenario): the
#    guard stops the run and names both repositories.
git -C "${WORK}" remote set-url origin "https://github.com/nahcnuj/conahcnuj.git"
rc=0
(
  verify_repo_alignment "nahcnuj/makamujo"
) >"${ROOT}/mismatch.log" 2>&1 || rc=$?
[[ ${rc} -ne 0 ]] || { echo "FAIL: a mismatched origin/target pair was accepted" >&2; exit 1; }
grep -q "origin points at nahcnuj/conahcnuj" "${ROOT}/mismatch.log" || {
  echo "FAIL: the error does not name origin's repository: $(cat "${ROOT}/mismatch.log")" >&2
  exit 1
}
grep -q "targets nahcnuj/makamujo" "${ROOT}/mismatch.log" || {
  echo "FAIL: the error does not name the target repository: $(cat "${ROOT}/mismatch.log")" >&2
  exit 1
}

# 3. An SSH GitHub origin that disagrees as well: the guard is URL-shape agnostic.
git -C "${WORK}" remote set-url origin "git@github.com:nahcnuj/conahcnuj.git"
rc=0
(
  verify_repo_alignment "nahcnuj/makamujo"
) >"${ROOT}/ssh.log" 2>&1 || rc=$?
[[ ${rc} -ne 0 ]] || { echo "FAIL: an SSH mismatched origin/target pair was accepted" >&2; exit 1; }

# 4. A non-GitHub origin (offline tests use local paths): the guard skips.
git -C "${WORK}" remote set-url origin "${ROOT}/local-origin.git"
(
  verify_repo_alignment "nahcnuj/makamujo"
) >"${ROOT}/local.log" 2>&1 || {
  echo "FAIL: a non-GitHub origin was rejected: $(cat "${ROOT}/local.log")" >&2
  exit 1
}

# 5. No target at all: the guard passes (repo_detect falls back to origin).
git -C "${WORK}" remote set-url origin "https://github.com/nahcnuj/conahcnuj.git"
(
  verify_repo_alignment ""
) >"${ROOT}/empty.log" 2>&1 || {
  echo "FAIL: an empty target was rejected: $(cat "${ROOT}/empty.log")" >&2
  exit 1
}

echo "conahcnuj repo alignment guard passed"
