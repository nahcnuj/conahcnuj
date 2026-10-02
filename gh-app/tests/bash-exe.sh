#!/usr/bin/env bash
# bash-exe.sh: the BASH_EXE default must be Git for Windows under MSYS/MinGW
# (a plain `bash` can be WSL there) and a real system bash everywhere else.
# Usage: bash bash-exe.sh <staged gh-app dir>
set -euo pipefail

STAGE="${1:?staged gh-app dir required}"

# shellcheck source=gh-app/bash-exe.sh
. "${STAGE}/bash-exe.sh"

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT

# Fake uname so both platform branches can be asserted from any host.
fake_uname() {
  mkdir -p "${ROOT}/bin"
  printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "${1}" > "${ROOT}/bin/uname"
  chmod +x "${ROOT}/bin/uname"
}

for os in MINGW64_NT-10.0 MSYS_NT-10.0 CYGWIN_NT-10.0; do
  fake_uname "${os}"
  out="$(PATH="${ROOT}/bin:${PATH}" default_bash_exe)"
  if [[ "${out}" != "C:/Program Files/Git/bin/bash.exe" ]]; then
    echo "FAIL: ${os} must default to Git for Windows, got '${out}'" >&2
    exit 1
  fi
done
echo "PASS default_bash_exe -> Git for Windows under MSYS/MinGW/Cygwin"

for os in Linux Darwin; do
  fake_uname "${os}"
  out="$(PATH="${ROOT}/bin:${PATH}" default_bash_exe)"
  if [[ -x /bin/bash ]]; then
    expected="/bin/bash"
  else
    expected="bash"
  fi
  if [[ "${out}" != "${expected}" ]]; then
    echo "FAIL: ${os} must default to '${expected}', got '${out}'" >&2
    exit 1
  fi
done
echo "PASS default_bash_exe -> system bash on Linux/macOS"

# Placeholder detection: an unconfigured app.env (example only) must fall back
# to the platform default instead of becoming a credential helper command.
bash_exe_is_placeholder "" || { echo "FAIL: empty value must count as placeholder" >&2; exit 1; }
bash_exe_is_placeholder "<your-bash-exe>" || { echo "FAIL: example placeholder must count as placeholder" >&2; exit 1; }
if bash_exe_is_placeholder "/bin/bash"; then
  echo "FAIL: a real path must not count as placeholder" >&2
  exit 1
fi
echo "PASS bash_exe_is_placeholder detects the unconfigured case"
