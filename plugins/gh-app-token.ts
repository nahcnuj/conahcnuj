import type { Plugin } from "@opencode-ai/plugin"
import { execFileSync } from "node:child_process"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"

const GH_APP_DIR = path.join(__dirname, "..", "gh-app")
const GET_TOKEN_SH = path.join(GH_APP_DIR, "get-token.sh")
const CREDENTIAL_HELPER_SH = path.join(GH_APP_DIR, "git-credential-helper.sh")

// Only values with a usable default live here. Required values have no
// defaults at all: absence fails fast with a fix (see loadAppEnv).
const DEFAULT_CONFIG = {
  BASH_EXE: "C:/Program Files/Git/bin/bash.exe",
}
const REQUIRED_KEYS = ["APP_SLUG"] as const

type Config = typeof DEFAULT_CONFIG & {
  [K in (typeof REQUIRED_KEYS)[number]]: string
}

/**
 * Parse `KEY=VALUE` lines (dotenv flavor). Returns every pair found;
 * callers decide which keys to accept. Surrounding quotes are stripped
 * and a leading `${HOME}` is expanded.
 */
function parseAppEnv(text: string): Record<string, string> {
  const out: Record<string, string> = {}
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim()
    if (!line || line.startsWith("#") || !line.includes("=")) continue
    const idx = line.indexOf("=")
    const key = line.slice(0, idx).trim()
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
 * required-key validation. Unknown keys (e.g. APP_ID, only used by the
 * shell scripts) are ignored here.
 */
function loadAppEnv(): Config {
  const parsed: Record<string, string> =
    (() => {
      const envFile = fs.existsSync(path.join(GH_APP_DIR, "app.env"))
        ? path.join(GH_APP_DIR, "app.env")
        : path.join(GH_APP_DIR, "app.env.example")
      if (!fs.existsSync(envFile)) {
        return {}
      }
      return parseAppEnv(fs.readFileSync(envFile, "utf8"))
    })()
  const config: Record<string, string> = { ...DEFAULT_CONFIG }
  for (const key of [
    ...Object.keys(DEFAULT_CONFIG),
    ...(REQUIRED_KEYS as readonly string[]),
  ]) {
    if (parsed[key]) {
      config[key] = parsed[key]
    }
  }
  const missing = (REQUIRED_KEYS as readonly string[]).filter((k) => !config[k])
  if (missing.length > 0) {
    throw new Error(
      `Missing required gh-app config: ${missing.join(", ")}. ` +
        `Set them in gh-app/app.env (see app.env.example).`
    )
  }
  return config as Config
}

/**
 * Resolve the bot account user ID (`<slug>[bot]`) via the public GitHub
 * API (no auth needed). APP_ID is deliberately NOT a fallback: it is the
 * App's own ID and never attributes commits to the bot account.
 */
async function resolveBotUserId(slug: string): Promise<string> {
  const res = await fetch(
    `https://api.github.com/users/${slug}%5Bbot%5D`,
    { headers: { Accept: "application/vnd.github+json" } }
  )
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
    throw new Error(
      `Unexpected user lookup response for ${slug}[bot].`
    )
  }
  return String((data as { id: number }).id)
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

const config = loadAppEnv()

let cachedToken: string | null = null
let cachedAt = 0
const TOKEN_TTL_MS = 50 * 60 * 1000

async function getInstallationToken(): Promise<string> {
  if (cachedToken && Date.now() - cachedAt < TOKEN_TTL_MS) {
    return cachedToken
  }
  const token = execFileSync(config.BASH_EXE, [GET_TOKEN_SH], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "inherit"],
  }).trim()
  cachedToken = token
  cachedAt = Date.now()
  return token
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
    "shell.env": async (input, output) => {
      const token = await getInstallationToken().catch(() => null)

      // GH_TOKEN: lets gh CLI / GitHub API calls run as the App.
      if (token) {
        output.env.GH_TOKEN = token
      }

      // GIT_CONFIG_*: force every git operation in this project to use the App identity.
      // Built from an array so KEY/VALUE indices and COUNT never drift apart.
      const helperSh = CREDENTIAL_HELPER_SH.replace(/\\/g, "/")
      const helperCmd = `!"${config.BASH_EXE}" "${helperSh}"`
      const gitConfig: Array<[string, string]> = [
        ["user.name", botName],
        ["user.email", botEmail],
        ["credential.helper", helperCmd],
        ["commit.gpgsign", "false"],
        ["alias.vc", vcCmd],
      ]
      output.env.GIT_CONFIG_COUNT = String(gitConfig.length)
      gitConfig.forEach(([key, value], i) => {
        output.env[`GIT_CONFIG_KEY_${i}`] = key
        output.env[`GIT_CONFIG_VALUE_${i}`] = value
      })
    },
    "tool.execute.before": async (input, output) => {
      // `git commit` under the App identity is always unsigned (commit.gpgsign
      // is forced to false above) and fails "Commits must have verified
      // signatures" branch rules. Git aliases cannot shadow the `commit`
      // builtin, so block it here and point at the Verified path instead.
      if (input.tool === "bash") {
        const cmd = parseBashCommand(output.args)
        if (cmd !== null && isGitCommitCommand(cmd)) {
          throw new Error(
            `Do not use \`git commit\`: commits made as ${botName} are unsigned and blocked by "Commits must have verified signatures" rules. ` +
              `Create a Verified commit instead: ${vcUsage}`
          )
        }
      }
    },
  }
}
