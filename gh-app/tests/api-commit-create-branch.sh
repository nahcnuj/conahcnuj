#!/usr/bin/env bash
# api-commit.sh branch-ref handling (offline, stubbed get-token.sh + curl).
#
# Covers the paths a real run hits when the feature branch is not where the
# commit expects it (issue #93: a concurrent run's pull request was merged and
# GitHub deleted its head branch while the model was still working):
#   * existing branch: commit on it, no create call
#   * missing branch without --create-branch: clear error, no curl noise
#   * missing branch with --create-branch: ref created from the default branch
#     head, commit expects exactly that head
#   * create loses a race (POST rejected, ref present now): commit on it
#   * create fails and the ref is still missing: clear error
#
# Usage: bash api-commit-create-branch.sh <staged gh-app dir>
set -euo pipefail

STAGE="${1:?staged gh-app dir required}"

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT
mkdir -p "${ROOT}/gh-app" "${ROOT}/bin"

# The script under test with a get-token.sh that needs no key or network.
cp "${STAGE}/api-commit.sh" "${STAGE}/app.env" "${ROOT}/gh-app/"
cat > "${ROOT}/gh-app/get-token.sh" <<'EOF'
#!/usr/bin/env bash
printf 'mock-token'
EOF

# --- stubbed curl -----------------------------------------------------------
# A tiny git/refs + graphql server. MOCK_REFS holds "<branch> <sha>" lines, so
# a test can script what exists on the remote. MOCK_CREATE_REF selects the POST
# outcome: ok | fail | race (rejected because someone else created the ref).
cat > "${ROOT}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
method="GET"; url=""; payload=""; payload_file=""
args=("$@")
i=0
while [[ ${i} -lt ${#args[@]} ]]; do
  case "${args[i]}" in
    -X) method="${args[i+1]}"; i=$((i + 2)) ;;
    -H) i=$((i + 2)) ;;
    -d) payload="${args[i+1]}"; i=$((i + 2)) ;;
    --data-binary)
      # "@file" for the GraphQL body, an inline string for the refs POST.
      if [[ "${args[i+1]}" == @* ]]; then payload_file="${args[i+1]#@}"; else payload="${args[i+1]}"; fi
      i=$((i + 2)) ;;
    -D|-o) i=$((i + 2)) ;;
    *) url="${args[i]}"; i=$((i + 1)) ;;
  esac
done
# The request body as plain text, whichever way it was passed.
body=""
if [[ -n "${payload_file}" ]]; then body="$(cat "${payload_file}")"; else body="${payload}"; fi
printf '%s %s\n' "${method}" "${url}" >> "${MOCK_CURL_LOG}"

api="${GH_APP_API_BASE}/repos/o/r"
ref_sha() {
  local line
  line="$(grep -F "$1 " "${MOCK_REFS}" 2>/dev/null | head -1 || true)"
  printf '%s' "${line#* }"
}
ref_body() {
  printf '{"ref":"refs/heads/%s","object":{"sha":"%s","type":"commit"}}' "$1" "$(ref_sha "$1")"
}
not_found() {
  echo "curl: (22) The requested URL returned error: 404" >&2
  exit 22
}

