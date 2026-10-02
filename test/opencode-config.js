// Validates the repository-level opencode.json permission policy (issue #11).
// Plain Node, no deps. Run through test/opencode-config.sh.
"use strict"

const assert = require("node:assert")
const fs = require("node:fs")
const path = require("node:path")

const configPath = path.join(__dirname, "..", "opencode.json")
assert.ok(fs.existsSync(configPath), "opencode.json is missing from the repository root")

const config = JSON.parse(fs.readFileSync(configPath, "utf8"))
const bash = (config.permission && config.permission.bash) || {}

assert.strictEqual(
  config.$schema,
  "https://opencode.ai/config.json",
  "opencode.json must carry the $schema hint"
)
// A blanket `ask` would make every unattended driver run fail: `ask` is an
// automatic rejection in `opencode run`, so models would stop at the first
// permission request and hand off with "no complete work".
assert.strictEqual(bash["*"], "allow", "bash catch-all must be allow, not ask")
assert.strictEqual(bash["* --force*"], "ask", "destructive --force commands stay behind approval")
for (const pattern of [
  "git push --force origin ma*",
  "git push -f origin ma*",
  "*gh-app/app.env*",
  "git config --global --set*",
  "git config --global --add*",
  "git config --global --unset*",
  "git config --global --remove-section*",
]) {
  assert.strictEqual(bash[pattern], "deny", `bash rule must deny ${pattern}`)
}
// Both default to `ask`, which would block agents that need ~/.config or that
// retry an identical call once.
assert.strictEqual(
  config.permission.external_directory["*"],
  "allow",
  "external_directory must stay allowed (it defaults to ask)"
)
assert.strictEqual(
  config.permission.doom_loop,
  "allow",
  "doom_loop must stay allowed (it defaults to ask)"
)

console.log("opencode.json permission policy OK")