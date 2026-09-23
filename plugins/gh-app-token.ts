import type { Plugin } from "@opencode-ai/plugin"
import { createSign } from "node:crypto"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"

const GH_APP_DIR = path.join(__dirname, "..", "gh-app")
const TOKEN_CACHE_FILE = path.join(GH_APP_DIR, "token.cache")
const CREDENTIAL_HELPER_SH = path.join(GH_APP_DIR, "git-credential-helper.sh")

// Git Bash on Windows; plain PATH lookup everywhere else (an explicit
// app.env value always wins, even when it does not exist yet: smoke tests
// stage a bogus path on purpose and must still load).
const BASH_EXE_WINDOWS = "C:/Program Files/Git/bin/bash.exe"
function resolveBashExe(explicit: string | undefined): string {
  if (explicit) {
    return explicit
  }
  return process.platform === "win32" ? BASH_EXE_WINDOWS : "bash"
}
const REQUIRED_KEYS = ["APP_SLUG"] as const
// Read from app.env when present, but never required up front: they are
// only validated inside fetchInstallationToken.
const TOKEN_KEYS = ["APP_ID", "INSTALLATION_ID", "PRIVATE_KEY_PATH"] as const

type Config = {
  BASH_EXE: string
} & {
  [K in (typeof REQUIRED_KEYS)[number]]: string
} & {
  [K in (typeof TOKEN_KEYS)[number]]?: string
}

/**
 * Parse `KEY=VALUE` lines (dotenv flavor). Only known keys (defaults,
 * required, token keys) are kept; anything else is ignored. Surrounding
 * quotes are stripped and a leading `${HOME}` is expanded. Keys must look
 * like `UPPER_SNAKE` so computed property writes stay safe.
 */
function parseAppEnv(text: string): Record<string, string> {
  const out: Record<string, string> = {}
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim()
    if (!line || line.startsWith("#") || !line.includes("=")) continue
    const idx = line.indexOf("=")
    const key = line.slice(0, idx).trim()
    if (!/^[A-Z][A-Z0-9_]*$/.test(key)) continue
    let value = line.slice(idx + 1).trim()
    if (
      value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'")))
    ) {
      value = value.slice(1, -1)
    }
    value = value.replace(/^\$\{HOME\}/, os.homedir())
    out[key] = value
  }
  return out
}

/**
 * Load config: defaults, then app.env (or app.env.example) overlay, then
 * required-key validation.
 */
function loadAppEnv(): Config {
  const envFile = fs.existsSync(path.join(GH_APP_DIR, "app.env"))
    ? path.join(GH_APP_DIR, "app.env")
    : path.join(GH_APP_DIR, "app.env.example")
  const parsed: Record<string, string> = fs.existsSync(envFile)
    ? parseAppEnv(fs.readFileSync(envFile, "utf8"))
    : {}
  const config: Config = {
    BASH_EXE: resolveBashExe(parsed["BASH_EXE"]),
    APP_SLUG: parsed["APP_SLUG"] ?? "",
  }
  for (const key of TOKEN_KEYS) {
    if (parsed[key]) {
      config[key] = parsed[key]
    }
  }
  const missing = (REQUIRED_KEYS as readonly string[]).filter(
    (k) => !(config as Record<string, string>)[k]
  )
  if (missing.length > 0) {
    throw new Error(
      `Missing required gh-app config: ${missing.join(", ")}. ` +
        `Set them in gh-app/app.env (see app.env.example).`
    )
  }
  return config
}

/**
 * Base64url-encode bytes or text (JWT building block).
 */
function b64url(input: Uint8Array | string): string {
  const buf =
    typeof input === "string" ? Buffer.from(input, "utf8") : Buffer.from(input)
  return buf
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "")
}

const BOT_ID_CACHE_FILE = path.join(GH_APP_DIR, "bot-id.cache")

/**
 * Read a cached bot user ID (plain digits). Bot IDs are immutable, so the
 * cache never expires; a malformed cache is ignored like a missing one.
 */
function readBotIdCache(cacheFile: string): string | null {
  let raw: string
  try {
    raw = fs.readFileSync(cacheFile, "utf8")
  } catch {
    return null
  }
  const id = raw.trim()
  return /^\d+$/.test(id) ? id : null
}

/**
 * Resolve the bot account user ID (`<slug>[bot]`): persistent cache first,
 * then the public GitHub API (no auth needed), caching the result. The
 * slug allowlist keeps user-controlled config out of the request URL.
 * APP_ID is deliberately NOT a fallback: it is the App's own ID and never
 * attributes commits to the bot account.
 */
