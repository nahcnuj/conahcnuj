// Unit tests for the opencode plugin, driven entirely through the hooks
// opencode calls (tool.execute.before, shell.env, the system-prompt
// transform, chat.message / chat.params). test/unit.sh compiles the real
// plugins/gh-app-token.ts unchanged into ./.unit/out/, so the code under
// test here IS the production source: this suite keeps no copy and no
// re-export of it, and there is nothing that could drift out of sync with
// the production file.
//
// The plugin resolves its gh-app dir relative to its own location, so
// ./.unit/out/gh-app-token.js reads ./.unit/gh-app, which this suite owns
// (app.env, bot-id.cache, token.cache). global fetch is stubbed before any
// test runs: nothing here reaches the network and no secret is needed.
//
// Usage: bash test/unit.sh (which builds ./.unit/out first)
//   or: node unit-run.js
//
// The require target is a fixed literal path on purpose: requiring an
// argv-provided path trips CodeQL path-injection (high), same as smoke-run.js.
"use strict"

const assert = require("node:assert")
const { createVerify, generateKeyPairSync } = require("node:crypto")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")

const PLUGIN_MODULE = "./.unit/out/gh-app-token.js"
const STAGE_DIR = path.join(__dirname, ".unit")
const GH_APP_DIR = path.join(STAGE_DIR, "gh-app")
const APP_ENV = path.join(GH_APP_DIR, "app.env")
const APP_ENV_EXAMPLE = path.join(GH_APP_DIR, "app.env.example")
const BOT_ID_CACHE = path.join(GH_APP_DIR, "bot-id.cache")
const TOKEN_CACHE = path.join(GH_APP_DIR, "token.cache")
const KEY_FILE = path.join(STAGE_DIR, "signing-key.pem")

const BOT_ID = "331119074"
const BOT = "conahcnuj[bot]"
const VC_USAGE = 'git vc -m "<message>" [-a]'
const TOKEN = "ghs_abcDEF-ghi_jkl.mno~pqr"

const forward = (p) => p.replace(/\\/g, "/")
const aliasVcTarget = () => forward(path.join(GH_APP_DIR, "api-commit.sh"))

// --- network guard ----------------------------------------------------------
// Every fetch is recorded; a test that wants the network installs its own
// handler, anything else fails here instead of reaching api.github.com.

let fetchCalls = []
let fetchHandler = null

globalThis.fetch = async (...args) => {
  fetchCalls.push(args)
  if (!fetchHandler) {
    throw new Error(`unit tests must not reach the network: ${args[0]}`)
  }
  return fetchHandler(...args)
}

// --- fixtures ---------------------------------------------------------------

// Rebuild the gh-app dir the plugin reads. A null value drops the key, so
// stage({ APP_SLUG: null }) reproduces a config without APP_SLUG. Resetting
// the fetch guard here makes stage() the boundary of every test.
function stage(config = {}, botCache = BOT_ID) {
  fs.rmSync(GH_APP_DIR, { recursive: true, force: true })
  fs.mkdirSync(GH_APP_DIR, { recursive: true })
  const settings = {
    APP_ID: "00000",
    INSTALLATION_ID: "00000",
    APP_SLUG: "conahcnuj",
    PRIVATE_KEY_PATH: path.join(STAGE_DIR, "no-such-key.pem"),
    BASH_EXE: "/nonexistent-bash",
    ...config,
  }
  const lines = Object.entries(settings)
    .filter(([, value]) => value !== null)
    .map(([key, value]) => `${key}=${value}`)
  fs.writeFileSync(APP_ENV, `${lines.join("\n")}\n`)
  if (botCache !== null) {
    fs.writeFileSync(BOT_ID_CACHE, String(botCache))
  }
  fetchCalls = []
  fetchHandler = null
}

// Fresh module load: the plugin reads app.env and keeps its state (in-memory
// token, seen models) at import time, so each fixture change starts here.
function loadPlugin() {
  const resolved = require.resolve(PLUGIN_MODULE)
  delete require.cache[resolved]
  return require(PLUGIN_MODULE)
}

async function freshHooks() {
  return loadPlugin().GhAppTokenPlugin({})
}

// --- test registry ----------------------------------------------------------

const tests = []
function test(name, fn) {
  tests.push({ name, fn })
}

// --- helpers ----------------------------------------------------------------

