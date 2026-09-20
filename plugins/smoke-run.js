// Plugin runtime smoke test runner (plain Node, no deps).
// Usage: node smoke-run.js <compiled gh-app-token.js> <expected bot user id>
//
// Loads the compiled plugin with a fake gh-app dir (fake app.env), then
// asserts the shell.env contract (GIT_CONFIG identity + alias.vc) and the
// tool.execute.before redirect (git commit blocked, others pass through).
"use strict"

const assert = require("node:assert")

async function main() {
  const [compiledPath, expectedId] = process.argv.slice(2)
  assert(compiledPath && expectedId, "usage: node smoke-run.js <compiled js> <bot id>")
  const { GhAppTokenPlugin } = require(compiledPath)
  const plugin = await GhAppTokenPlugin({})
  assert(plugin["shell.env"], "missing shell.env hook")
  assert(plugin["tool.execute.before"], "missing tool.execute.before hook")

  const output = { args: {}, env: {} }
  await plugin["shell.env"]({}, output)
  const env = output.env
  const pairs = {}
  const count = Number(env.GIT_CONFIG_COUNT)
  assert(Number.isInteger(count) && count > 0, "bad GIT_CONFIG_COUNT")
  for (let i = 0; i < count; i++) {
    pairs[env[`GIT_CONFIG_KEY_${i}`]] = env[`GIT_CONFIG_VALUE_${i}`]
  }
  assert(
    typeof pairs["user.email"] === "string" && pairs["user.email"].startsWith(`${expectedId}+`),
    `user.email should start with ${expectedId}+, got: ${pairs["user.email"]}`
  )
  assert(
    typeof pairs["alias.vc"] === "string" && pairs["alias.vc"].includes("api-commit.sh"),
    `alias.vc should point at api-commit.sh, got: ${pairs["alias.vc"]}`
  )

  const before = plugin["tool.execute.before"]
  let threw = false
  try {
    await before({ tool: "bash" }, { args: { command: 'git commit -m "x"' }, env: {} })
  } catch (err) {
    threw = /git vc/.test(String((err && err.message) || err))
  }
  assert(threw, "git commit was not redirected to git vc")
  // Must not interfere with anything else.
  await before({ tool: "bash" }, { args: { command: "git status" }, env: {} })
  await before({ tool: "read" }, { args: { filePath: "x" }, env: {} })

  console.log("PLUGIN SMOKE OK")
}

main().catch((err) => {
  console.error(`SMOKE FAIL: ${(err && err.message) || err}`)
  process.exit(1)
})
