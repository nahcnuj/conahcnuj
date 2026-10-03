// Unit tests for the opencode plugin internals (plain Node, no deps).
// Usage: bash test/unit.sh (which compiles a test build into ./.unit/)
//   or: node unit-run.js
//
// Focus: the command inspection behind the `git vc` redirects (the part an
// agent actually trips over), app.env / cache parsing, and the model-label
// plumbing. The installed-file runtime contract (hook wiring as opencode sees
// it) is covered separately by smoke-run.js.
// The require target is a fixed literal path on purpose: requiring an
// argv-provided path trips CodeQL path-injection (high), same as smoke-run.js.
"use strict"

const assert = require("node:assert")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")

const compiled = require("./.unit/out/gh-app-token.js")
const GhAppTokenPlugin = compiled.GhAppTokenPlugin
const u = compiled.__unit

const BOT = "conahcnuj[bot]"
const STAGE_GH_APP = path.join(__dirname, ".unit", "gh-app")

const tests = []
function test(name, fn) {
  tests.push({ name, fn })
}

// --- helpers ---------------------------------------------------------------

// Error message the hook would raise, or null when it allows the command.
function redirectMessage(tool, args) {
  try {
    u.redirectToVerifiedCommit(tool, args, BOT)
  } catch (err) {
    return String((err && err.message) || err)
  }
  return null
}