function gitConfigPairs(env) {
  const pairs = {}
  const count = Number(env.GIT_CONFIG_COUNT)
  assert.ok(Number.isInteger(count) && count > 0, `bad GIT_CONFIG_COUNT: ${env.GIT_CONFIG_COUNT}`)
  for (let i = 0; i < count; i++) {
    pairs[env[`GIT_CONFIG_KEY_${i}`]] = env[`GIT_CONFIG_VALUE_${i}`]
  }
  return pairs
}

// The error the hook would raise, or null when it allows the command.
async function redirect(plugin, tool, args) {
  try {
    await plugin["tool.execute.before"]({ tool }, { args, env: {} })
  } catch (err) {
    return String((err && err.message) || err)
  }
  return null
}

async function assertRedirected(commands, needle) {
  const plugin = await freshHooks()
  for (const command of commands) {
    const message = await redirect(plugin, "bash", { command })
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

async function assertAllowed(commands) {
  const plugin = await freshHooks()
  for (const command of commands) {
    assert.strictEqual(await redirect(plugin, "bash", { command }), null, `blocked: ${command}`)
  }
}

// RSA key for the token exchange: written once into the stage (which
// test/unit.sh removes), the public half stays in memory for verification.
let keyPair = null
function signingKeys() {
  if (!keyPair) {
    fs.mkdirSync(STAGE_DIR, { recursive: true })
    const { privateKey, publicKey } = generateKeyPairSync("rsa", { modulusLength: 2048 })
    fs.writeFileSync(KEY_FILE, privateKey.export({ type: "pkcs8", format: "pem" }))
    keyPair = {
      keyPath: KEY_FILE,
      publicKey: publicKey.export({ type: "spki", format: "pem" }),
    }
  }
  return keyPair
}

function assertJwt(jwt, issuer) {
  const parts = jwt.split(".")
  assert.strictEqual(parts.length, 3, `jwt shape: ${jwt}`)
  for (const part of parts) {
    assert.ok(/^[A-Za-z0-9_-]+$/.test(part), `jwt segment is not unpadded base64url: ${part}`)
  }
  const header = JSON.parse(Buffer.from(parts[0], "base64url").toString("utf8"))
  assert.deepStrictEqual(header, { alg: "RS256", typ: "JWT" })
  const payload = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"))
  assert.deepStrictEqual(Object.keys(payload), ["iat", "exp", "iss"])
  assert.strictEqual(payload.iss, issuer)
  assert.strictEqual(payload.exp - payload.iat, 540)
  const verified = createVerify("sha256")
    .update(`${parts[0]}.${parts[1]}`)
    .verify(keyPair.publicKey, Buffer.from(parts[2], "base64url"))
  assert.ok(verified, "jwt signature does not verify against the staged key")
}

// --- the module / plugin surface -------------------------------------------

test("module: exports the plugin factory and nothing else", () => {
  const mod = loadPlugin()
  // opencode's loader treats every export as a plugin, so a second export
  // would be loaded as a second plugin.
  assert.deepStrictEqual(Object.keys(mod), ["GhAppTokenPlugin"])
})

test("plugin: exposes exactly the hooks opencode and the driver rely on", async () => {
  const plugin = await freshHooks()
  assert.deepStrictEqual(Object.keys(plugin).sort(), [
    "chat.message",
    "chat.params",
    "experimental.chat.system.transform",
    "shell.env",
    "tool.execute.before",
  ])
})

// --- git commit redirects ---------------------------------------------------

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
  // Quoting and shell wrappers with nothing to run stay untouched.
  'echo "unterminated',
  'bash "-C/path with space" -m x',
  "bash -x",
  "bash -c",
]

test("redirects: git commit (any form) points at git vc", async () => {
  stage()
  await assertRedirected(GIT_COMMIT_COMMANDS, "git commit")
})

test("redirects: everything else git-ish keeps working", async () => {
  stage()
  await assertAllowed(GIT_ALLOWED_COMMANDS)
})

test("redirects: the git commit message names the bot, the rule and the usage", async () => {
  stage()
  const plugin = await freshHooks()
  const message = await redirect(plugin, "bash", { command: 'git commit -m "x"' })
  assert.ok(message !== null, "git commit was not blocked")
  assert.ok(message.includes(`commits made as ${BOT} are unsigned`), message)
  assert.ok(message.includes("Commits must have verified signatures"), message)
  assert.ok(message.includes(VC_USAGE), message)
  // The commit redirect explains git vc, never the script behind it.
  assert.ok(!message.includes("api-commit.sh"), message)
})

// --- api-commit.sh redirects ------------------------------------------------

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

test("redirects: running api-commit.sh directly points at git vc", async () => {
  stage()
  await assertRedirected(API_COMMIT_COMMANDS, "api-commit.sh")
})

test("redirects: reading or mentioning the script keeps working", async () => {
  stage()
  await assertAllowed(API_COMMIT_ALLOWED_COMMANDS)
})

test("hook: only bash commands are inspected, and they need a command string", async () => {
  stage()
  const plugin = await freshHooks()
  assert.strictEqual(await redirect(plugin, "read", { filePath: "gh-app/api-commit.sh" }), null)
  assert.strictEqual(await redirect(plugin, "edit", { filePath: "x" }), null)
  assert.strictEqual(await redirect(plugin, "bash", {}), null)
  assert.strictEqual(await redirect(plugin, "bash", { command: 42 }), null)
  assert.strictEqual(await redirect(plugin, "bash", "git commit"), null)
  assert.strictEqual(await redirect(plugin, "bash", undefined), null)
  assert.strictEqual(await redirect(plugin, "bash", null), null)
})

// --- shell.env contract -----------------------------------------------------

test("shell.env: publishes the App identity, the alias.vc wrapper and nothing else", async () => {
  stage()
  const plugin = await freshHooks()
  const output = { env: {} }
  await plugin["shell.env"]({ cwd: ".", sessionID: "s1" }, output)
  const pairs = gitConfigPairs(output.env)
  assert.deepStrictEqual(Object.keys(pairs), [
    "user.name",
    "user.email",
    "credential.helper",
    "commit.gpgsign",
    "alias.vc",
  ])
  assert.strictEqual(pairs["user.name"], BOT)
  assert.strictEqual(pairs["user.email"], `${BOT_ID}+${BOT}@users.noreply.github.com`)
  assert.strictEqual(pairs["commit.gpgsign"], "false")
  assert.strictEqual(pairs["alias.vc"], `!"/nonexistent-bash" "${aliasVcTarget()}"`)
  assert.strictEqual(
    pairs["credential.helper"],
    `!"/nonexistent-bash" "${forward(path.join(GH_APP_DIR, "git-credential-helper.sh"))}"`
  )
  // No private key and no token cache in the stage, so no token is issued -
  // and nothing asked the network for one.
  assert.strictEqual(output.env.GH_TOKEN, undefined)
  assert.strictEqual(fetchCalls.length, 0)
  for (const key of Object.keys(output.env)) {
    assert.ok(
      /^GIT_CONFIG_(COUNT|KEY_\d+|VALUE_\d+)$/.test(key),
      `unexpected shell env key: ${key}`
    )
  }
})

// --- installation token -----------------------------------------------------

test("shell.env: a cached installation token is published without any network", async () => {
  stage()
  // Only the first line counts; anything after it is ignored.
  fs.writeFileSync(TOKEN_CACHE, `${Math.floor(Date.now() / 1000) + 3600}|ghs_cached\nmore\n`)
  const plugin = await freshHooks()
  const output = { env: {} }
  await plugin["shell.env"]({ cwd: ".", sessionID: "s1" }, output)
  assert.strictEqual(output.env.GH_TOKEN, "ghs_cached")
  assert.strictEqual(fetchCalls.length, 0)
})

test("shell.env: expired or malformed token caches are ignored, still no network", async () => {
  const now = Math.floor(Date.now() / 1000)
  const cases = [
    ["expired", `${now - 1}|ghs_cached`],
    ["no-separator", "ghs_cached"],
    ["empty", ""],
    ["empty-expiry", "|ghs_cached"],
    ["non-numeric-expiry", `later|ghs_cached`],
  ]
  for (const [name, body] of cases) {
    stage()
    fs.writeFileSync(TOKEN_CACHE, `${body}\n`)
    const plugin = await freshHooks()
    const output = { env: {} }
    await plugin["shell.env"]({ cwd: ".", sessionID: "s1" }, output)
    assert.strictEqual(output.env.GH_TOKEN, undefined, `for ${name}`)
    // The staged key file does not exist, so issuance stops before any
    // request is made.
    assert.strictEqual(fetchCalls.length, 0, `network call for ${name}`)
  }
})

test("shell.env: issues a signed token, caches it and never sends the key twice", async () => {
  const { keyPath } = signingKeys()
  stage({ APP_ID: "54321", INSTALLATION_ID: "12345", PRIVATE_KEY_PATH: keyPath })
  const expiresAt = new Date((Math.floor(Date.now() / 1000) + 3600) * 1000).toISOString()
  fetchHandler = async () => ({
    ok: true,
    status: 201,
    json: async () => ({ token: TOKEN, expires_at: expiresAt }),
  })

  const plugin = await freshHooks()
  const first = { env: {} }
  await plugin["shell.env"]({ cwd: ".", sessionID: "s1" }, first)
  assert.strictEqual(first.env.GH_TOKEN, TOKEN)
  assert.strictEqual(fetchCalls.length, 1)

  // The request itself: right endpoint, and a JWT the staged key really
  // signed (base64url segments, RS256 header, App id as issuer).
  const [url, init] = fetchCalls[0]
  assert.strictEqual(url, "https://api.github.com/app/installations/12345/access_tokens")
  assert.strictEqual(init.method, "POST")
  const authorization = /^Bearer (.+)$/.exec(init.headers.Authorization)
  assert.ok(authorization, `Authorization header: ${init.headers.Authorization}`)
  assertJwt(authorization[1], "54321")

  // The cache file uses the same expiry|token format as gh-app/get-token.sh.
  const expectedExpiry = Math.floor(Date.parse(expiresAt) / 1000) - 600
  assert.strictEqual(fs.readFileSync(TOKEN_CACHE, "utf8"), `${expectedExpiry}|${TOKEN}`)

  // Later shells of the same run reuse the in-memory copy...
  const second = { env: {} }
  await plugin["shell.env"]({ cwd: ".", sessionID: "s1" }, second)
  assert.strictEqual(second.env.GH_TOKEN, TOKEN)
  assert.strictEqual(fetchCalls.length, 1)

  // ...and a fresh run picks the written cache up instead of exchanging again.
  const reloaded = await freshHooks()
  const third = { env: {} }
  await reloaded["shell.env"]({ cwd: ".", sessionID: "s1" }, third)
  assert.strictEqual(third.env.GH_TOKEN, TOKEN)
  assert.strictEqual(fetchCalls.length, 1)
})

test("shell.env: a failed exchange degrades to no GH_TOKEN", async () => {
  const { keyPath } = signingKeys()
  const cases = [
    ["http error", async () => ({ ok: false, status: 503, json: async () => ({}) })],
    ["no token field", async () => ({ ok: true, status: 201, json: async () => ({}) })],
    [
      "malformed token",
      async () => ({ ok: true, status: 201, json: async () => ({ token: "ghs_bad token" }) }),
    ],
    ["network failure", async () => { throw new Error("connection refused") }],
  ]
  for (const [name, handler] of cases) {
    stage({ APP_ID: "54321", INSTALLATION_ID: "12345", PRIVATE_KEY_PATH: keyPath })
    fetchHandler = handler
    const plugin = await freshHooks()
    const output = { env: {} }
    await plugin["shell.env"]({ cwd: ".", sessionID: "s1" }, output)
    assert.strictEqual(output.env.GH_TOKEN, undefined, `for ${name}`)
    assert.strictEqual(fs.existsSync(TOKEN_CACHE), false, `cache written for ${name}`)
    assert.strictEqual(fetchCalls.length, 1, `for ${name}`)
  }
})

test("shell.env: an unusable expires_at falls back to a short cache lifetime", async () => {
  const { keyPath } = signingKeys()
  stage({ APP_ID: "54321", INSTALLATION_ID: "12345", PRIVATE_KEY_PATH: keyPath })
  fetchHandler = async () => ({
    ok: true,
    status: 201,
    json: async () => ({ token: TOKEN, expires_at: "not-a-date" }),
  })
  const plugin = await freshHooks()
  const before = Math.floor(Date.now() / 1000)
  const output = { env: {} }
  await plugin["shell.env"]({ cwd: ".", sessionID: "s1" }, output)
  const after = Math.floor(Date.now() / 1000)
  assert.strictEqual(output.env.GH_TOKEN, TOKEN)
  const expiry = Number(fs.readFileSync(TOKEN_CACHE, "utf8").split("|")[0])
  assert.ok(expiry >= before + 3000, `expiry too early: ${expiry}`)
  assert.ok(expiry <= after + 3000, `expiry too late: ${expiry}`)
})

test("shell.env: unusable exchange config never reaches the network", async () => {
  const brokenConfigs = [
    ["installation id is not digits", { INSTALLATION_ID: "abc" }],
    ["no private key", { PRIVATE_KEY_PATH: null }],
    ["no installation id", { INSTALLATION_ID: null }],
    ["no app id", { APP_ID: null }],
  ]
  for (const [name, config] of brokenConfigs) {
    stage(config)
    const plugin = await freshHooks()
    const output = { env: {} }
    await plugin["shell.env"]({ cwd: ".", sessionID: "s1" }, output)
    assert.strictEqual(output.env.GH_TOKEN, undefined, `for ${name}`)
    assert.strictEqual(fetchCalls.length, 0, `network call for ${name}`)
  }
})

// --- bot identity -----------------------------------------------------------

test("bot id: a digits-only cache is used as-is, with no lookup", async () => {
  stage()
  const plugin = await freshHooks()
  const output = { env: {} }
  await plugin["shell.env"]({ cwd: ".", sessionID: "s1" }, output)
  const pairs = gitConfigPairs(output.env)
  assert.strictEqual(pairs["user.email"], `${BOT_ID}+${BOT}@users.noreply.github.com`)
  assert.strictEqual(fetchCalls.length, 0)
})

test("bot id: a missing or malformed cache falls back to the public lookup", async () => {
  for (const cache of [null, "not-an-id"]) {
    stage({}, cache)
    fetchHandler = async (url) => {
      assert.strictEqual(url, "https://api.github.com/users/conahcnuj%5Bbot%5D")
      return { ok: true, status: 200, json: async () => ({ id: 424242 }) }
    }
    const plugin = await freshHooks()
    const output = { env: {} }
    await plugin["shell.env"]({ cwd: ".", sessionID: "s1" }, output)
    const pairs = gitConfigPairs(output.env)
    assert.strictEqual(pairs["user.email"], `424242+${BOT}@users.noreply.github.com`)
    assert.strictEqual(fetchCalls.length, 1, `for cache=${cache}`)
    // The resolved id is written back, so the next run skips the lookup.
    assert.strictEqual(fs.readFileSync(BOT_ID_CACHE, "utf8").trim(), "424242")
    const again = { env: {} }
    await plugin["shell.env"]({ cwd: ".", sessionID: "s1" }, again)
    assert.strictEqual(fetchCalls.length, 1, `second lookup for cache=${cache}`)
  }
})

test("bot id: a failed lookup or a hostile APP_SLUG fails the plugin loudly", async () => {
  stage({}, null)
  fetchHandler = async () => ({ ok: false, status: 404, json: async () => ({}) })
  await assert.rejects(
    freshHooks(),
    /Cannot resolve bot user ID for conahcnuj\[bot\] \(HTTP 404\)/
  )

  stage({}, null)
  fetchHandler = async () => ({ ok: true, status: 200, json: async () => ({ login: "x" }) })
  await assert.rejects(freshHooks(), /Unexpected user lookup response/)

  // APP_SLUG lands in the request URL, so a hostile value must fail before
  // any request is built.
  stage({ APP_SLUG: "bad slug!" }, null)
  await assert.rejects(freshHooks(), /Invalid APP_SLUG for bot lookup/)
  assert.strictEqual(fetchCalls.length, 0)
})

// --- app.env parsing --------------------------------------------------------

test("app.env: BASH_EXE from app.env is what the git vc alias runs", async () => {
  stage({ BASH_EXE: "C:/custom/bin/bash.exe" })
  const plugin = await freshHooks()
  const output = { env: {} }
  await plugin["shell.env"]({ cwd: ".", sessionID: "s1" }, output)
  const pairs = gitConfigPairs(output.env)
  assert.strictEqual(pairs["alias.vc"], `!"C:/custom/bin/bash.exe" "${aliasVcTarget()}"`)
})

test("app.env: without BASH_EXE the platform default runs git vc", async () => {
  stage({ BASH_EXE: null })
  const plugin = await freshHooks()
  const output = { env: {} }
  await plugin["shell.env"]({ cwd: ".", sessionID: "s1" }, output)
  const pairs = gitConfigPairs(output.env)
  const fallback = process.platform === "win32" ? "C:/Program Files/Git/bin/bash.exe" : "bash"
  assert.strictEqual(pairs["alias.vc"], `!"${fallback}" "${aliasVcTarget()}"`)
})

test("app.env: the example file is used when app.env does not exist", async () => {
  stage()
  fs.rmSync(APP_ENV)
  fs.writeFileSync(
    APP_ENV_EXAMPLE,
    "# example\nAPP_SLUG=exampleslug\nBASH_EXE=/example-bash\n"
  )
  const plugin = await freshHooks()
  const output = { env: {} }
  await plugin["shell.env"]({ cwd: ".", sessionID: "s1" }, output)
  const pairs = gitConfigPairs(output.env)
  assert.strictEqual(pairs["user.name"], "exampleslug[bot]")
  assert.strictEqual(pairs["user.email"], `${BOT_ID}+exampleslug[bot]@users.noreply.github.com`)
  assert.strictEqual(pairs["alias.vc"], `!"/example-bash" "${aliasVcTarget()}"`)
})

test("app.env: without either file the plugin refuses to load", async () => {
  stage()
  fs.rmSync(APP_ENV)
  assert.throws(loadPlugin, /Missing required gh-app config: APP_SLUG/)
})

test("app.env: comments, blanks and unusable keys never satisfy the config", async () => {
  stage()
  fs.writeFileSync(
    APP_ENV,
    [
      "# comment",
      "",
      "   ",
      "no assignment here",
      "lower=1",
      "with space=1",
      "1LEADING=1",
      "app_slug=conahcnuj",
      "APP_SLUG=",
    ].join("\n")
  )
  assert.throws(loadPlugin, /Missing required gh-app config: APP_SLUG/)
})

test("app.env: quotes are stripped and ${HOME} expands in values", async () => {
  const cases = [
    ['"${HOME}/bin/my bash"', "/bin/my bash"],
    ["'${HOME}/bin/sh'", "/bin/sh"],
  ]
  for (const [raw, suffix] of cases) {
    stage({ BASH_EXE: raw })
    const plugin = await freshHooks()
    const output = { env: {} }
    await plugin["shell.env"]({ cwd: ".", sessionID: "s1" }, output)
    const pairs = gitConfigPairs(output.env)
    const home = forward(os.homedir())
    assert.strictEqual(pairs["alias.vc"], `!"${home}${suffix}" "${aliasVcTarget()}"`, `for ${raw}`)
  }
})

test("app.env: CRLF line endings parse like LF", async () => {
  stage()
  fs.writeFileSync(APP_ENV, ["APP_ID=00000", "APP_SLUG=conahcnuj", "BASH_EXE=/crlf-bash"].join("\r\n") + "\r\n")
  const plugin = await freshHooks()
  const output = { env: {} }
  await plugin["shell.env"]({ cwd: ".", sessionID: "s1" }, output)
  const pairs = gitConfigPairs(output.env)
  // A stray \r would end up in the alias and break every `git vc` run.
  assert.strictEqual(pairs["alias.vc"], `!"/crlf-bash" "${aliasVcTarget()}"`)
})

// --- system prompt ----------------------------------------------------------

test("system prompt: the git vc rules are appended exactly once and stay one line", async () => {
  stage()
  const plugin = await freshHooks()
  const output = { system: ["existing rule"] }
  await plugin["experimental.chat.system.transform"]({}, output)
  assert.strictEqual(output.system.length, 2)
  assert.strictEqual(output.system[0], "existing rule")
  const rules = output.system[1]
  assert.ok(!/[\r\n]/.test(rules), "commit rules must be a single line")
  assert.ok(rules.includes("`git vc`"), rules)
  assert.ok(rules.includes("`git commit`"), rules)
  assert.ok(rules.includes("api-commit.sh"), rules)
  assert.ok(rules.includes(VC_USAGE), rules)
  await plugin["experimental.chat.system.transform"]({}, output)
  assert.strictEqual(output.system.length, 2, "commit rules injected more than once")
})

// --- model label ------------------------------------------------------------

test("chat hooks: the session model and variant become one commit trailer label", async () => {
  stage()
  const plugin = await freshHooks()
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "conahcnuj-unit-"))
  const labelFile = path.join(dir, "label.txt")
  const savedModel = process.env.CONAHCNUJ_SESSION_MODEL
  const savedFile = process.env.CONAHCNUJ_MODEL_LABEL_FILE
  try {
    delete process.env.CONAHCNUJ_SESSION_MODEL
    process.env.CONAHCNUJ_MODEL_LABEL_FILE = labelFile

    await plugin["chat.message"](
      { sessionID: "s1", model: { providerID: "opencode", modelID: "fledge" }, variant: "high" },
      { message: {}, parts: [] }
    )
    let output = { env: {} }
    await plugin["shell.env"]({ cwd: ".", sessionID: "s1" }, output)
    assert.strictEqual(output.env.CONAHCNUJ_COMMIT_MODEL, "opencode/fledge (high)")
    assert.strictEqual(fs.readFileSync(labelFile, "utf8"), "opencode/fledge (high)\n")

    // The display name from chat.params wins over the id stand-in.
    await plugin["chat.params"](
      { sessionID: "s1", agent: "build", model: { name: "Grok 4.7", providerID: "xai", id: "grok-4.7" } },
      {}
    )
    output = { env: {} }
    await plugin["shell.env"]({ cwd: ".", sessionID: "s1" }, output)
    assert.strictEqual(output.env.CONAHCNUJ_COMMIT_MODEL, "Grok 4.7 (high)")

    // A name that already carries the variant is not suffixed twice.
    await plugin["chat.params"](
      { sessionID: "s2", agent: "build", model: { name: "Grok 4.7 (high)", providerID: "xai", id: "grok-4.7" } },
      {}
    )
    await plugin["chat.message"](
      { sessionID: "s2", model: { providerID: "xai", modelID: "grok-4.7" }, variant: "high" },
      { message: {}, parts: [] }
    )
    output = { env: {} }
    await plugin["shell.env"]({ cwd: ".", sessionID: "s2" }, output)
    assert.strictEqual(output.env.CONAHCNUJ_COMMIT_MODEL, "Grok 4.7 (high)")

    // Newlines and tabs in a display name collapse into one line.
    await plugin["chat.params"](
      { sessionID: "s3", agent: "build", model: { name: "Grok\n4.7\t", providerID: "xai", id: "g" } },
      {}
    )
    await plugin["chat.message"](
      { sessionID: "s3", model: { providerID: "xai", modelID: "g" }, variant: "medium" },
      { message: {}, parts: [] }
    )
    output = { env: {} }
    await plugin["shell.env"]({ cwd: ".", sessionID: "s3" }, output)
    assert.strictEqual(output.env.CONAHCNUJ_COMMIT_MODEL, "Grok 4.7 (medium)")

    // A variant without any name produces no label at all.
    await plugin["chat.message"]({ sessionID: "s4", variant: "medium" }, { message: {}, parts: [] })
    output = { env: {} }
    await plugin["shell.env"]({ cwd: ".", sessionID: "s4" }, output)
    assert.strictEqual(output.env.CONAHCNUJ_COMMIT_MODEL, undefined)

    // An explicit label (the caller already chose one) is never overwritten.
    output = { env: { CONAHCNUJ_COMMIT_MODEL: "custom" } }
    await plugin["shell.env"]({ cwd: ".", sessionID: "s1" }, output)
    assert.strictEqual(output.env.CONAHCNUJ_COMMIT_MODEL, "custom")
  } finally {
    if (savedModel === undefined) {
      delete process.env.CONAHCNUJ_SESSION_MODEL
    } else {
      process.env.CONAHCNUJ_SESSION_MODEL = savedModel
    }
    if (savedFile === undefined) {
      delete process.env.CONAHCNUJ_MODEL_LABEL_FILE
    } else {
      process.env.CONAHCNUJ_MODEL_LABEL_FILE = savedFile
    }
    fs.rmSync(dir, { recursive: true, force: true })
  }
})

