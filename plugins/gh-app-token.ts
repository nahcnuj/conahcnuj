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
const BOT_NAME = `${config.APP_SLUG}[bot]`
const BOT_EMAIL = `${config.APP_ID}+${config.APP_SLUG}[bot]@users.noreply.github.com`

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
  return {
    "shell.env": async (input, output) => {
      const token = await getInstallationToken().catch(() => null)

      // GH_TOKEN: lets gh CLI / GitHub API calls run as the App.
      if (token) {
        output.env.GH_TOKEN = token
      }

      // GIT_CONFIG_*: force every git operation in this project to use the App identity.
      const helperSh = CREDENTIAL_HELPER_SH.replace(/\\/g, "/")
      const helperCmd = `!"${config.BASH_EXE}" "${helperSh}"`
      output.env.GIT_CONFIG_COUNT = "4"
      output.env.GIT_CONFIG_KEY_0 = "user.name"
      output.env.GIT_CONFIG_VALUE_0 = BOT_NAME
      output.env.GIT_CONFIG_KEY_1 = "user.email"
      output.env.GIT_CONFIG_VALUE_1 = BOT_EMAIL
      output.env.GIT_CONFIG_KEY_2 = "credential.helper"
      output.env.GIT_CONFIG_VALUE_2 = helperCmd
      output.env.GIT_CONFIG_KEY_3 = "commit.gpgsign"
      output.env.GIT_CONFIG_VALUE_3 = "false"
    },
  }
}