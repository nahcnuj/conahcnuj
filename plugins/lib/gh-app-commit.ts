export const API_COMMIT_SCRIPT = "api-commit.sh"
const SHELL_NAMES = new Set(["bash", "sh", "zsh", "ksh", "dash"])
// Command launchers that hand their remaining argv to the wrapped command.
// A `sudo git commit` or `env ./api-commit.sh` must be caught like the bare
// form, so the launcher word (and its own option words) is skipped and the
// wrapped command inspected in its place.
const LAUNCHER_NAMES = new Set(["command", "env", "nohup", "sudo", "time"])
const SEPARATOR_CHARS_RE = /[;&|()\n]/
const ASSIGNMENT_RE = /^[A-Za-z_][A-Za-z0-9_]*=/
const SHELL_SCRIPT_FLAG_RE = /^-[a-zA-Z]*c[a-zA-Z]*$/
const GIT_OPTION_WITH_VALUE_RE = /^-[cC]$/

export function commandWords(cmd: string): string[][] {
  const segments: string[][] = []
  let words: string[] = []
  let word = ""
  let quote: '"' | "'" | null = null
  let quoted = false
  const endWord = () => {
    if (word || quoted) {
      words.push(word)
    }
    word = ""
    quoted = false
  }
  const endSegment = () => {
    endWord()
    if (words.length > 0) {
      segments.push(words)
    }
    words = []
  }
  for (const char of cmd) {
    if (quote) {
      if (char === quote) {
        quote = null
      } else {
        word += char
      }
      continue
    }
    if (char === '"' || char === "'") {
      quote = char
      quoted = true
      continue
    }
    if (SEPARATOR_CHARS_RE.test(char)) {
      endSegment()
      continue
    }
    if (/\s/.test(char)) {
      endWord()
      continue
    }
    word += char
  }
  endSegment()
  return segments
}

export function basename(token: string): string {
  const slash = Math.max(token.lastIndexOf("/"), token.lastIndexOf("\\"))
  return slash >= 0 ? token.slice(slash + 1) : token
}

export function* executedCommands(cmd: string): Generator<string[]> {
  for (const words of commandWords(cmd)) {
    let i = 0
    // Strip leading assignments and command launchers (sudo, env, nohup, ...):
    // a launcher hands its argv to the wrapped command, so `sudo git commit`
    // must block like the bare form. Repeating until stable lets
    // `env VAR=x sudo bash -c "git commit"` shed each layer in turn while
    // keeping the quoted script of a trailing `-c` intact for the shell
    // handling below.
    while (i < words.length) {
      if (ASSIGNMENT_RE.test(words[i])) {
        i += 1
        continue
      }
      if (LAUNCHER_NAMES.has(basename(words[i]).toLowerCase())) {
        i += 1
        while (i < words.length && words[i].startsWith("-")) {
          i += 1
        }
        continue
      }
      break
    }
    if (i >= words.length) {
      continue
    }
    if (!SHELL_NAMES.has(basename(words[i]).toLowerCase())) {
      yield words.slice(i)
      continue
    }
    let j = i + 1
    while (j < words.length && words[j].startsWith("-")) {
      if (SHELL_SCRIPT_FLAG_RE.test(words[j])) {
        const script = words[j + 1]
        if (script !== undefined) {
          yield* executedCommands(script)
        }
        j = words.length
        break
      }
      j += 1
    }
    if (j < words.length) {
      yield words.slice(j)
    }
  }
}

export function isGitCommitInvocation(words: string[]): boolean {
  const head = basename(words[0] ?? "").toLowerCase()
  if (head !== "git" && head !== "git.exe") {
    return false
  }
  let i = 1
  while (i < words.length && words[i].startsWith("-")) {
    i += GIT_OPTION_WITH_VALUE_RE.test(words[i]) ? 2 : 1
  }
  return /^commit(-|$)/.test(words[i] ?? "")
}

export function isGitCommitCommand(cmd: string): boolean {
  return [...executedCommands(cmd)].some(isGitCommitInvocation)
}

export function isDirectApiCommitCommand(cmd: string): boolean {
  return [...executedCommands(cmd)].some(
    (words) => basename(words[0] ?? "") === API_COMMIT_SCRIPT
  )
}
