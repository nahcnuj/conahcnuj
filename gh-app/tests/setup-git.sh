#!/usr/bin/env bash
# setup-git.sh: the credential helper must run through the configured bash,
# and fall back to the platform default while app.env still carries the
# app.env.example placeholder (a fresh clone has no app.env at all).
# Usage: bash setup-git.sh <staged gh-app dir>
set -euo pipefail

STAGE="${1:?staged gh-app dir required}"

# The staged gh-app dir is shared with the other tests, so work on a copy.
WORK="$(mktemp -d)"
REPO="$(mktemp -d)"
trap 'rm -rf "${WORK}" "${REPO}"' EXIT
mkdir -p "${WORK}/gh-app"
cp "${STAGE}"/*.sh "${WORK}/gh-app/"

# bot-user-id.sh would reach the public API; the bot identity is not under test.
cat > "${WORK}/gh-app/bot-user-id.sh" <<'EOF'
#!/usr/bin/env bash
printf '331119074\n'
EOF

# shellcheck source=gh-app/bash-exe.sh
. "${WORK}/gh-app/bash-exe.sh"

git -C "${REPO}" init -q 2>/dev/null

helper_of() {
  (cd "${REPO}" && bash "${WORK}/gh-app/setup-git.sh" >/dev/null) || return 1
  # credential.helper is multi-valued: --get (all levels) can return a global
  # value, so read the repo-local config explicitly.
  git -C "${REPO}" config --local --get credential.helper
}

# Placeholder (unconfigured): the platform default must be used.
cat > "${WORK}/gh-app/app.env" <<'EOF'
APP_ID=00000
INSTALLATION_ID=00000
APP_SLUG=conahcnuj
PRIVATE_KEY_PATH=/tmp/nonexistent.pem
BASH_EXE="<your-bash-exe>"
EOF
out="$(helper_of)"
expected="!\"$(default_bash_exe)\" \"${WORK}/gh-app/git-credential-helper.sh\""
if [[ "${out}" != "${expected}" ]]; then
  echo "FAIL: placeholder BASH_EXE should use the platform default" >&2
  echo "  expected: ${expected}" >&2
  echo "  got:      ${out}" >&2
  exit 1
fi
name="$(git -C "${REPO}" config --local --get user.name)"
if [[ "${name}" != "conahcnuj[bot]" ]]; then
  echo "FAIL: bot identity expected, got '${name}'" >&2
  exit 1
fi
echo "PASS setup-git.sh falls back to the platform default bash (repo-local config)"

# Configured value: app.env wins over the default.
cat > "${WORK}/gh-app/app.env" <<'EOF'
APP_ID=00000
INSTALLATION_ID=00000
APP_SLUG=conahcnuj
PRIVATE_KEY_PATH=/tmp/nonexistent.pem
BASH_EXE=/custom/bash
EOF
out="$(helper_of)"
# MSYS rewrites POSIX-looking arguments before handing them to git.exe, so
# /custom/bash is stored as C:/Program Files/Git/custom/bash under Git Bash.
# Assert the configured bash (not the default) is what got stored, tolerating
# that rewrite, so the same test holds on a Linux host.
bash_token="${out#*\"}"
bash_token="${bash_token%%\"*}"
case "${bash_token}" in
  /custom/bash | */custom/bash) ;;
  *)
    echo "FAIL: configured BASH_EXE expected, got bash token '${bash_token}' in '${out}'" >&2
    exit 1
    ;;
esac
[[ "${out}" == *"${WORK}/gh-app/git-credential-helper.sh"* ]] ||
  { echo "FAIL: helper script path missing from '${out}'" >&2; exit 1; }
[[ "${bash_token}" != "$(default_bash_exe)" ]] ||
  { echo "FAIL: configured BASH_EXE must win over the platform default" >&2; exit 1; }
echo "PASS setup-git.sh honours a configured BASH_EXE"