async function resolveBotUserId(slug: string): Promise<string> {
  const cached = readBotIdCache(BOT_ID_CACHE_FILE)
  if (cached) {
    return cached
  }
  if (!/^[A-Za-z0-9-]+$/.test(slug)) {
    throw new Error(`Invalid APP_SLUG for bot lookup: ${slug}`)
  }
  const res = await fetch(`https://api.github.com/users/${slug}%5Bbot%5D`, {
    headers: { Accept: "application/vnd.github+json" },
  })
  if (!res.ok) {
    throw new Error(
      `Cannot resolve bot user ID for ${slug}[bot] (HTTP ${res.status}): ` +
        `check network access to api.github.com.`
    )
  }
  const data: unknown = await res.json()
  if (
    typeof data !== "object" ||
    data === null ||
    !("id" in data) ||
    typeof (data as { id: unknown }).id !== "number"
  ) {
    throw new Error(`Unexpected user lookup response for ${slug}[bot].`)
  }
  const id = String((data as { id: number }).id)
  try {
    fs.writeFileSync(BOT_ID_CACHE_FILE, id, "utf8")
  } catch {
    // Cache is best-effort only; the resolved ID is still returned.
  }
  return id
}

/**
 * Read a cached installation token (`expiry|token`) when still valid.
 * Returns null on any problem (missing/expired/malformed cache).
 */
function readTokenCache(cacheFile: string): string | null {
  let raw: string
  try {
    raw = fs.readFileSync(cacheFile, "utf8")
  } catch {
    return null
  }
  const match = /^(\d+)\|(.+)$/.exec(raw.split("\n", 1)[0] ?? "")
  if (!match) {
    return null
  }
  if (Date.now() / 1000 >= Number(match[1])) {
    return null
  }
  return match[2]
}

/**
 * Fetch a fresh installation token: RS256-sign a JWT with the App private
 * key and exchange it at the installations endpoint. Same wire behavior
 * as gh-app/get-token.sh (shared `token.cache` format included).
 */
