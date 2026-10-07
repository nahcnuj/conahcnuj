#!/usr/bin/env bash
# Unit tests for the opencode plugin: compile the REAL plugins/gh-app-token.ts
# (no copy of it, nothing appended to it - unit-run.js drives the hooks opencode
# calls, so nothing has to be re-exported for the tests) with
# plugins/tsconfig.unit.json into test/.unit/out, then run unit-run.js.
# GH_APP_DIR resolves as test/.unit/gh-app, which unit-run.js stages as its
# fixture (app.env, bot-id.cache, token.cache); global fetch is stubbed there,
# so no network is touched.
# No secrets, no pwsh: the installed-file runtime path is covered separately
# by test/smoke.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
PLUGINS_DIR="${REPO}/plugins"
STAGE="${HERE}/.unit"
# A leftover stage from an earlier run must never mask a failure.
rm -rf "${STAGE}"
trap 'rm -rf "${STAGE}"' EXIT

# NOTE: plain `cd`, not `npm --prefix`: native npm on Windows ignores an
# msys-style absolute prefix (same as the lint-ts job in ci.yml).
(cd "${PLUGINS_DIR}" && npm ci --no-audit --no-fund)

# plugins/tsconfig.unit.json extends the lint config (same strictness, types
# resolve from plugins/node_modules) and only turns on emit into the stage.
"${PLUGINS_DIR}/node_modules/.bin/tsc" -p "${PLUGINS_DIR}/tsconfig.unit.json"

node "${STAGE}/out/lib/gh-app-commit.test.js"
node "${HERE}/unit-run.js"