case "${url}" in
  "${api}/git/refs/heads/"*)
    ref="$(printf '%s' "${url}" | sed 's#.*/git/refs/heads/##')"
    [[ -n "$(ref_sha "${ref}")" ]] || not_found
    ref_body "${ref}"; exit 0 ;;
  "${api}/branches/"*)
    printf '{"name":"%s","commit":{"sha":"%s"}}' "main" "${MOCK_BASE_SHA}"; exit 0 ;;
  "${api}/git/refs")
    [[ "${method}" == "POST" ]] || not_found
    want_ref="$(printf '%s' "${body}" | sed -n 's/.*"ref":"refs\/heads\/\([^"]*\)".*/\1/p')"
    case "${MOCK_CREATE_REF:-ok}" in
      race)
        # Someone else got there first: the ref now exists, our POST is 422.
        printf '%s %s\n' "${want_ref}" "${MOCK_RACE_SHA}" >> "${MOCK_REFS}"
        echo "curl: (22) The requested URL returned error: 422" >&2
        exit 22 ;;
      fail)
        echo "curl: (22) The requested URL returned error: 403" >&2
        exit 22 ;;
      *)
        want_sha="$(printf '%s' "${body}" | sed -n 's/.*"sha":"\([^"]*\)".*/\1/p')"
        printf '%s %s\n' "${want_ref}" "${want_sha}" >> "${MOCK_REFS}"
        ref_body "${want_ref}"; exit 0 ;;
    esac ;;
  "${api}")
    printf '{"full_name":"o/r","default_branch":"main"}'; exit 0 ;;
  "${GH_APP_API_BASE}/graphql")
    cp "${payload_file}" "${MOCK_GRAPHQL_BODY}"
    printf '{"data":{"createCommitOnBranch":{"commit":{"oid":"newsha0000"}}}}'; exit 0 ;;
esac
echo "stub curl: unhandled ${method} ${url}" >&2
exit 1
EOF
chmod +x "${ROOT}/bin/curl"

export PATH="${ROOT}/bin:${PATH}"
# Point the script at a host only the stub answers, so a stub gap can never
# reach the real API.
export GH_APP_API_BASE="https://api.example.test"
export MOCK_BASE_SHA="1111111111111111111111111111111111111111"
export MOCK_RACE_SHA="2222222222222222222222222222222222222222"
export MOCK_REFS="${ROOT}/refs.txt"
export MOCK_CURL_LOG="${ROOT}/curl.log"
export MOCK_GRAPHQL_BODY="${ROOT}/graphql.json"

# --- fixture repo -----------------------------------------------------------
# A local bare "remote" so the trailing `git pull origin <branch>` succeeds
# without network; the ref state the script talks about is the mocked one.
git init -q --bare "${ROOT}/remote.git"
git init -q "${ROOT}/repo"
git -C "${ROOT}/repo" config user.email "mock@test"
git -C "${ROOT}/repo" config user.name "mock"
git -C "${ROOT}/repo" config commit.gpgsign false
printf 'base\n' > "${ROOT}/repo/file.txt"
git -C "${ROOT}/repo" add -A
git -C "${ROOT}/repo" commit -qm init
git -C "${ROOT}/repo" remote add origin "${ROOT}/remote.git"
git -C "${ROOT}/repo" push -q origin HEAD:refs/heads/b

APICOMMIT="${ROOT}/gh-app/api-commit.sh"

# Commit something and hand the staged index to the script.
stage_change() {
  printf 'change\n' >> "${ROOT}/repo/file.txt"
  git -C "${ROOT}/repo" add -A
}

# 1. Existing branch: no create call, the commit targets the branch head.
: > "${MOCK_REFS}"
printf 'b %s\n' "${MOCK_BASE_SHA}" >> "${MOCK_REFS}"
stage_change
OUT="$(cd "${ROOT}/repo" && bash "${APICOMMIT}" o/r b -m msg 2>"${ROOT}/err.txt")"
grep -q 'newsha0000' <<<"${OUT}" || { echo "FAIL: the commit sha was not printed" >&2; exit 1; }
if grep -q 'POST .*git/refs$' "${MOCK_CURL_LOG}"; then
  echo "FAIL: an existing branch must not be created again" >&2
  exit 1
fi
grep -q "expectedHeadOid:\\\\\"${MOCK_BASE_SHA}" "${MOCK_GRAPHQL_BODY}" \
  || { echo "FAIL: the commit does not expect the branch head:" >&2; cat "${MOCK_GRAPHQL_BODY}" >&2; exit 1; }
echo "PASS api-commit.sh commits on an existing branch"

