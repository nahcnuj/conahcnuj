#!/usr/bin/env bash
# Validate the repository-level opencode.json (issue #11).
#
# The driver runs `opencode run` non-interactively, where an `ask` rule is an
# automatic rejection, so the permission policy that applies to agents working
# in this repository is version controlled here instead of living only in one
# machine's global config. The assertions live in opencode-config.js:
#
#   - the file parses as JSON and carries the JSON schema hint
#   - ordinary work is allowed (a blanket `ask` would make every unattended
#     driver run fail with "no available model completed the work")
#   - the safety denies survive: app.env (App secrets), force pushes and
#     global git writes
#   - external_directory / doom_loop stay allowed, because they default to
#     `ask` and would otherwise block agents that need ~/.config or retry once
#
# Needs node (any recent version). No secrets, no network.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "${HERE}/../opencode.json" ]]; then
  echo "FAIL: opencode.json is missing from the repository root" >&2
  exit 1
fi

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is required to validate opencode.json" >&2
  exit 1
fi

node "${HERE}/opencode-config.js"