#!/usr/bin/env bash
# api-commit.sh must not discard local commits when it creates a remote branch
# that does not exist yet. A branch can be missing on the remote while the local
# branch already carries commits (a resumed/renamed branch, or one the agent
# created locally); those commits are reachable on the remote even without the
# branch ref. The pre-fix code always based the new branch on the default branch
# tip and then force-synced the local checkout to it, so `git reset --hard`
# silently dropped the local commits (the run then looked like it lost the
# earlier implementation). The branch must instead start from the local HEAD
# when the remote already has that commit.
# This runs api-commit.sh end to end against a local bare remote with a stubbed
# token and curl; no network, no secrets.
# Usage: bash api-commit-creates-branch-divergent.sh <staged gh-app dir>
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

# Stub curl: the branch ref read returns nothing (branch missing), the repo root
# answers the default branch, branches/main answers the default tip, the
# git/refs POST accepts only the local HEAD base (proving it was preferred over
# the default tip), and the GraphQL commit answers the fixture sha.
cat > "${PRIV}/bin/curl" <<'EOF'
#!/usr/bin/env bash
args="$*"
if [[ "$args" == *"/graphql"* ]]; then
  printf '{"data":{"createCommitOnBranch":{"commit":{"oid":"%s"}}}}' "${FAKE_NEW_SHA}"
elif [[ "$args" == *"/git/refs/heads/feature"* ]]; then
  :
elif [[ "$args" == *"/branches/main"* ]]; then
  printf '{"commit":{"sha":"%s"}}' "${DEFAULT_TIP}"
elif [[ "$args" == *"/git/refs"* ]]; then
  if [[ "$args" == *"${LOCAL_COMMIT}"* ]]; then
    printf '{"ref":"refs/heads/feature","object":{"sha":"%s"}}' "${LOCAL_COMMIT}"
  else
    exit 22
  fi
else
  printf '{"default_branch":"main"}'
fi
EOF
chmod +x "${PRIV}/bin/curl"
export PATH="${PRIV}/bin:${PATH}"

# Fixture: a bare remote with main. The local feature branch has one commit of
# its own on top of main; that commit is pushed to a different ref (wip) so it
# is reachable on the remote, but refs/heads/feature does not exist.
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
DEFAULT_TIP="$(git -C "${W}" rev-parse HEAD)"
git -C "${W}" switch -q -c feature
printf 'local work\n' > "${W}/local.txt"
git -C "${W}" add -A
git -C "${W}" commit -qm "local work"
LOCAL_COMMIT="$(git -C "${W}" rev-parse HEAD)"
git -C "${W}" push -q origin "HEAD:refs/heads/wip"

# Stage a further change for api-commit to commit. The verified commit GitHub
# would create keeps the local commit as its parent, and is already pushed to
# the remote branch so the local sync has somewhere to land.
printf 'feature\n' >> "${W}/f.txt"
git -C "${W}" add -A
NEW_TREE="$(git -C "${W}" write-tree)"
NEW_SHA="$(git -C "${W}" commit-tree "${NEW_TREE}" -p "${LOCAL_COMMIT}" -m "first feature commit")"
git -C "${W}" push -q origin "${NEW_SHA}:refs/heads/feature"

OUT="${ROOT}/out.txt"
RC=0
(
  cd "${W}"
  DEFAULT_TIP="${DEFAULT_TIP}" LOCAL_COMMIT="${LOCAL_COMMIT}" FAKE_NEW_SHA="${NEW_SHA}" \
    bash "${PRIV}/gh-app/api-commit.sh" o/r feature -m "first feature commit"
) > "${OUT}" 2>&1 || RC=$?

echo "----- api-commit.sh divergent branch-creation run output -----"
cat "${OUT}"
echo "-------------------------------------------------------------"

[[ ${RC} -eq 0 ]] || { echo "FAIL: api-commit.sh exited ${RC} (expected 0) for a missing branch with local commits"; exit 1; }
grep -q "Created branch feature from local HEAD" "${OUT}" || { echo "FAIL: the new branch was not based on the local HEAD"; exit 1; }

# The sync must have landed on the created commit with the local commit kept as
# an ancestor, not discarded.
[[ "$(git -C "${W}" rev-parse HEAD)" == "${NEW_SHA}" ]] || { echo "FAIL: local branch was not synced to the created commit"; exit 1; }
git -C "${W}" merge-base --is-ancestor "${LOCAL_COMMIT}" HEAD || { echo "FAIL: the local commit was discarded by the sync"; exit 1; }
[[ "$(cat "${W}/local.txt")" == "local work" ]] || { echo "FAIL: the local commit content was lost"; exit 1; }
[[ "$(cat "${W}/f.txt")" == $'base\nfeature' ]] || { echo "FAIL: the committed content was not preserved"; exit 1; }

echo "PASS api-commit.sh keeps local commits when creating a missing branch"
