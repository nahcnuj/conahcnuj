#!/usr/bin/env bash
# conahcnuj abnormal-exit bug-report test (offline).
#
# When the driver cannot resolve the issue it must not die silently: an
# abnormal exit (here: every model produces no changes, so implementation fails)
# triggers the EXIT trap, which files a bug report issue. The report goes to the
# conahcnuj repository (here configured with CONAHCNUJ_BUG_REPO=nahcnuj/conahcnuj),
# NOT to the repository being worked on (CONAHCNUJ_REPO=nahcnuj/makamujo): the
# bug is about the driver, and the GitHub App token is only guaranteed to be
# able to write to its own repository. The mocked API tape ends with the created
# issue's response. Asserts that the original exit code is preserved, the
# failure is logged, and the bug report issue landed in conahcnuj while the
# body still names the item worked on in makamujo.
#
# Also covers the auto-detection chain: the driver's own origin remote when no
# CONAHCNUJ_BUG_REPO is set, the App-derived target (installed layout with no
# origin and no config), and the final conahcnuj fallback when even that is
# unavailable offline — never the working repository (issue #40).
#
# No secrets, no network.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
DRIVER="${REPO}/bin/conahcnuj.sh"
# The driver's own checkout origin: the auto-detected report target when no
# CONAHCNUJ_BUG_REPO is configured (used by the second scenario below).
DRIVER_REPO="$(git -C "${REPO}" remote get-url origin 2>/dev/null | sed -E 's#.*github\.com[:/]##; s#\.git$##' || true)"

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

# Mocked response tape, in call order:
#   fetch_issue, get_repo, find_pr_by_head_any (empty), create_issue (25).
# The mocked opencode is a no-op for every model, so implement produces no
# changes, start_issue exits 1, and the EXIT trap files the bug report (one
# extra API call reading the created issue's number).
TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'EOF'
{"number": 14, "title": "test issue that cannot be implemented", "body": "dummy body", "labels": [], "state": "open"}
{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}}}}
{"data":{"repository":{"pullRequests":{"nodes":[]}}}}
{"number": 25}
EOF

unset CONAHCNUJ_COMMIT_MODEL
export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1
export MOCK_OPENCODE_MODELS="opencode/first"
export MOCK_OPENCODE_NOOP="opencode/first"

# --- Scenario 1: explicit CONAHCNUJ_BUG_REPO --------------------------------
# Work on nahcnuj/makamujo; the bug report must land in nahcnuj/conahcnuj.
export CONAHCNUJ_BUG_REPO="nahcnuj/conahcnuj"
export CONAHCNUJ_REPO="nahcnuj/makamujo"

LOG="${ROOT}/run.log"
RC=0
(
  cd "${WORK}"
  CONAHCNUJ_MAX_SECONDS=120 bash "${DRIVER}" 14 < "${TAPE}"
) > "${LOG}" 2>&1 || RC=$?

echo "----- conahcnuj bugreport run log -----"
cat "${LOG}"
echo "----------------------------------------"

[[ ${RC} -ne 0 ]] || { echo "FAIL: driver exited 0 (expected an abnormal exit)"; exit 1; }
[[ ${RC} -eq 1 ]] || { echo "FAIL: driver exit code ${RC} (expected 1)"; exit 1; }

grep -q "could not implement issue #14" "${LOG}" || { echo "FAIL: implementation failure was not logged"; exit 1; }
grep -q "filing a bug report issue in nahcnuj/conahcnuj" "${LOG}" || { echo "FAIL: no bug report filing message for conahcnuj"; exit 1; }
grep -q "Bug report issue #25 created" "${LOG}" || { echo "FAIL: bug report issue #25 was not created"; exit 1; }
grep -q "https://github.com/nahcnuj/conahcnuj/issues/25" "${LOG}" || { echo "FAIL: bug report URL is missing"; exit 1; }
grep -q "filing a bug report issue in nahcnuj/makamujo" "${LOG}" && { echo "FAIL: the report went to the working repository instead of conahcnuj"; exit 1; }

# --- Scenario 2: auto-detected report target ---------------------------------
# Without CONAHCNUJ_BUG_REPO the driver falls back to its own checkout's
# origin remote. The working repo is still nahcnuj/makamujo, so this proves
# the two repositories are decoupled by default.
unset CONAHCNUJ_BUG_REPO
if [[ -n "${DRIVER_REPO}" ]]; then
  LOG2="${ROOT}/run2.log"
  RC2=0
  (
    cd "${WORK}"
    CONAHCNUJ_MAX_SECONDS=120 bash "${DRIVER}" 14 < "${TAPE}"
  ) > "${LOG2}" 2>&1 || RC2=$?
  [[ ${RC2} -eq 1 ]] || { echo "FAIL: scenario 2 driver exit code ${RC2} (expected 1)"; exit 1; }
  grep -q "filing a bug report issue in ${DRIVER_REPO}" "${LOG2}" || { echo "FAIL: report did not go to the driver's own repository (${DRIVER_REPO})"; exit 1; }
fi