test("chat hooks: CONAHCNUJ_SESSION_MODEL keeps side models out of the label", async () => {
  stage()
  const saved = process.env.CONAHCNUJ_SESSION_MODEL
  try {
    process.env.CONAHCNUJ_SESSION_MODEL = "opencode/fledge"
    const plugin = await freshHooks()

    await plugin["chat.message"](
      { sessionID: "a", model: { providerID: "opencode", modelID: "other" }, variant: "high" },
      { message: {}, parts: [] }
    )
    let output = { env: {} }
    await plugin["shell.env"]({ cwd: ".", sessionID: "a" }, output)
    assert.strictEqual(output.env.CONAHCNUJ_COMMIT_MODEL, undefined)

    await plugin["chat.message"](
      { sessionID: "a", model: { providerID: "opencode", modelID: "fledge" }, variant: "high" },
      { message: {}, parts: [] }
    )
    output = { env: {} }
    await plugin["shell.env"]({ cwd: ".", sessionID: "a" }, output)
    assert.strictEqual(output.env.CONAHCNUJ_COMMIT_MODEL, "opencode/fledge (high)")

    // A bare model id matches that id, whatever the provider around it...
    process.env.CONAHCNUJ_SESSION_MODEL = "fledge"
    await plugin["chat.message"](
      { sessionID: "b", model: { providerID: "xai", modelID: "fledge" }, variant: "low" },
      { message: {}, parts: [] }
    )
    output = { env: {} }
    await plugin["shell.env"]({ cwd: ".", sessionID: "b" }, output)
    assert.strictEqual(output.env.CONAHCNUJ_COMMIT_MODEL, "xai/fledge (low)")

    // ...but never a different model id.
    await plugin["chat.message"](
      { sessionID: "c", model: { providerID: "xai", modelID: "other" }, variant: "low" },
      { message: {}, parts: [] }
    )
    output = { env: {} }
    await plugin["shell.env"]({ cwd: ".", sessionID: "c" }, output)
    assert.strictEqual(output.env.CONAHCNUJ_COMMIT_MODEL, undefined)
  } finally {
    if (saved === undefined) {
      delete process.env.CONAHCNUJ_SESSION_MODEL
    } else {
      process.env.CONAHCNUJ_SESSION_MODEL = saved
    }
  }
})

