#!/usr/bin/env bash
# install.sh deployment test (offline, no secrets, no network).
#
# Installs into a temp dir (never touching $HOME) and asserts the deployed
# payload mirrors the sources byte for byte: both gh-app trees, the plugin,
# lib/, the driver binary; app.env created from app.env.example; an existing
# app.env preserved; leftovers of older installs dropped; no test code and no
# typecheck tooling deployed. The driver binary is also started once to prove
# it finds its sibling gh-app/lib trees.
#
# Usage: bash test/install-test.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Stage a source tree without the untracked app.env (it holds real secrets and
# would otherwise be copied over the deployed one), so the test asserts the
# fresh-clone path on every host.
SRC="${TMP}/src"
mkdir -p "${SRC}/gh-app" "${SRC}/plugins" "${SRC}/bin" "${SRC}/lib"
cp "${REPO}/install.sh" "${SRC}/install.sh"
cp "${REPO}"/gh-app/*.sh "${SRC}/gh-app/"
cp "${REPO}/gh-app/app.env.example" "${SRC}/gh-app/"
cp "${REPO}/plugins/gh-app-token.ts" "${SRC}/plugins/"
cp "${REPO}/bin/conahcnuj.sh" "${SRC}/bin/"
cp "${REPO}"/lib/*.sh "${SRC}/lib/"

DEST="${TMP}/opencode"
BIN="${TMP}/bin"
BIN_SIDE="$(dirname "${BIN}")"

# Leftovers of an older install (test code was shipped before) must be dropped.
mkdir -p "${DEST}/gh-app/tests"
printf 'legacy\n' > "${DEST}/gh-app/mock-test.sh"
printf 'legacy\n' > "${DEST}/gh-app/tests/get-token-cache.sh"

install() {
  bash "${SRC}/install.sh" --destination "${DEST}" --install-path "${BIN}" >/dev/null
}

expect_same() {
  [[ -f "${1}" ]] || fail "missing deployment: ${1}"
  cmp -s "${2}" "${1}" || fail "content mismatch: ${1} (source ${2})"
}

install

# 1) Plugin-side payload (config destination).
for name in get-token.sh git-credential-helper.sh setup-git.sh api-commit.sh \
            bot-user-id.sh bash-exe.sh app.env.example; do
  expect_same "${DEST}/gh-app/${name}" "${SRC}/gh-app/${name}"
done
for name in get-token.sh git-credential-helper.sh setup-git.sh api-commit.sh \
            bot-user-id.sh bash-exe.sh; do
  [[ -x "${DEST}/gh-app/${name}" ]] || fail "not executable: ${DEST}/gh-app/${name}"
done
expect_same "${DEST}/plugins/gh-app-token.ts" "${SRC}/plugins/gh-app-token.ts"

# 2) Binary-side payload: the driver resolves gh-app/lib relative to itself.
for name in get-token.sh git-credential-helper.sh setup-git.sh api-commit.sh \
            bot-user-id.sh bash-exe.sh app.env.example; do
  expect_same "${BIN_SIDE}/gh-app/${name}" "${SRC}/gh-app/${name}"
done
for name in gh-api.sh opencode.sh rate-limit.sh; do
  expect_same "${BIN_SIDE}/lib/${name}" "${SRC}/lib/${name}"
done
expect_same "${BIN}/conahcnuj" "${SRC}/bin/conahcnuj.sh"
[[ -x "${BIN}/conahcnuj" ]] || fail "driver binary is not executable: ${BIN}/conahcnuj"

# 3) app.env is created from the example (fresh clone).
expect_same "${DEST}/gh-app/app.env" "${SRC}/gh-app/app.env.example"
[[ -f "${BIN_SIDE}/gh-app/app.env" ]] || fail "app.env was not created beside the driver"

# 4) Nothing else: no test code, no typecheck tooling. The plugins dir may
#    hold other user plugins, so only assert our payload is there.
[[ ! -e "${DEST}/gh-app/tests" ]] || fail "test code must not be deployed"
[[ ! -e "${DEST}/gh-app/mock-test.sh" ]] || fail "legacy mock-test.sh must be removed"
deployed_plugins="$(cd "${DEST}/plugins" && ls -A)"
case " ${deployed_plugins} " in
  *" gh-app-token.ts "*) ;;
  *) fail "plugin was not deployed, got: ${deployed_plugins}" ;;
esac

# 5) The deployed driver runs and finds its sibling gh-app/lib trees.
if out="$(bash "${BIN}/conahcnuj" 2>&1)"; then
  fail "conahcnuj without arguments must exit non-zero, got: ${out}"
fi
[[ "${out}" == *"Usage:"* ]] || fail "conahcnuj without arguments must print usage, got: ${out}"

# 6) Re-running keeps local configuration: an existing app.env wins over the
#    example, and the payload is refreshed.
printf 'APP_ID="keep-me"\n' > "${DEST}/gh-app/app.env"
install
grep -q 'APP_ID="keep-me"' "${DEST}/gh-app/app.env" || fail "existing app.env must be preserved"
expect_same "${DEST}/gh-app/setup-git.sh" "${SRC}/gh-app/setup-git.sh"

# 7) Unknown options fail loudly instead of installing somewhere unexpected.
if bash "${SRC}/install.sh" --bogus >/dev/null 2>&1; then
  fail "unknown option must exit non-zero"
fi

echo "PASS install.sh deployment test"
