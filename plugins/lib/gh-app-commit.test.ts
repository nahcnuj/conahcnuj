import {
  API_COMMIT_SCRIPT,
  basename,
  commandWords,
  executedCommands,
  isDirectApiCommitCommand,
  isGitCommitCommand,
  isGitCommitInvocation,
} from "./gh-app-commit"

function assertEqual(actual: unknown, expected: unknown, msg?: string): void {
  if (actual !== expected) {
    throw new Error(msg ?? `expected ${expected} but got ${actual}`)
  }
}

function assertDeepEqual(actual: unknown, expected: unknown, msg?: string): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) {
    throw new Error(msg ?? `expected ${e} but got ${a}`)
  }
}

function collect<T>(gen: Generator<T>): T[] {
  const out: T[] = []
  for (const v of gen) {
    out.push(v)
  }
  return out
}

function testCommandWords() {
  assertDeepEqual(commandWords("git commit -m x"), [["git", "commit", "-m", "x"]])
  assertDeepEqual(commandWords("git commit -m \"hello world\""), [
    ["git", "commit", "-m", "hello world"],
  ])
  assertDeepEqual(commandWords("git commit -m 'hi' && git push"), [
    ["git", "commit", "-m", "hi"],
    ["git", "push"],
  ])
  assertDeepEqual(commandWords("FOO=bar git commit"), [["FOO=bar", "git", "commit"]])
  assertDeepEqual(commandWords("bash -c \"git commit -m x\""), [
    ["bash", "-c", "git commit -m x"],
  ])
}

function testBasename() {
  assertEqual(basename("git"), "git")
  assertEqual(basename("/usr/bin/git"), "git")
  assertEqual(basename("C:\\Program Files\\Git\\bin\\git.exe"), "git.exe")
  assertEqual(basename("api-commit.sh"), "api-commit.sh")
}

function testIsGitCommitInvocation() {
  assertEqual(isGitCommitInvocation(["git", "commit"]), true)
  assertEqual(isGitCommitInvocation(["git", "commit", "-m", "x"]), true)
  assertEqual(isGitCommitInvocation(["git.exe", "commit"]), true)
  assertEqual(isGitCommitInvocation(["git", "-C", "repo", "commit"]), true)
  assertEqual(isGitCommitInvocation(["git", "-c", "user.name=x", "commit"]), true)
  assertEqual(isGitCommitInvocation(["git", "commit-tree"]), true)
  assertEqual(isGitCommitInvocation(["git", "push"]), false)
}

function testIsGitCommitCommand() {
  assertEqual(isGitCommitCommand("git commit -m x"), true)
  assertEqual(isGitCommitCommand("git commit --amend"), true)
  assertEqual(isGitCommitCommand("bash -c 'git commit -m x'"), true)
  assertEqual(isGitCommitCommand("cat api-commit.sh | bash"), false)
  assertEqual(isGitCommitCommand('bash "/tmp/api-commit.sh"'), false)
  assertEqual(isGitCommitCommand("FOO=bar bash -lc \"git commit -m hi\""), true)
}

function testIsDirectApiCommitCommand() {
  assertEqual(isDirectApiCommitCommand("api-commit.sh"), true)
  assertEqual(isDirectApiCommitCommand("./api-commit.sh"), true)
  assertEqual(isDirectApiCommitCommand("/path/to/api-commit.sh"), true)
  assertEqual(isDirectApiCommitCommand("bash api-commit.sh"), true)
  assertEqual(isDirectApiCommitCommand('bash "/x/api-commit.sh"'), true)
  assertEqual(isDirectApiCommitCommand("cat api-commit.sh"), false)
}

function testExecutedCommands() {
  assertDeepEqual(collect(executedCommands("git commit -m x")), [["git", "commit", "-m", "x"]])
  assertDeepEqual(collect(executedCommands("bash -c \"git commit\"")), [["git", "commit"]])
  assertDeepEqual(collect(executedCommands("VAR=a bash api-commit.sh")), [["api-commit.sh"]])
}

const tests = [
  testCommandWords,
  testBasename,
  testIsGitCommitInvocation,
  testIsGitCommitCommand,
  testIsDirectApiCommitCommand,
  testExecutedCommands,
]

let failed = 0
for (const t of tests) {
  try {
    t()
    console.log(`ok - ${t.name}`)
  } catch (e) {
    failed++
    console.error(`not ok - ${t.name}: ${(e as Error).message}`)
  }
}
if (failed > 0) {
  process.exit(1)
}