# --- Scenario 3: installed layout (no origin, no config) ----------------------
# An installed driver (~/.local/bin deployed by install.ps1) sits next to its
# lib/ and gh-app/ but outside any git checkout, so the origin-remote guess of
# scenario 2 is unavailable. In offline test mode the App-derived lookup is
# skipped too, so the report falls back to the conahcnuj repository itself with
# a warning — never to the working repository (issue #40) — and the driver
# still exits cleanly (never silently dead).
INST="${ROOT}/installed"
mkdir -p "${INST}/bin" "${INST}/lib" "${INST}/gh-app"
cp "${REPO}/bin/conahcnuj.sh" "${INST}/bin/conahcnuj.sh"
cp "${REPO}"/lib/*.sh "${INST}/lib/"
cp "${REPO}"/gh-app/*.sh "${INST}/gh-app/"
cp "${REPO}/gh-app/app.env.example" "${INST}/gh-app/app.env.example"
export CONAHCNUJ_REPO="nahcnuj/makamujo"
LOG3="${ROOT}/run3.log"
RC3=0
(
  cd "${WORK}"
  CONAHCNUJ_MAX_SECONDS=120 bash "${INST}/bin/conahcnuj.sh" 14 < "${TAPE}"
) > "${LOG3}" 2>&1 || RC3=$?
[[ ${RC3} -eq 1 ]] || { echo "FAIL: scenario 3 driver exit code ${RC3} (expected 1)"; exit 1; }
grep -q "WARNING: no bug-report repository could be resolved; filing the report into nahcnuj/conahcnuj" "${LOG3}" || { echo "FAIL: scenario 3 did not warn about the conahcnuj fallback"; exit 1; }
grep -q "filing a bug report issue in nahcnuj/conahcnuj" "${LOG3}" || { echo "FAIL: scenario 3 did not file into the conahcnuj fallback repository"; exit 1; }
grep -q "filing a bug report issue in nahcnuj/makamujo" "${LOG3}" && { echo "FAIL: scenario 3 fell back to the working repository"; exit 1; }
unset CONAHCNUJ_REPO

# --- unit: the bug report body carries a detailed error log -----------------
# Source the driver (CONAHCNUJ_IMPORT=1, so main() is not run) and stub
# gh_api_create_issue to capture the body it would send. Assert the report
# includes the tail of the run log and names the item worked on in the WORKING
# repository (nahcnuj/makamujo) even though the issue is filed in conahcnuj.
(
  CONAHCNUJ_IMPORT=1
  unset CONAHCNUJ_REPO CONAHCNUJ_BUG_REPO
  # Source the driver so its functions (plus our stub) run in one shell.
  # shellcheck source=bin/conahcnuj.sh
  source "${DRIVER}"
  gh_api_create_issue() {
    printf '%s\n' "${4}" > "${ROOT}/captured-body.txt"
    printf '99\n'
  }
  RUN_LOG_FILE="$(mktemp)"
  printf '%s\n' \
    "Issue #14: test issue that cannot be implemented" \
    "opencode: trying model opencode/first" \
    "ERROR: could not implement issue #14 with any available model." \
    > "${RUN_LOG_FILE}"
  BUG_REPORT_OWNER="nahcnuj"
  BUG_REPORT_REPO="conahcnuj"
  BUG_WORK_OWNER="nahcnuj"
  BUG_WORK_REPO="makamujo"
  BUG_REPORT_INPUT="14"
  BUG_REPORTED="0"
  report_bug_on_exit "1"
  # bug_report_repo: explicit value wins over everything else.
  out1="$(CONAHCNUJ_BUG_REPO="nahcnuj/conahcnuj" bug_report_repo)"
  [[ "${out1}" == "nahcnuj/conahcnuj" ]] || { echo "FAIL: explicit CONAHCNUJ_BUG_REPO was not honoured"; exit 1; }
  # ... and with nothing configured the driver's own origin remote is used.
  out2="$(bug_report_repo)"
  if [[ -n "${DRIVER_REPO}" ]]; then
    [[ "${out2}" == "${DRIVER_REPO}" ]] || { echo "FAIL: auto-detected report repo ${out2} (expected ${DRIVER_REPO})"; exit 1; }
  fi
  # ... but an origin that IS the working repository is never used as the
  # report target (issue #40): with the working repo passed in, nothing is
  # printed so report_bug_on_exit falls through to the conahcnuj-targeted
  # lookups instead of filing the report in the very repo the run failed on.
  if [[ -n "${DRIVER_REPO}" ]]; then
    out3="$(bug_report_repo "${DRIVER_REPO}")"
    [[ -z "${out3}" ]] || { echo "FAIL: the working repository ${DRIVER_REPO} was accepted as the report target"; exit 1; }
    out4="$(bug_report_repo "naHcnuj/CoNahcnUj")"
    [[ -z "${out4}" ]] || { echo "FAIL: case-variant of the working repository was accepted as the report target (${out4})"; exit 1; }
  fi
  run_log_cleanup
)

grep -q "## Error log" "${ROOT}/captured-body.txt" || { echo "FAIL: bug report has no error log section"; exit 1; }
grep -q "ERROR: could not implement issue #14 with any available model." "${ROOT}/captured-body.txt" || { echo "FAIL: the error log does not carry the failing message"; exit 1; }
grep -q "Exit code: 1" "${ROOT}/captured-body.txt" || { echo "FAIL: exit code is missing from the report"; exit 1; }
grep -q "nahcnuj/makamujo#14" "${ROOT}/captured-body.txt" || { echo "FAIL: the report does not name the item worked on in makamujo"; exit 1; }
grep -q "Repository:" "${ROOT}/captured-body.txt" && { echo "FAIL: self-evident repository line is still in the report"; exit 1; }

# --- unit: App-derived report target (installed layout) ----------------------
# When neither CONAHCNUJ_BUG_REPO nor the driver's origin remote resolves (the
# installed ~/.local/bin layout), the bug-report repository is derived from the
# GitHub App's own installation on the abnormal-exit path: the repository whose
# short name equals APP_SLUG, falling back to the installation owner + APP_SLUG.
# Placeholder settings stay unset. Offline: gh_api_call is stubbed.
(
  CONAHCNUJ_IMPORT=1
  unset CONAHCNUJ_REPO CONAHCNUJ_BUG_REPO GH_API_TEST_MODE
  # Source the driver so its functions (plus our stubs) run in one shell.
  # shellcheck source=bin/conahcnuj.sh
  source "${DRIVER}"

  # A fixture app.env describing a real App (APP_SLUG=conahcnuj) in a gh-app
  # dir that is not a git checkout, exactly like an installed driver's.
  FIXAPP="${ROOT}/ghapp"
  mkdir -p "${FIXAPP}"
  cat > "${FIXAPP}/app.env" <<'EOF'
APP_ID="1"
INSTALLATION_ID="2"
APP_SLUG="conahcnuj"
PRIVATE_KEY_PATH="/nonexistent"
BASH_EXE="/bin/bash"
EOF
  export GH_APP_DIR="${FIXAPP}"

  # Stub the installation-repositories lookup: the App covers makamujo (the
  # working repo) and conahcnuj (its own project).
  gh_api_call() {
    printf '%s\n' '{"total_count":2,"repositories":[{"id":1,"node_id":"n1","name":"makamujo","full_name":"nahcnuj/makamujo","private":true,"owner":{"login":"nahcnuj","id":1}},{"id":2,"node_id":"n2","name":"conahcnuj","full_name":"nahcnuj/conahcnuj","private":true,"owner":{"login":"nahcnuj","id":2}}],"permissions":{"issues":"write"}}'
  }

  # The repository whose short name equals the App slug is the driver's project.
  out="$(bug_report_app_repo)"
  [[ "${out}" == "nahcnuj/conahcnuj" ]] || { echo "FAIL: App-derived report repo ${out} (expected nahcnuj/conahcnuj)"; exit 1; }

  # Without a matching repository, the installation owner + APP_SLUG is used.
  gh_api_call() {
    printf '%s\n' '{"total_count":1,"repositories":[{"id":1,"node_id":"n1","name":"makamujo","full_name":"nahcnuj/makamujo","private":true,"owner":{"login":"nahcnuj","id":1}}],"permissions":{}}'
  }
  out="$(bug_report_app_repo)"
  [[ "${out}" == "nahcnuj/conahcnuj" ]] || { echo "FAIL: owner fallback ${out} (expected nahcnuj/conahcnuj)"; exit 1; }

  # A placeholder APP_SLUG means "not configured": nothing is derived.
  export GH_APP_DIR="${ROOT}/ghapp-ph"
  mkdir -p "${GH_APP_DIR}"
  printf 'APP_SLUG="<your-app-name>"\n' > "${GH_APP_DIR}/app.env"
  out="$(bug_report_app_repo)"
  [[ -z "${out}" ]] || { echo "FAIL: placeholder APP_SLUG derived ${out} (expected nothing)"; exit 1; }

  # Installed-layout abnormal exit: with no static bug-report repository, the
  # EXIT trap derives nahcnuj/conahcnuj from the App installation instead of
  # falling back to the working repository (nahcnuj/makamujo).
  export GH_APP_DIR="${FIXAPP}"
  gh_api_create_issue() {
    printf '%s/%s\n' "${1}" "${2}" > "${ROOT}/trap-target.txt"
    printf '77\n'
  }
  RUN_LOG_FILE="$(mktemp)"
  printf 'ERROR: could not implement issue #14\n' > "${RUN_LOG_FILE}"
  BUG_REPORT_OWNER=""
  BUG_REPORT_REPO=""
  BUG_WORK_OWNER="nahcnuj"
  BUG_WORK_REPO="makamujo"
  BUG_REPORT_INPUT="14"
  BUG_REPORTED="0"
  report_bug_on_exit "1"
  got="$(cat "${ROOT}/trap-target.txt")"
  [[ "${got}" == "nahcnuj/conahcnuj" ]] || { echo "FAIL: trap filed the report into ${got} (expected nahcnuj/conahcnuj)"; exit 1; }
  run_log_cleanup
)

echo "conahcnuj abnormal-exit bug report passed"
