import type { Plugin } from "@opencode-ai/plugin"
import { execFileSync } from "node:child_process"
import fs from "node:fs"
import os from "node:os"
import path from "node:path"

const GH_APP_DIR = path.join(__dirname, "..", "gh-app")
const GET_TOKEN_SH = path.join(GH_APP_DIR, "get-token.sh")
const CREDENTIAL_HELPER_SH = path.join(GH_APP_DIR, "git-credential-helper.sh")

const DEFAULT_CONFIG = {
  APP_ID: "",
  BOT_USER_ID: "",
  APP_SLUG: "",
  BASH_EXE: "C:/Program Files/Git/bin/bash.exe",
}

function loadAppEnv(): typeof DEFAULT_CONFIG {
  const config = { ...DEFAULT_CONFIG }
  const envFile = fs.existsSync(path.join(GH_APP_DIR, "app.env"))
    ? path.join(GH_APP_DIR, "app.env")
    : path.join(GH_APP_DIR, "app.env.example")
  if (!fs.existsSync(envFile)) {
    return config
  }
  for (const raw of fs.readFileSync(envFile, "utf8").split(/\r?\n/)) {
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
    if (key in config) {
      ;(config as Record<string, string>)[key] = value
    }
  }
  return config
}

const config = loadAppEnv()
const BOT_USER_ID_SH = path.join(GH_APP_DIR, "bot-user-id.sh")
function resolveBotUserId(): string {
  const raw = config.BOT_USER_ID
  if (raw && !raw.startsWith("<")) {
    return raw
  }
  // Not set (or left as a placeholder): auto-resolve from the public API.
  // APP_ID (the GitHub App's ID, used for JWT `iss`) never attributes commits
  // to the bot account, so it is deliberately NOT used as a fallback.
  try {
    const out = execFileSync(config.BASH_EXE, [BOT_USER_ID_SH], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "inherit"],
    }).trim()
    if (/^\d+$/.test(out)) {
      return out
    }
  } catch {
    // fall through to the actionable error below (e.g. offline)
  }
  throw new Error(
    "BOT_USER_ID is not set and auto-resolve failed. Set it to the bot " +
      "account user ID (`gh api users/<slug>%5Bbot%5D --jq .id`), not APP_ID."
  )
}
config.BOT_USER_ID = resolveBotUserId()
const BOT_NAME = `${config.APP_SLUG}[bot]`
const BOT_EMAIL = `${config.BOT_USER_ID}+${config.APP_SLUG}[bot]@users.noreply.github.com`

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
  const ghAppDir = GH_APP_DIR.replace(/\\/g, "/")
  const apiCommitSh = `${ghAppDir}/api-commit.sh`
  const bashExe = config.BASH_EXE.replace(/\\/g, "/")
  // `git vc` (verified-commit): one-line Verified commit of the whole worktree.
  // owner/repo/branch are auto-detected from git remote + HEAD, so it works
  // in any repo: `git vc -m "msg" --all`
  const vcCmd = `!"${bashExe}" "${apiCommitSh}"`
  const vcUsage = `git vc -m "<message>" --all (or: bash "${apiCommitSh}" -m "<message>" --all)`

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
        ["user.name", BOT_NAME],
        ["user.email", BOT_EMAIL],
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
        const args = output.args as { command?: unknown }
        const cmd = typeof args.command === "string" ? args.command : ""
        if (/(^|[;&|\n])\s*git(\.exe)?\s+(-C\s+\S+\s+)*commit\b/.test(cmd)) {
          throw new Error(
            `Do not use \`git commit\`: commits made as ${BOT_NAME} are unsigned and blocked by "Commits must have verified signatures" rules. ` +
              `Create a Verified commit instead: ${vcUsage}`
          )
        }
      }
    },
  }
}