function assertRedirected(commands, needle) {
  for (const command of commands) {
    const message = redirectMessage("bash", { command })
    assert.ok(
      message !== null && message.includes("git vc") && message.includes(needle),
      `not redirected to git vc (${needle}): ${command} -> ${message}`
    )
    // The redirect must never point back at the script it replaces.
    assert.ok(
      !/bash ["'][^"']*api-commit\.sh/.test(message),
      `redirect suggests running api-commit.sh: ${message}`
    )
  }
}

function assertAllowed(commands) {
  for (const command of commands) {
    assert.strictEqual(redirectMessage("bash", { command }), null, `blocked: ${command}`)
  }
}

// --- git commit ------------------------------------------------------------

const GIT_COMMIT_COMMANDS = [
  'git commit -m "x"',
  "git commit --amend --no-edit",
  "git.exe commit -m x",
  "git -C /tmp/repo commit -m x",
  "git -c user.email=a@b commit -m x",
  "git --no-pager commit -m x",
  // Plumbing commit creators are unsigned too.
  "git commit-tree HEAD -m x",
  // Reached through separators, assignments and shell wrappers.
  "cd repo && git commit -m x",
  "git status; git commit -m x",
  "git add -A && git commit -m x",
  "true | git commit -m x",
  "git add -A\ngit commit -m x",
  "(cd repo && git commit -m x)",
  "GH_TOKEN=x git commit -m x",
  'bash -c "git commit -m x"',
  "sh -c 'cd repo && git commit -m x'",
]

const GIT_ALLOWED_COMMANDS = [
  "git status",
  "git add -A && git vc -m x",
  "git diff --cached",
  "git log --oneline -5",
  "git push origin main",
  // The sanctioned path and the staging step must never be blocked.
  'git vc -m "message"',
  'git vc -m "message" -a',
  // Only the command word counts: mentions inside another command or string
  // are harmless.
  "git commitx",
  'echo "git commit"',
  'grep -rn "git commit" AGENTS.md',
  'bash -c "echo git commit"',
]

test("redirects: git commit (any form) points at git vc", () => {
  assertRedirected(GIT_COMMIT_COMMANDS, "git commit")
})

test("redirects: everything else git-ish keeps working", () => {
  assertAllowed(GIT_ALLOWED_COMMANDS)
})

// --- api-commit.sh ---------------------------------------------------------

const API_COMMIT_COMMANDS = [
  "api-commit.sh -m x",
  "./gh-app/api-commit.sh -m x",
  "gh-app/api-commit.sh -m x",
  '/opt/conahcnuj/gh-app/api-commit.sh --dry-run',
  'bash gh-app/api-commit.sh -m "x"',
  'bash "/opt/conahcnuj/gh-app/api-commit.sh" -m x',
  'sh "$HOME/.config/opencode/gh-app/api-commit.sh" -m x',
  "Bash gh-app/api-commit.sh -m x",
  "bash --norc gh-app/api-commit.sh -m x",
  "cd repo && sh /opt/gh-app/api-commit.sh",
  "git add -A && api-commit.sh -m x",
  "VAR=1 bash -lc '/tmp/gh-app/api-commit.sh -m x'",
  'zsh -c "cd repo && api-commit.sh -m x"',
  'bash -c "cd repo && bash gh-app/api-commit.sh -m x"',
  "C:\\gh-app\\api-commit.sh -m x",
]

const API_COMMIT_ALLOWED_COMMANDS = [
  'git vc -m "message"',
  'git vc -m "message" -a',
  "cat gh-app/api-commit.sh",
  "grep -n 'api-commit.sh' AGENTS.md",
  "sed -n 1,20p gh-app/api-commit.sh",
  "echo api-commit.sh",
  'bash -c "grep -n api-commit.sh AGENTS.md"',
  // Similar names are not the script.
  "bash gh-app/api-commit.sh.bak",
  "bash gh-app/my-api-commit.sh",
  "gh-app/api-commit-notes.md",
]

test("redirects: running api-commit.sh directly points at git vc", () => {
  assertRedirected(API_COMMIT_COMMANDS, "api-commit.sh")
})

test("redirects: reading or mentioning the script keeps working", () => {
  assertAllowed(API_COMMIT_ALLOWED_COMMANDS)
})

test("hook: only bash commands are inspected, and they need a command string", () => {
  assert.strictEqual(redirectMessage("read", { filePath: "gh-app/api-commit.sh" }), null)
  assert.strictEqual(redirectMessage("edit", { filePath: "x" }), null)
  assert.strictEqual(redirectMessage("bash", {}), null)
  assert.strictEqual(redirectMessage("bash", { command: 42 }), null)
  assert.strictEqual(redirectMessage("bash", undefined), null)
})

// --- command inspection internals -----------------------------------------

test("commandWords: quotes keep a path or an inline script in one piece", () => {
  assert.deepStrictEqual(u.commandWords('bash "-C/path with space" -m x'), [
    ["bash", "-C/path with space", "-m", "x"],
  ])
  assert.deepStrictEqual(u.commandWords('bash -c "cd x && api-commit.sh -m x"'), [
    ["bash", "-c", "cd x && api-commit.sh -m x"],
  ])
  assert.deepStrictEqual(u.commandWords("'gh-app/api-commit.sh' -m x"), [
    ["gh-app/api-commit.sh", "-m", "x"],
  ])
  // Separators outside quotes still split.
  assert.deepStrictEqual(u.commandWords("a && b | c ; d"), [["a"], ["b"], ["c"], ["d"]])
  // An explicitly empty word survives; blank input yields nothing.
  assert.deepStrictEqual(u.commandWords('a "" b'), [["a", "", "b"]])
  assert.deepStrictEqual(u.commandWords("   "), [])
  assert.deepStrictEqual(u.commandWords(""), [])
  // An unterminated quote keeps the rest as one word.
  assert.deepStrictEqual(u.commandWords('echo "unterminated'), [["echo", "unterminated"]])
})

test("basename: last path element, for both separators", () => {
  assert.strictEqual(u.basename("api-commit.sh"), "api-commit.sh")
  assert.strictEqual(u.basename("gh-app/api-commit.sh"), "api-commit.sh")
  assert.strictEqual(u.basename("/opt/x/gh-app/api-commit.sh"), "api-commit.sh")
  assert.strictEqual(u.basename("C:\\gh-app\\api-commit.sh"), "api-commit.sh")
  assert.strictEqual(u.basename("/opt/x/gh-app/"), "")
})

test("executedCommands: yields what a shell would run, wrappers unwrapped", () => {
  assert.deepStrictEqual([...u.executedCommands("git status")], [["git", "status"]])
  assert.deepStrictEqual([...u.executedCommands("VAR=1 GH_TOKEN=x git status")], [
    ["git", "status"],
  ])
  assert.deepStrictEqual([...u.executedCommands("a && b | c; d")], [
    ["a"],
    ["b"],
    ["c"],
    ["d"],
  ])
  assert.deepStrictEqual([...u.executedCommands('bash -c "cd x && ls"')], [
    ["cd", "x"],
    ["ls"],
  ])
  assert.deepStrictEqual(
    [...u.executedCommands("bash --norc gh-app/api-commit.sh -m x")],
    [["gh-app/api-commit.sh", "-m", "x"]]
  )
  // Wrappers with nothing to run contribute nothing.
  assert.deepStrictEqual([...u.executedCommands("bash -x")], [])
  assert.deepStrictEqual([...u.executedCommands("bash -c")], [])
  assert.deepStrictEqual([...u.executedCommands("   ")], [])
})

test("isGitCommitInvocation: commit subcommands only, past git options", () => {
  assert.strictEqual(u.isGitCommitInvocation(["git", "commit"]), true)
  assert.strictEqual(u.isGitCommitInvocation(["git", "commit-tree", "-m", "x"]), true)
  assert.strictEqual(u.isGitCommitInvocation(["git.exe", "commit"]), true)
  assert.strictEqual(u.isGitCommitInvocation(["git", "-C", "/tmp", "commit"]), true)
  assert.strictEqual(u.isGitCommitInvocation(["git", "-c", "a=b", "commit"]), true)
  assert.strictEqual(u.isGitCommitInvocation(["git", "commitx"]), false)
  assert.strictEqual(u.isGitCommitInvocation(["git", "status"]), false)
  assert.strictEqual(u.isGitCommitInvocation(["git"]), false)
  assert.strictEqual(u.isGitCommitInvocation(["gh", "api"]), false)
  assert.strictEqual(u.isGitCommitInvocation([]), false)
})

test("parseBashCommand: only an object arg with a string command", () => {
  assert.strictEqual(u.parseBashCommand({ command: "git status" }), "git status")
  for (const args of [undefined, null, "git commit", {}, { command: 42 }, ["git commit"]]) {
    assert.strictEqual(u.parseBashCommand(args), null, `for ${JSON.stringify(args)}`)
  }
})

// --- config / cache parsing ------------------------------------------------

test("parseAppEnv: reads KEY=VALUE, skips comments, blanks and unusable keys", () => {
  assert.deepStrictEqual(
    u.parseAppEnv(
      [
        "# comment",
        "",
        "   ",
        "APP_ID=123",
        "APP_SLUG=conahcnuj",
        "no assignment here",
        "lower=1",
        "with space=1",
        "1LEADING=1",
        "UNKNOWN_KEY=keep",
      ].join("\n")
    ),
    { APP_ID: "123", APP_SLUG: "conahcnuj", UNKNOWN_KEY: "keep" }
  )
})

test("parseAppEnv: quotes, ${HOME}, CRLF and inner spaces in values", () => {
  const home = os.homedir()
  assert.deepStrictEqual(
    u.parseAppEnv(
      ['A="quoted"', "B='single'", "C=${HOME}/x", "D=a=b", "E=  padded  ", "F=line\r"].join(
        "\r\n"
      )
    ),
    { A: "quoted", B: "single", C: `${home}/x`, D: "a=b", E: "padded", F: "line" }
  )
})

test("resolveBashExe: an explicit app.env value wins over the platform default", () => {
  const fallback = process.platform === "win32" ? "C:/Program Files/Git/bin/bash.exe" : "bash"
  assert.strictEqual(u.resolveBashExe("C:/Program Files/Git/bin/bash.exe"), "C:/Program Files/Git/bin/bash.exe")
  assert.strictEqual(u.resolveBashExe(undefined), fallback)
  assert.strictEqual(u.resolveBashExe(""), fallback)
})

test("b64url: base64url without padding, from text and bytes", () => {
  assert.strictEqual(u.b64url('{"alg":"RS256","typ":"JWT"}'), "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9")
  assert.strictEqual(u.b64url("a?b>c~d"), "YT9iPmN-ZA")
  assert.strictEqual(u.b64url(new Uint8Array([0xfb, 0xff, 0xfe])), "-__-")
  assert.ok(!u.b64url("abcde").includes("="))
})

test("readBotIdCache: digits only, missing or malformed cache ignored", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "conahcnuj-unit-"))
  try {
    const good = path.join(dir, "good")
    fs.writeFileSync(good, "331119074\n")
    assert.strictEqual(u.readBotIdCache(good), "331119074")
    const bad = path.join(dir, "bad")
    fs.writeFileSync(bad, "not-an-id\n")
    assert.strictEqual(u.readBotIdCache(bad), null)
    assert.strictEqual(u.readBotIdCache(path.join(dir, "absent")), null)
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test("readTokenCache: unexpired token accepted, expired or malformed ignored", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "conahcnuj-unit-"))
  const now = Math.floor(Date.now() / 1000)
  try {
    const valid = path.join(dir, "valid")
    // Only the first line counts; the rest is ignored.
    fs.writeFileSync(valid, `${now + 3600}|ghs_token\nsecond line\n`)
    assert.strictEqual(u.readTokenCache(valid), "ghs_token")
    const expired = path.join(dir, "expired")
    fs.writeFileSync(expired, `${now - 1}|ghs_token`)
    assert.strictEqual(u.readTokenCache(expired), null)
    for (const [name, body] of [
      ["no-separator", "ghs_token"],
      ["empty", ""],
      ["empty-expiry", "|ghs_token"],
    ]) {
      const file = path.join(dir, name)
      fs.writeFileSync(file, body)
      assert.strictEqual(u.readTokenCache(file), null, `for ${name}`)
    }
    assert.strictEqual(u.readTokenCache(path.join(dir, "absent")), null)
  } finally {
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

// --- model label plumbing --------------------------------------------------

test("formatModelLabel: appends the variant once, tolerates empty input", () => {
  assert.strictEqual(u.formatModelLabel("Grok 4.7", "medium"), "Grok 4.7 (medium)")
  assert.strictEqual(u.formatModelLabel("Grok 4.7 (medium)", "medium"), "Grok 4.7 (medium)")
  assert.strictEqual(u.formatModelLabel("Grok 4.7", ""), "Grok 4.7")
  assert.strictEqual(u.formatModelLabel("", "medium"), "")
  assert.strictEqual(u.formatModelLabel("Grok\n4.7", "high"), "Grok 4.7 (high)")
})

test("matchesSessionModel: only the pinned session model counts", () => {
  const saved = process.env.CONAHCNUJ_SESSION_MODEL
  try {
    delete process.env.CONAHCNUJ_SESSION_MODEL
    assert.strictEqual(u.matchesSessionModel("opencode", "fledge"), true)
    process.env.CONAHCNUJ_SESSION_MODEL = "opencode/fledge"
    assert.strictEqual(u.matchesSessionModel("opencode", "fledge"), true)
    assert.strictEqual(u.matchesSessionModel("opencode", "other"), false)
    assert.strictEqual(u.matchesSessionModel("xai", "fledge"), false)
    // A bare model id also matches, but never a different provider's.
    process.env.CONAHCNUJ_SESSION_MODEL = "fledge"
    assert.strictEqual(u.matchesSessionModel("opencode", "fledge"), true)
    assert.strictEqual(u.matchesSessionModel("opencode", "other"), false)
  } finally {
    if (saved === undefined) {
      delete process.env.CONAHCNUJ_SESSION_MODEL
    } else {
      process.env.CONAHCNUJ_SESSION_MODEL = saved
    }
  }
})

test("commit rules: name git vc, forbid the rest, stay one line", () => {
  assert.ok(!/[\r\n]/.test(u.COMMIT_RULES), "commit rules must be a single line")
  assert.ok(u.COMMIT_RULES.includes("`git vc`"))
  assert.ok(u.COMMIT_RULES.includes("`git commit`"))
  assert.ok(u.COMMIT_RULES.includes("api-commit.sh"))
  assert.ok(u.COMMIT_RULES.includes(u.VC_USAGE))
  // The usage string is the alias only: never the script behind it.
  assert.strictEqual(u.VC_USAGE, 'git vc -m "<message>" [-a]')
})

// --- hook wiring (the staged app.env drives this) -------------------------

async function pluginOnce() {
  return GhAppTokenPlugin({})
}

function gitConfigPairs(env) {
  const pairs = {}
  const count = Number(env.GIT_CONFIG_COUNT)
  assert.ok(Number.isInteger(count) && count > 0, `bad GIT_CONFIG_COUNT: ${env.GIT_CONFIG_COUNT}`)
  for (let i = 0; i < count; i++) {
    pairs[env[`GIT_CONFIG_KEY_${i}`]] = env[`GIT_CONFIG_VALUE_${i}`]
  }
  return pairs
}

test("hook: shell.env publishes the App identity, the alias.vc wrapper and nothing else", async () => {
  const plugin = await pluginOnce()
  const output = { env: {} }
  await plugin["shell.env"]({ cwd: ".", sessionID: "unit-env" }, output)
  const pairs = gitConfigPairs(output.env)
  assert.deepStrictEqual(Object.keys(pairs), [
    "user.name",
    "user.email",
    "credential.helper",
    "commit.gpgsign",
    "alias.vc",
  ])
  assert.strictEqual(pairs["user.name"], BOT)
  // bot id comes from the seeded bot-id.cache, so no lookup happens.
  assert.strictEqual(pairs["user.email"], `331119074+${BOT}@users.noreply.github.com`)
  assert.strictEqual(pairs["commit.gpgsign"], "false")
  assert.ok(
    pairs["credential.helper"].endsWith('git-credential-helper.sh"'),
    `credential.helper: ${pairs["credential.helper"]}`
  )
  // BASH_EXE from app.env is what the alias runs the script with.
  const apiCommitSh = path.join(STAGE_GH_APP, "api-commit.sh").replace(/\\/g, "/")
  assert.strictEqual(pairs["alias.vc"], `!"/nonexistent-bash" "${apiCommitSh}"`)
  // No private key in the stage, so no token is issued.
  assert.strictEqual(output.env.GH_TOKEN, undefined)
  for (const key of Object.keys(output.env)) {
    assert.ok(
      /^GIT_CONFIG_(COUNT|KEY_\d+|VALUE_\d+)$/.test(key),
      `unexpected shell env key: ${key}`
    )
  }
})

test("hook: a cached installation token is published as GH_TOKEN", async () => {
  const cacheFile = path.join(STAGE_GH_APP, "token.cache")
  fs.writeFileSync(cacheFile, `${Math.floor(Date.now() / 1000) + 3600}|ghs_cached\n`)
  try {
    const plugin = await pluginOnce()
    const output = { env: {} }
    await plugin["shell.env"]({ cwd: ".", sessionID: "unit-token" }, output)
    assert.strictEqual(output.env.GH_TOKEN, "ghs_cached")
  } finally {
    fs.rmSync(cacheFile, { force: true })
  }
})

test("hook: the commit rules reach the system prompt exactly once", async () => {
  const plugin = await pluginOnce()
  const output = { system: [] }
  await plugin["experimental.chat.system.transform"]({}, output)
  assert.deepStrictEqual(output.system, [u.COMMIT_RULES])
  await plugin["experimental.chat.system.transform"]({}, output)
  assert.strictEqual(output.system.length, 1)
})

test("hook: the session model name and variant become the commit-model label", async () => {
  const plugin = await pluginOnce()
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "conahcnuj-unit-"))
  const labelFile = path.join(dir, "label.txt")
  process.env.CONAHCNUJ_MODEL_LABEL_FILE = labelFile
  delete process.env.CONAHCNUJ_SESSION_MODEL
  try {
    await plugin["chat.message"](
      {
        sessionID: "unit-label",
        model: { providerID: "opencode", modelID: "fledge" },
        variant: "high",
      },
      { message: {}, parts: [] }
    )
    const output = { env: {} }
    await plugin["shell.env"]({ sessionID: "unit-label" }, output)
    assert.strictEqual(output.env.CONAHCNUJ_COMMIT_MODEL, "opencode/fledge (high)")
    assert.strictEqual(fs.readFileSync(labelFile, "utf8").trim(), "opencode/fledge (high)")
  } finally {
    delete process.env.CONAHCNUJ_MODEL_LABEL_FILE
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

// --- runner ----------------------------------------------------------------

async function main() {
  let failed = 0
  for (const { name, fn } of tests) {
    try {
      await fn()
      console.log(`ok - ${name}`)
    } catch (err) {
      failed += 1
      console.log(`not ok - ${name}`)
      const detail = String((err && err.message) || err)
      console.log(`  ${detail.split("\n").join("\n  ")}`)
    }
  }
  console.log(`\n${tests.length - failed}/${tests.length} unit tests passed`)
  if (failed > 0) {
    process.exit(1)
  }
}

// Guarded entry point (not bare top-level code): importing this file must
// never execute the suite as a side effect.
if (require.main === module) {
  main().catch((err) => {
    console.error(`UNIT FAIL: ${(err && err.message) || err}`)
    process.exit(1)
  })
}