#!/usr/bin/env bash
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
args="$*"
if [[ "$args" == *"/graphql"* ]]; then
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --data-binary) cp "${2#@}" "${CAPTURE}"; shift 2 ;;
      *) shift ;;
    esac
  done
  printf '{"data":{"createCommitOnBranch":{"commit":{"oid":"%s"}}}}' "${FAKE_NEW_SHA}"
elif [[ "$args" == *"/git/trees/"* ]]; then
  printf '{\n  "sha": "base-tree",\n  "tree": [\n    {\n      "path": "f.txt",\n      "type": "blob"\n    },\n    {\n      "path": "added.txt",\n      "type": "blob"\n    }\n  ],\n  "truncated": false\n}'
else
  printf '{\n  "object": {\n    "sha": "%s"\n  }\n}' "${FAKE_HEAD_SHA}"
fi
EOF
chmod +x "${PRIV}/bin/curl"
export PATH="${PRIV}/bin:${PATH}"

REMOTE="${ROOT}/remote.git"
git init -q --bare "${REMOTE}"
W="${ROOT}/W"
git init -q "${W}"
git -C "${W}" config user.email "mock@test"
git -C "${W}" config user.name "mock"
git -C "${W}" config commit.gpgsign false
git -C "${W}" remote add origin "${REMOTE}"
printf 'base\n' > "${W}/f.txt"
printf 'gone\n' > "${W}/gone.txt"
git -C "${W}" add -A
git -C "${W}" commit -qm init
git -C "${W}" branch -M main
git -C "${W}" push -q -u origin main
git -C "${W}" checkout -q -b feature
printf 'feature\n' >> "${W}/f.txt"
git -C "${W}" commit -qam feature
git -C "${W}" push -q -u origin feature
FEATURE_HEAD="$(git -C "${W}" rev-parse HEAD)"

rm "${W}/gone.txt"
printf 'new\n' > "${W}/added.txt"
git -C "${W}" add -A

NEW_TREE="$(git -C "${W}" write-tree)"
NEW_SHA="$(git -C "${W}" commit-tree "${NEW_TREE}" -p "${FEATURE_HEAD}" -m "remove gone, add added")"
git -C "${W}" push -q origin "${NEW_SHA}:refs/heads/feature"

CAPTURE="${ROOT}/query.json"
OUT="${ROOT}/out.txt"
RC=0
(
  cd "${W}"
  CAPTURE="${CAPTURE}" FAKE_HEAD_SHA="${FEATURE_HEAD}" FAKE_NEW_SHA="${NEW_SHA}" \
    bash "${PRIV}/gh-app/api-commit.sh" o/r feature -m "remove gone, add added"
) > "${OUT}" 2>&1 || RC=$?


[[ ${RC} -eq 0 ]] || { echo "FAIL: api-commit.sh exited ${RC} (expected 0) for an already-absent deletion"; exit 1; }
if grep -qE 'WARNING|skipping deletion' "${OUT}"; then
  echo "FAIL: an already-absent deletion was reported (silence is golden)"; exit 1
fi
if grep -q 'gone\.txt' "${CAPTURE}"; then
  echo "FAIL: the already-absent deletion was still sent to createCommitOnBranch"; exit 1
fi
grep -q 'added\.txt' "${CAPTURE}" || { echo "FAIL: the addition was dropped along with the deletion"; exit 1; }

echo "PASS api-commit.sh skips a deletion already absent from the remote head"