async function fetchInstallationToken(
  config: Config,
  cacheFile: string
): Promise<string> {
  const appId = config.APP_ID
  const installationId = config.INSTALLATION_ID
  let keyPath = config.PRIVATE_KEY_PATH
  if (!appId || !installationId || !keyPath) {
    throw new Error(
      "APP_ID / INSTALLATION_ID / PRIVATE_KEY_PATH are required to issue " +
        "a token. Set them in gh-app/app.env."
    )
  }
  // IDs go into the request URL: digits only, so no URL structure can leak in.
  if (!/^\d+$/.test(installationId)) {
    throw new Error(
      `Invalid INSTALLATION_ID for token exchange: ${installationId}`
    )
  }
  if (keyPath.startsWith("~")) {
    keyPath = path.join(os.homedir(), keyPath.slice(1))
  }
  const now = Math.floor(Date.now() / 1000)
  const signingInput =
    b64url('{"alg":"RS256","typ":"JWT"}') +
    "." +
    b64url(JSON.stringify({ iat: now, exp: now + 540, iss: appId }))
  const key = fs.readFileSync(keyPath, "utf8")
  const signature = createSign("sha256").update(signingInput).sign(key)
  const jwt = `${signingInput}.${b64url(signature)}`
  // Only the short-lived signed JWT leaves this machine, and only to
  // api.github.com. The private key itself is never transmitted: it is
  // read locally purely to sign with.
  const res = await fetch(
    `https://api.github.com/app/installations/${installationId}/access_tokens`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${jwt}`,
        Accept: "application/vnd.github+json",
      },
    }
  )
  if (!res.ok) {
    throw new Error(`Token exchange failed (HTTP ${res.status}).`)
  }
  const data: unknown = await res.json()
  if (
    typeof data !== "object" ||
    data === null ||
    !("token" in data) ||
    typeof (data as { token: unknown }).token !== "string" ||
    !(data as { token: string }).token
  ) {
    throw new Error("Token exchange returned no token.")
  }
  const token = (data as { token: string }).token
  // The cache file is read back as a credential, so enforce the token
  // shape here: GitHub tokens are URL-safe without separators or spaces.
  if (!/^[A-Za-z0-9_.~-]+$/.test(token)) {
    throw new Error("Token exchange returned a malformed token.")
  }
  const expiresAt = (data as { expires_at?: unknown }).expires_at
  const expiresSec =
    typeof expiresAt === "string" && !Number.isNaN(Date.parse(expiresAt))
      ? Math.floor(Date.parse(expiresAt) / 1000) - 600
      : now + 3000
  fs.writeFileSync(cacheFile, `${expiresSec}|${token}`, "utf8")
  return token
}

const config = loadAppEnv()

let cachedToken: string | null = null
let cachedAt = 0
const TOKEN_TTL_MS = 50 * 60 * 1000

async function getInstallationToken(): Promise<string> {
  if (cachedToken && Date.now() - cachedAt < TOKEN_TTL_MS) {
    return cachedToken
  }
  const cached = readTokenCache(TOKEN_CACHE_FILE)
  if (cached) {
    return cached
  }
  const token = await fetchInstallationToken(config, TOKEN_CACHE_FILE)
  cachedToken = token
  cachedAt = Date.now()
  return token
}

/**
 * Extract a bash command string from tool args. Returns null when the
 * shape is anything else (never throws: unknown tools pass through).
 */
function parseBashCommand(args: unknown): string | null {
  if (typeof args !== "object" || args === null) {
    return null
  }
  const cmd = (args as { command?: unknown }).command
  return typeof cmd === "string" ? cmd : null
}

/**
 * True when a command line invokes `git commit` (the unsigned path under
 * the App identity). Other git subcommands are left alone.
 */
function isGitCommitCommand(cmd: string): boolean {
  return /(^|[;&|\n])\s*git(\.exe)?\s+(-C\s+\S+\s+)*commit\b/.test(cmd)
}

interface ShellIdentity {
  botName: string
  botEmail: string
  vcCmd: string
}

/**
 * `shell.env` hook body: publish the App identity to every shell the
 * session spawns. GH_TOKEN is best-effort (a missing key must not break
 * shell startup); the git identity below is always enforced.
 */
async function injectShellEnv(
  env: Record<string, string>,
  identity: ShellIdentity
): Promise<void> {
  const token = await getInstallationToken().catch(() => null)

  // GH_TOKEN: lets gh CLI / GitHub API calls run as the App.
  if (token) {
    env.GH_TOKEN = token
  }

  // GIT_CONFIG_*: force every git operation in this project to use the App identity.
  // Built from an array so KEY/VALUE indices and COUNT never drift apart.
  const helperSh = CREDENTIAL_HELPER_SH.replace(/\\/g, "/")
  const helperCmd = `!"${config.BASH_EXE}" "${helperSh}"`
  const gitConfig: Array<[string, string]> = [
    ["user.name", identity.botName],
    ["user.email", identity.botEmail],
    ["credential.helper", helperCmd],
    ["commit.gpgsign", "false"],
    ["alias.vc", identity.vcCmd],
  ]
  env.GIT_CONFIG_COUNT = String(gitConfig.length)
  gitConfig.forEach(([key, value], i) => {
    env[`GIT_CONFIG_KEY_${i}`] = key
    env[`GIT_CONFIG_VALUE_${i}`] = value
  })
}

/**
 * `tool.execute.before` hook body: `git commit` under the App identity is
 * always unsigned (commit.gpgsign is forced to false above) and fails
 * "Commits must have verified signatures" branch rules. Git aliases cannot
 * shadow the `commit` builtin, so block it here and point at the Verified
 * path instead. Throws to block, returns silently to allow.
 */
interface SeenModel {
  name: string
  variant: string
}

const seenModels = new Map<string, SeenModel>()
let latestSessionID = ""

/**
 * The driver creates a private file with mkdtemp and passes its path in
 * CONAHCNUJ_MODEL_LABEL_FILE. Only a path that path.resolve places inside
 * the temp directory is written, so an env path cannot escape that directory.
 */
function writeModelLabel(label: string): void {
  const requested = process.env.CONAHCNUJ_MODEL_LABEL_FILE
  if (!requested) {
    return
  }
  const root = path.resolve(os.tmpdir())
  const resolved = path.resolve(requested)
  const prefix = root.endsWith(path.sep) ? root : root + path.sep
  if (!resolved.startsWith(prefix)) {
    return
  }
  fs.writeFileSync(resolved, `${label}\n`, "utf8")
}

function oneLine(value: string): string {
  return value.replace(/[\r\n\t]+/g, " ").replace(/ {2,}/g, " ").trim()
}

/**
 * Display label for a commit trailer. Variant is the OpenCode effort
 * ("medium", ...), appended only when the name does not already include it.
 */
function formatModelLabel(name: string, variant: string): string {
  const base = oneLine(name)
  const effort = oneLine(variant)
  if (!base) {
    return ""
  }
  if (!effort || base.endsWith(`(${effort})`)) {
    return base
  }
  return `${base} (${effort})`
}

/**
 * True when this model is the session's selected one. Without
 * CONAHCNUJ_SESSION_MODEL every model is recorded (interactive OpenCode).
 * The driver sets provider/model so a side model (title, compaction) does
 * not replace the label of the model that did the work.
 */
function matchesSessionModel(providerID: string, modelID: string): boolean {
  const want = oneLine(process.env.CONAHCNUJ_SESSION_MODEL ?? "")
  if (!want) {
    return true
  }
  const slash = want.indexOf("/")
  if (slash < 0) {
    return want === modelID || want === `${providerID}/${modelID}`
  }
  return want === `${providerID}/${modelID}`
}

function rememberModel(
  sessionID: string,
  patch: { name?: string; variant?: string }
): void {
  const prev = seenModels.get(sessionID) ?? { name: "", variant: "" }
  const name =
    patch.name !== undefined && oneLine(patch.name) ? oneLine(patch.name) : prev.name
  const variant = patch.variant !== undefined ? oneLine(patch.variant) : prev.variant
  if (!name && !variant) {
    return
  }
  seenModels.set(sessionID, { name, variant })
  latestSessionID = sessionID
  const label = formatModelLabel(name, variant)
  if (!label) {
    return
  }
  try {
    writeModelLabel(label)
  } catch {
    // The driver falls back to the model id when the file cannot be written.
  }
}

function labelForSession(sessionID: string | undefined): string {
  const id = sessionID || latestSessionID
  const seen = id ? seenModels.get(id) : undefined
  if (!seen) {
    return ""
  }
  return formatModelLabel(seen.name, seen.variant)
}

function blockUnsignedCommit(
  tool: string,
  args: unknown,
  botName: string,
  vcUsage: string
): void {
  if (tool !== "bash") {
    return
  }
  const cmd = parseBashCommand(args)
  if (cmd !== null && isGitCommitCommand(cmd)) {
    throw new Error(
      `Do not use \`git commit\`: commits made as ${botName} are unsigned and blocked by "Commits must have verified signatures" rules. ` +
        `Create a Verified commit instead: ${vcUsage}`
    )
  }
}

