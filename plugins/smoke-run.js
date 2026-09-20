// Plugin runtime smoke test runner (plain Node, no deps).
// Usage: bash plugins/smoke.sh (which stages ./.smoke/ first)
//   or: node smoke-run.js <expected app slug>
//
// Loads the compiled plugin with a fake gh-app dir (fake app.env; the bot
// ID itself is auto-resolved from the public API), then asserts the
// shell.env contract (GIT_CONFIG identity + alias.vc) and the
// tool.execute.before redirect (git commit blocked, others pass through).
// The require target is a fixed literal path on purpose: requiring an
// argv-provided path trips CodeQL path-injection (high). smoke.sh stages
// the compiled artifact plus a fake gh-app dir at ./.smoke/ (same relative
// layout, so __dirname-based resolution finds the fake app.env).
"use strict"

const assert = require("node:assert")

async function main() {
  const [expectedSlug] = process.argv.slice(2)
  assert(expectedSlug, "usage: node smoke-run.js <app slug>")
  const { GhAppTokenPlugin } = require("./.smoke/out/gh-app-token.js")
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
    typeof pairs["user.email"] === "string" &&
      new RegExp(`^\\d+\\+${expectedSlug}\\[bot\\]@users\\.noreply\\.github\\.com$`).test(
        pairs["user.email"]
      ),
    `user.email has wrong shape, got: ${pairs["user.email"]}`
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
