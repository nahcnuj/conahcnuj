#!/usr/bin/env bash
# Platform-aware default for BASH_EXE (sourced, never executed).
#
# BASH_EXE tells git which bash runs the App credential helper. Under
# MSYS/MinGW it must be Git for Windows' bash, because a plain `bash` resolves
# to WSL there, where MSYS-style paths (/c/...) and the Windows git do not
# exist. Everywhere else the system bash is correct, so an absolute path is
# used when /bin/bash exists (NixOS and friends resolve `bash` from PATH).

# Print the default bash executable for this host.
default_bash_exe() {
  local os
  os="$(uname -s 2>/dev/null || printf 'unknown')"
  case "${os}" in
    MINGW* | MSYS* | CYGWIN* | Windows_NT)
      printf '%s\n' "C:/Program Files/Git/bin/bash.exe"
      ;;
    *)
      if [[ -x /bin/bash ]]; then
        printf '%s\n' "/bin/bash"
      else
        printf '%s\n' "bash"
      fi
      ;;
  esac
}

# True when a configured BASH_EXE value is still the app.env.example
# placeholder (a fresh clone has no app.env, so the example is used verbatim).
bash_exe_is_placeholder() {
  [[ -z "${1:-}" || "${1}" == "<your-bash-exe>" ]]
}