export const GhAppTokenPlugin: Plugin = async () => {
  const botUserId = await resolveBotUserId(config.APP_SLUG)
  const botName = `${config.APP_SLUG}[bot]`
  const botEmail = `${botUserId}+${config.APP_SLUG}[bot]@users.noreply.github.com`
  const ghAppDir = GH_APP_DIR.replace(/\\/g, "/")
  const apiCommitSh = `${ghAppDir}/api-commit.sh`
  const bashExe = config.BASH_EXE.replace(/\\/g, "/")
  // `git vc` (verified-commit): commit staged changes, or `-a` for tracked.
  // owner/repo/branch are auto-detected, so it works in any repo.
  const vcCmd = `!"${bashExe}" "${apiCommitSh}"`
  const vcUsage = `git vc -m "<message>" [-a] (or: bash "${apiCommitSh}" -m "<message>" [-a])`

  return {
    "chat.message": async (input) => {
      const model = input.model
      if (model && !matchesSessionModel(model.providerID, model.modelID)) {
        return
      }
      // Keep a display name from chat.params. The id is only a stand-in
      // until that hook has supplied model.name.
      const prev = seenModels.get(input.sessionID)
      const name = model ? `${model.providerID}/${model.modelID}` : undefined
      rememberModel(input.sessionID, {
        ...(prev?.name ? {} : { name }),
        variant: input.variant,
      })
    },
    "chat.params": async (input) => {
      const model = input.model
      if (!matchesSessionModel(model.providerID, model.id)) {
        return
      }
      rememberModel(input.sessionID, {
        name: model.name || `${model.providerID}/${model.id}`,
      })
    },
    "shell.env": async (input, output) => {
      await injectShellEnv(output.env, { botName, botEmail, vcCmd })
      // An explicit label (the user, or a caller that already chose one) wins.
      if (!output.env.CONAHCNUJ_COMMIT_MODEL) {
        const label = labelForSession(input.sessionID)
        if (label) {
          output.env.CONAHCNUJ_COMMIT_MODEL = label
        }
      }
    },
    "tool.execute.before": async (input, output) => {
      blockUnsignedCommit(input.tool, output.args, botName, vcUsage)
    },
  }
}
