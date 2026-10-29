#!/usr/bin/env bash
# api-commit.sh must not let curl's raw exit code (22 for HTTP errors) escape.
# It should exit 1 with the GitHub API status/body so a bug report identifies a
# permissions/auth failure instead of just "exit 22". No network/secrets.
# Usage: bash api-commit-http-error.sh <staged gh-app dir>
set -euo pipefail

STAGE="${1:?staged gh-app dir required}"
APICOMMIT_SRC="${STAGE}/api-commit.sh"

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT

PRIV="${ROOT}/priv"
mkdir -p "${PRIV}/gh-app" "${PRIV}/bin"
cp "${APICOMMIT_SRC}" "${PRIV}/gh-app/api-commit.sh"
cat > "${PRIV}/gh-app/app.env" <<'EOF'
APP_ID=1
EOF
cat > "${PRIV}/gh-app/get-token.sh" <<'EOF'
#!/usr/bin/env bash
printf 'fake-token'
EOF
chmod +x "${PRIV}/gh-app/get-token.sh"

cat > "${PRIV}/bin/curl" <<'EOF'
#!/usr/bin/env bash
case "${MOCK_CURL_MODE}" in
  forbidden)
    printf '{"message":"Resource not accessible by integration"}\n403'
    ;;
  transport)
    exit 22
    ;;
  missing-branch-forbidden)
    if [[ "$*" == *"/git/refs/heads/"* ]]; then
      printf '{"message":"Not Found"}\n404'
    else
      printf '{"message":"Forbidden"}\n403'
    fi
    ;;
  *) exit 99 ;;
esac
EOF
chmod +x "${PRIV}/bin/curl"
export PATH="${PRIV}/bin:${PATH}"

W="${ROOT}/W"
git init -q "${W}"
git -C "${W}" config user.email "mock@test"
git -C "${W}" config user.name "mock"
git -C "${W}" config commit.gpgsign false
printf 'base\n' > "${W}/f.txt"
git -C "${W}" add -A
git -C "${W}" commit -qm init
git -C "${W}" branch -M main
printf 'change\n' >> "${W}/f.txt"
git -C "${W}" add -A

run_case() {
  local mode="${1}"
  local out="${ROOT}/${mode}.out"
  local rc=0
  (
    cd "${W}"
    MOCK_CURL_MODE="${mode}" \
      bash "${PRIV}/gh-app/api-commit.sh" o/r feature -m msg
  ) > "${out}" 2>&1 || rc=$?
  printf '%s' "${out}"
  return "${rc}"
}

OUT="$(run_case forbidden)" || RC=$?
RC="${RC:-0}"
[[ ${RC} -eq 1 ]] || { echo "FAIL: HTTP 403 exited ${RC} (expected 1)"; cat "${OUT}"; exit 1; }
grep -q "HTTP 403" "${OUT}" || { echo "FAIL: HTTP 403 was not reported"; cat "${OUT}"; exit 1; }
grep -q "Resource not accessible by integration" "${OUT}" || { echo "FAIL: API error body was not reported"; cat "${OUT}"; exit 1; }
echo "PASS api-commit.sh reports HTTP 403 and exits 1"

unset RC
OUT="$(run_case transport)" || RC=$?
RC="${RC:-0}"
[[ ${RC} -eq 1 ]] || { echo "FAIL: curl transport error exited ${RC} (expected 1)"; cat "${OUT}"; exit 1; }
grep -q "curl exit 22" "${OUT}" || { echo "FAIL: curl transport error was not reported"; cat "${OUT}"; exit 1; }
echo "PASS api-commit.sh reports curl transport errors and exits 1"

unset RC
OUT="$(run_case missing-branch-forbidden)" || RC=$?
RC="${RC:-0}"
[[ ${RC} -eq 1 ]] || { echo "FAIL: missing branch + 403 exited ${RC} (expected 1)"; cat "${OUT}"; exit 1; }
grep -q "repos/o/r -> HTTP 403" "${OUT}" || { echo "FAIL: repo-level 403 was not reported after an expected branch 404"; cat "${OUT}"; exit 1; }
! grep -q "curl: (22)" "${OUT}" || { echo "FAIL: raw curl exit 22 leaked into output"; cat "${OUT}"; exit 1; }
echo "PASS api-commit.sh distinguishes an expected branch 404 from a repo 403"
