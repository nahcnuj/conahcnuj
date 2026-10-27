#!/usr/bin/env bash
# api-commit.sh must survive an in-progress merge when it syncs the local
# checkout after creating the verified commit. The driver tells the coding
# agent to "fix whatever breaks them" when a PR's branch conflicts; the agent
# resolves the conflict in the work tree and stages it, leaving MERGE_HEAD
# behind. The commit succeeds on GitHub, but the trailing `git pull` used to
# refuse ("You have not concluded your merge (MERGE_HEAD exists)"), so a
# successful verified commit was reported as a failure and the driver died
# with exit 128 (issue #250). This runs api-commit.sh end to end against a
# local bare remote with a stubbed token and curl; no network, no secrets.
# Usage: bash api-commit-merge.sh <staged gh-app dir>
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

# Stub curl: answer the refs read with the fixture head and the GraphQL commit
# with the fixture's commit sha (both are real commits in the bare remote).
cat > "${PRIV}/bin/curl" <<'EOF'
#!/usr/bin/env bash
args="$*"
if [[ "$args" == *"/graphql"* ]]; then
  printf '{"data":{"createCommitOnBranch":{"commit":{"oid":"%s"}}}}' "${FAKE_NEW_SHA}"
else
  printf '{"object":{"sha":"%s"}}' "${FAKE_HEAD_SHA}"
fi
EOF
chmod +x "${PRIV}/bin/curl"
export PATH="${PRIV}/bin:${PATH}"

# Fixture: a bare remote, main advanced past feature with a conflicting edit,
# and a work tree sitting in the resolved-but-uncommitted merge state.
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
git -C "${W}" checkout -q -b feature
printf 'feature\n' > "${W}/f.txt"
git -C "${W}" commit -qam feature
git -C "${W}" push -q -u origin feature
FEATURE_HEAD="$(git -C "${W}" rev-parse HEAD)"
git -C "${W}" checkout -q main
printf 'main-change\n' > "${W}/f.txt"
git -C "${W}" commit -qam main-change
git -C "${W}" push -q origin main
git -C "${W}" checkout -q feature
git -C "${W}" merge origin/main >/dev/null 2>&1 || true
printf 'resolved\n' > "${W}/f.txt"
git -C "${W}" add -A
if ! git -C "${W}" rev-parse --verify -q MERGE_HEAD >/dev/null; then
  echo "FAIL: fixture did not leave a merge in progress" >&2
  exit 1
fi
# The verify commit GitHub would create: the resolved tree on top of the branch
# head, already pushed to the remote (so the local sync has somewhere to land).
RESOLVED_TREE="$(git -C "${W}" write-tree)"
NEW_SHA="$(git -C "${W}" commit-tree "${RESOLVED_TREE}" -p "${FEATURE_HEAD}" -m resolved)"
git -C "${W}" push -q origin "${NEW_SHA}:refs/heads/feature"

OUT="${ROOT}/out.txt"
RC=0
(
  cd "${W}"
  FAKE_HEAD_SHA="${FEATURE_HEAD}" FAKE_NEW_SHA="${NEW_SHA}" \
    bash "${PRIV}/gh-app/api-commit.sh" o/r feature -m "resolve branch conflict"
) > "${OUT}" 2>&1 || RC=$?

echo "----- api-commit.sh merge run output -----"
cat "${OUT}"
echo "------------------------------------------"

[[ ${RC} -eq 0 ]] || { echo "FAIL: api-commit.sh exited ${RC} (expected 0) under MERGE_HEAD"; exit 1; }
grep -q "unfinished merge" "${OUT}" && { echo "FAIL: the sync still hit the unfinished-merge refusal"; exit 1; }

# The sync must have landed on the commit that was created.
[[ "$(git -C "${W}" rev-parse HEAD)" == "${NEW_SHA}" ]] || { echo "FAIL: local branch was not synced to the created commit"; exit 1; }
if git -C "${W}" rev-parse --verify -q MERGE_HEAD >/dev/null; then
  echo "FAIL: MERGE_HEAD was left behind"; exit 1
fi
[[ "$(cat "${W}/f.txt")" == "resolved" ]] || { echo "FAIL: the resolved content was not preserved"; exit 1; }

echo "PASS api-commit.sh commits through an in-progress merge (issue #250)"