test("chat hooks: the label file path cannot escape the temp directory", async () => {
  stage()
  const plugin = await freshHooks()
  const escapeFile = path.join(
    path.dirname(os.tmpdir()),
    `conahcnuj-unit-escape-${process.pid}.txt`
  )
  const saved = process.env.CONAHCNUJ_MODEL_LABEL_FILE
  try {
    process.env.CONAHCNUJ_MODEL_LABEL_FILE = escapeFile
    await plugin["chat.message"](
      { sessionID: "s1", model: { providerID: "xai", modelID: "grok" }, variant: "medium" },
      { message: {}, parts: [] }
    )
    assert.strictEqual(fs.existsSync(escapeFile), false, "label written outside the temp dir")
    const output = { env: {} }
    await plugin["shell.env"]({ cwd: ".", sessionID: "s1" }, output)
    // The label itself still reaches the shell; only the file write is denied.
    assert.strictEqual(output.env.CONAHCNUJ_COMMIT_MODEL, "xai/grok (medium)")
  } finally {
    if (saved === undefined) {
      delete process.env.CONAHCNUJ_MODEL_LABEL_FILE
    } else {
      process.env.CONAHCNUJ_MODEL_LABEL_FILE = saved
    }
    fs.rmSync(escapeFile, { force: true })
  }
})

