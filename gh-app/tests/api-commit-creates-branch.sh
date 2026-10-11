#!/usr/bin/env bash
# api-commit.sh must create a remote branch that does not exist yet, from the
# default branch head, so the ordinary `git switch -c <branch>` then
# `git vc -m "<message>"` workflow needs no --create-branch flag. This runs
# api-commit.sh end to end against a local bare remote with a stubbed token and
# curl; no network, no secrets.
# Usage: bash api-commit-creates-branch.sh <staged gh-app dir>
set -euo pipefail

STAGE="${1:?staged gh-app dir required}"
APICOMMIT_SRC="${STAGE}/api-commit.sh"

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT

# Private copy of api-commit.sh with a stubbed token script and app.env, so the
# shared staged get-token.sh other tests rely on is left untouched.
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

# Stub curl: the branch ref read returns nothing (branch missing), the repo
# root answers the default branch, branches/default answers the base sha, the
# git/refs POST succeeds, and the GraphQL commit answers the fixture sha.
cat > "${PRIV}/bin/curl" <<'EOF'
#!/usr/bin/env bash
args="$*"
if [[ "$args" == *"/graphql"* ]]; then
  printf '{"data":{"createCommitOnBranch":{"commit":{"oid":"%s"}}}}' "${FAKE_NEW_SHA}"
elif [[ "$args" == *"/branches/main"* ]]; then
  printf '{"commit":{"sha":"%s"}}' "${BASE_SHA}"
elif [[ "$args" == *"/git/refs/heads/feature"* ]]; then
  :
elif [[ "$args" == *"/git/refs"* ]]; then
  printf '{"ref":"refs/heads/feature","object":{"sha":"%s"}}' "${BASE_SHA}"
else
  printf '{"default_branch":"main"}'
fi
EOF
chmod +x "${PRIV}/bin/curl"
export PATH="${PRIV}/bin:${PATH}"

# Fixture: a bare remote with only main, and a local work tree on a feature
# branch created with the ordinary `git switch -c` flow (no remote branch).
REMOTE="${ROOT}/remote.git"
git init -q --bare "${REMOTE}"
W="${ROOT}/W"
git init -q "${W}"
git -C "${W}" config user.email "mock@test"
git -C "${W}" config user.name "mock"
git -C "${W}" config commit.gpgsign false
git -C "${W}" remote add origin "${REMOTE}"
printf 'base\n' > "${W}/f.txt"
git -C "${W}" add -A
git -C "${W}" commit -qm init
git -C "${W}" branch -M main
git -C "${W}" push -q -u origin main
BASE_SHA="$(git -C "${W}" rev-parse HEAD)"
git -C "${W}" switch -q -c feature
printf 'feature\n' >> "${W}/f.txt"
git -C "${W}" add -A

# The verified commit GitHub would create: the work-tree tree on top of the
# default branch head, already pushed to the remote (so the local sync has
# somewhere to land).
NEW_TREE="$(git -C "${W}" write-tree)"
NEW_SHA="$(git -C "${W}" commit-tree "${NEW_TREE}" -p "${BASE_SHA}" -m "first feature commit")"
git -C "${W}" push -q origin "${NEW_SHA}:refs/heads/feature"

OUT="${ROOT}/out.txt"
RC=0
(
  cd "${W}"
  BASE_SHA="${BASE_SHA}" FAKE_NEW_SHA="${NEW_SHA}" \
    bash "${PRIV}/gh-app/api-commit.sh" o/r feature -m "first feature commit"
) > "${OUT}" 2>&1 || RC=$?

echo "----- api-commit.sh branch-creation run output -----"
cat "${OUT}"
echo "----------------------------------------------------"

[[ ${RC} -eq 0 ]] || { echo "FAIL: api-commit.sh exited ${RC} (expected 0) for a missing branch"; exit 1; }
grep -q "Created branch feature from main" "${OUT}" || { echo "FAIL: no branch-created message in output"; exit 1; }

# The sync must have landed on the commit that was created.
[[ "$(git -C "${W}" rev-parse HEAD)" == "${NEW_SHA}" ]] || { echo "FAIL: local branch was not synced to the created commit"; exit 1; }
[[ "$(cat "${W}/f.txt")" == $'base\nfeature' ]] || { echo "FAIL: the committed content was not preserved"; exit 1; }

echo "PASS api-commit.sh creates a missing branch from the default branch"