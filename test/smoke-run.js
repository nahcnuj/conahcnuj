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
  const [expectedSlug, expectedId] = process.argv.slice(2)
  assert(expectedSlug && expectedId, "usage: node smoke-run.js <app slug> <bot id>")
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
  const emailMatch =
    typeof pairs["user.email"] === "string"
      ? /^(\d+)\+([A-Za-z0-9-]+)\[bot\]@users\.noreply\.github\.com$/.exec(
          pairs["user.email"]
        )
      : null
  assert(
    emailMatch !== null &&
      emailMatch[1] === expectedId &&
      emailMatch[2] === expectedSlug,
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

  // Branch protection / rulesets belong to the repository owner: every write
  // path is refused, an admin merge included, and so is a GraphQL mutation
  // against the same policy.
  const protectionWrites = [
    "gh ruleset create --repo o/r --branch main",
    "gh ruleset edit 1234 --repo o/r --bypass-pull-requests-as-admin",
    "gh ruleset delete 1234 --repo o/r",
    "gh api -X PUT repos/o/r/branches/main/protection",
    "gh api --method DELETE repos/o/r/branches/main/protection/required_status_checks",
    "gh api repos/o/r/branches/main/protection -f required_status_checks='{}'",
    "gh api -X POST repos/o/r/rulesets",
    "gh api graphql -f query='mutation { updateBranchProtectionRule }'",
    "gh pr merge 1 --repo o/r --admin",
  ]
  for (const command of protectionWrites) {
    let blocked = false
    try {
      await before({ tool: "bash" }, { args: { command }, env: {} })
    } catch (err) {
      blocked = /branch protection/i.test(String((err && err.message) || err))
    }
    assert(blocked, `merge-policy weakening was not blocked: ${command}`)
  }
  // Reading the current rules stays allowed: a blocked merge must still be
  // explainable, only changing the rules is out of scope.
  await before(
    { tool: "bash" },
    { args: { command: "gh api repos/o/r/branches/main/protection" }, env: {} }
  )
  await before(
    { tool: "bash" },
    { args: { command: "gh api -X GET repos/o/r/rulesets" }, env: {} }
  )
  await before({ tool: "bash" }, { args: { command: "gh ruleset list --repo o/r" }, env: {} })
  await before(
    { tool: "bash" },
    { args: { command: "gh ruleset check main --repo o/r" }, env: {} }
  )
  await before({ tool: "bash" }, { args: { command: "gh pr checks 1" }, env: {} })

  // Must not interfere with anything else.
  await before({ tool: "bash" }, { args: { command: "git status" }, env: {} })
  await before({ tool: "read" }, { args: { filePath: "x" }, env: {} })

  // OpenCode reports the variant on the user message and the display name
  // on chat.params. The shell that runs `git vc` must see one trailer label.
  const fs = require("node:fs")
  const os = require("node:os")
  const path = require("node:path")
  const labelDir = fs.mkdtempSync(path.join(os.tmpdir(), "conahcnuj-smoke-"))
  const labelFile = path.join(labelDir, "label.txt")
  const outside = path.join(os.tmpdir(), "..", `conahcnuj-escape-${process.pid}.txt`)
  process.env.CONAHCNUJ_SESSION_MODEL = "xai/grok-4.7"
  process.env.CONAHCNUJ_MODEL_LABEL_FILE = labelFile
  await plugin["chat.message"](
    {
      sessionID: "s1",
      model: { providerID: "xai", modelID: "grok-4.7" },
      variant: "medium",
    },
    { message: {}, parts: [] }
  )
  await plugin["chat.message"](
    {
      sessionID: "s1",
      model: { providerID: "xai", modelID: "grok-small" },
      variant: "low",
    },
    { message: {}, parts: [] }
  )
  await plugin["chat.params"](
    {
      sessionID: "s1",
      agent: "build",
      model: { name: "Grok 4.7", providerID: "xai", id: "grok-4.7" },
    },
    {}
  )
  const labeled = { env: {} }
  await plugin["shell.env"]({ cwd: ".", sessionID: "s1" }, labeled)
  assert.strictEqual(labeled.env.CONAHCNUJ_COMMIT_MODEL, "Grok 4.7 (medium)")
  assert.strictEqual(fs.readFileSync(labelFile, "utf8").trim(), "Grok 4.7 (medium)")
  process.env.CONAHCNUJ_MODEL_LABEL_FILE = outside
  await plugin["chat.params"](
    {
      sessionID: "s1",
      agent: "build",
      model: { name: "Grok 4.7", providerID: "xai", id: "grok-4.7" },
    },
    {}
  )
  assert.strictEqual(fs.existsSync(path.resolve(outside)), false)
  const explicit = { env: { CONAHCNUJ_COMMIT_MODEL: "custom" } }
  await plugin["shell.env"]({ cwd: ".", sessionID: "s1" }, explicit)
  assert.strictEqual(explicit.env.CONAHCNUJ_COMMIT_MODEL, "custom")
  delete process.env.CONAHCNUJ_SESSION_MODEL
  delete process.env.CONAHCNUJ_MODEL_LABEL_FILE
  fs.rmSync(labelDir, { recursive: true, force: true })

  console.log("PLUGIN SMOKE OK")
}

// Guarded entry point (not bare top-level code): importing this file must
// never execute the test as a side effect.
if (require.main === module) {
  main().catch((err) => {
    console.error(`SMOKE FAIL: ${(err && err.message) || err}`)
    process.exit(1)
  })
}