// --- runner -----------------------------------------------------------------

async function main() {
  if (!fs.existsSync(path.join(STAGE_DIR, "out", "gh-app-token.js"))) {
    console.error("UNIT FAIL: test/.unit/out is missing; run: bash test/unit.sh")
    process.exit(1)
  }
  stage()
  // The driver may run opencode with these set: they must not leak into the
  // fixtures (the plugin records a model per CONAHCNUJ_SESSION_MODEL).
  const ambient = {
    sessionModel: process.env.CONAHCNUJ_SESSION_MODEL,
    labelFile: process.env.CONAHCNUJ_MODEL_LABEL_FILE,
  }
  delete process.env.CONAHCNUJ_SESSION_MODEL
  delete process.env.CONAHCNUJ_MODEL_LABEL_FILE
  let failed = 0
  try {
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
  } finally {
    if (ambient.sessionModel === undefined) {
      delete process.env.CONAHCNUJ_SESSION_MODEL
    } else {
      process.env.CONAHCNUJ_SESSION_MODEL = ambient.sessionModel
    }
    if (ambient.labelFile === undefined) {
      delete process.env.CONAHCNUJ_MODEL_LABEL_FILE
    } else {
      process.env.CONAHCNUJ_MODEL_LABEL_FILE = ambient.labelFile
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
