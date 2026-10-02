// Shape check for the repository-level opencode.json (issue #11).
//
// Deliberately *not* a policy test: the concrete allow/deny list is a human
// decision that changes as the repo grows, so this file only asserts that the
// config still is valid JSON and still conforms to the shape declared by
// $schema (https://opencode.ai/config.json). Pinning individual rules here
// would only produce merge conflicts and false failures.
//
// The policy itself is documented in AGENTS.md ("opencode の権限ポリシー").
// Run: node test/opencode-config.js
"use strict"

const assert = require("node:assert")
const fs = require("node:fs")
const path = require("node:path")

const configPath = path.join(__dirname, "..", "opencode.json")
assert.ok(fs.existsSync(configPath), "opencode.json is missing from the repository root")

const config = JSON.parse(fs.readFileSync(configPath, "utf8"))

// Keys the schema accepts inside `permission`, and the actions a rule may
// resolve to. Anything else is a typo that opencode would silently ignore.
const PERMISSION_KEYS = new Set([
  "read",
  "edit",
  "glob",
  "grep",
  "bash",
  "task",
  "skill",
  "lsp",
  "question",
  "webfetch",
  "websearch",
  "external_directory",
  "doom_loop",
])
const ACTIONS = new Set(["allow", "ask", "deny"])

assert.strictEqual(config.$schema, "https://opencode.ai/config.json", "$schema must point at the opencode schema")

function checkRules(where, rules) {
  assert.strictEqual(typeof rules, "object", `${where} must be an object`)
  assert.ok(rules !== null && !Array.isArray(rules), `${where} must not be an array`)
  for (const [pattern, action] of Object.entries(rules)) {
    assert.ok(pattern.length > 0, `${where} has an empty pattern`)
    assert.ok(ACTIONS.has(action), `${where}["${pattern}"] must be one of ${[...ACTIONS].join("/")} (got ${JSON.stringify(action)})`)
  }
}

const permission = config.permission
assert.ok(permission !== undefined, "opencode.json must declare a permission block")
assert.strictEqual(typeof permission, "object", "permission must be an object or a string")

if (typeof permission === "object") {
  for (const [tool, rules] of Object.entries(permission)) {
    assert.ok(PERMISSION_KEYS.has(tool), `permission has an unknown key: ${tool}`)
    // A tool maps either to a single action string or to pattern -> action.
    if (typeof rules === "string") {
      assert.ok(ACTIONS.has(rules), `permission.${tool} must be one of ${[...ACTIONS].join("/")} (got ${JSON.stringify(rules)})`)
    } else {
      checkRules(`permission.${tool}`, rules)
    }
  }
}

console.log("opencode.json matches the opencode config shape")