# 2. Missing branch without --create-branch: a clear error, no curl noise.
: > "${MOCK_CURL_LOG}"
: > "${MOCK_REFS}"
stage_change
if (cd "${ROOT}/repo" && bash "${APICOMMIT}" o/r gone -m msg) >"${ROOT}/out.txt" 2>"${ROOT}/err.txt"; then
  echo "FAIL: a missing branch must fail without --create-branch" >&2
  exit 1
fi
grep -q "ERROR: branch gone not found on o/r" "${ROOT}/err.txt" \
  || { echo "FAIL: missing the not-found error:" >&2; cat "${ROOT}/err.txt" >&2; exit 1; }
if grep -q "curl: (22)" "${ROOT}/err.txt"; then
  echo "FAIL: the expected 404 probe leaked curl's error:" >&2
  cat "${ROOT}/err.txt" >&2
  exit 1
fi
echo "PASS api-commit.sh reports a missing branch without curl noise"

# 3. Missing branch with --create-branch: created from the default branch head.
: > "${MOCK_CURL_LOG}"
: > "${MOCK_REFS}"
stage_change
OUT="$(cd "${ROOT}/repo" && bash "${APICOMMIT}" o/r b -m msg --create-branch 2>"${ROOT}/err.txt")"
grep -q "Created branch b from main" "${ROOT}/err.txt" \
  || { echo "FAIL: the branch creation was not reported:" >&2; cat "${ROOT}/err.txt" >&2; exit 1; }
grep -q '^b '"${MOCK_BASE_SHA}"'$' "${MOCK_REFS}" \
  || { echo "FAIL: the ref was not created from the default branch head:" >&2; cat "${MOCK_REFS}" >&2; exit 1; }
grep -q "expectedHeadOid:\\\\\"${MOCK_BASE_SHA}" "${MOCK_GRAPHQL_BODY}" \
  || { echo "FAIL: the commit does not expect the created head:" >&2; cat "${MOCK_GRAPHQL_BODY}" >&2; exit 1; }
grep -q 'newsha0000' <<<"${OUT}" || { echo "FAIL: the commit sha was not printed" >&2; exit 1; }
echo "PASS api-commit.sh --create-branch creates the branch from the default branch"

# 4. A concurrent creator wins the race: the ref exists after the rejected POST.
: > "${MOCK_CURL_LOG}"
: > "${MOCK_REFS}"
stage_change
OUT="$(cd "${ROOT}/repo" && MOCK_CREATE_REF=race bash "${APICOMMIT}" o/r b -m msg --create-branch 2>"${ROOT}/err.txt")"
grep -q "Branch b already existed; committing on it" "${ROOT}/err.txt" \
  || { echo "FAIL: the lost race was not adopted:" >&2; cat "${ROOT}/err.txt" >&2; exit 1; }
grep -q "expectedHeadOid:\\\\\"${MOCK_RACE_SHA}" "${MOCK_GRAPHQL_BODY}" \
  || { echo "FAIL: the commit does not expect the concurrent head:" >&2; cat "${MOCK_GRAPHQL_BODY}" >&2; exit 1; }
echo "PASS api-commit.sh adopts a branch created concurrently"

# 5. Creation genuinely fails: report it instead of dying on curl's exit code.
: > "${MOCK_CURL_LOG}"
: > "${MOCK_REFS}"
stage_change
if (cd "${ROOT}/repo" && MOCK_CREATE_REF=fail bash "${APICOMMIT}" o/r b -m msg --create-branch) >"${ROOT}/out.txt" 2>"${ROOT}/err.txt"; then
  echo "FAIL: a failed branch creation must fail the commit" >&2
  exit 1
fi
grep -q "ERROR: could not create branch b on o/r from main" "${ROOT}/err.txt" \
  || { echo "FAIL: missing the creation error:" >&2; cat "${ROOT}/err.txt" >&2; exit 1; }
echo "PASS api-commit.sh reports a failed branch creation"
