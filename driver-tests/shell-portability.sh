#!/usr/bin/env bash
# Shell-portability guidance must be present and environment-aware (#369).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"

# 1. The plugin injects a shell-portability rule derived from the actual
#    platform (process.platform), not a hard-coded "Windows/PowerShell".
grep -q "process.platform" "${ROOT}/plugins/gh-app-token.ts" || {
  echo "FAIL: plugin does not derive the shell rule from process.platform" >&2
  exit 1
}
grep -q "head.*tail.*grep" "${ROOT}/plugins/gh-app-token.ts" || {
  echo "FAIL: plugin does not mention head/tail/grep" >&2
  exit 1
}

# 2. The global AGENTS.md template carries the same portability guidance and
#    tells the model to first identify its environment.
grep -q "シェルの移植性" "${ROOT}/opencode/AGENTS.md" || {
  echo "FAIL: opencode/AGENTS.md has no shell-portability section" >&2
  exit 1
}
grep -q "まず自分がどの OS" "${ROOT}/opencode/AGENTS.md" || {
  echo "FAIL: opencode/AGENTS.md does not tell the model to identify its environment first" >&2
  exit 1
}

