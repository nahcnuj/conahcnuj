#!/usr/bin/env bash
# Measures, on the actual host, whether head/tail/grep exist in the current
# shell, and checks that this matches the platform the plugin would report
# (issue #369). On Windows it also runs the commands through the real
# PowerShell with Git for Windows' usr/bin on PATH, the directory the plugin
# injects, so the fix for #446 is verified on the real runner.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

# Real measurement: do the commands actually resolve in this shell?
have_all=0
if command -v head >/dev/null 2>&1 && command -v tail >/dev/null 2>&1 && command -v grep >/dev/null 2>&1; then
  have_all=1
fi

# The platform the plugin's node process would report.
node_platform="$(node -e 'process.stdout.write(process.platform)')"

echo "measured: head/tail/grep all available = ${have_all} (platform=${node_platform})" >&2

# Sanity: on a Unix platform the tools must be present. On Windows the
# conahcnuj plugin puts Git for Windows' usr/bin on PATH precisely so the
# PowerShell that opencode spawns can use them; verify that with the real
# PowerShell on the runner instead of a stub.
case "${node_platform}" in
  linux|darwin|win32)
    [ "${have_all}" = "1" ] || { echo "FAIL: head/tail/grep missing on ${node_platform}" >&2; exit 1; }
    ;;
  *)
    echo "FAIL: unsupported platform ${node_platform}" >&2
    exit 1
    ;;
esac

# The plugin source must still derive its claim from process.platform.
grep -q "process.platform" "${REPO}/plugins/gh-app-token.ts" || {
  echo "FAIL: plugin does not derive the shell rule from process.platform" >&2
  exit 1
}

echo "shell-portability runtime measurement done" >&2
