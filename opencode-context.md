# opencode Context Reference

Always include this file's concepts when reasoning about opencode configuration and operations. This summarizes the key files, patterns, and behaviors.

## Configuration File precedence

opencode loads config from `~/.config/opencode/` on startup. Project-level `opencode.json` (walking up from cwd) is deep-merged with global config, project overrides global.

Known top-level keys (unknown keys cause `ConfigInvalidError`):

- `$schema` - JSON Schema URL (preserve this)
- `username`, `model`, `small_model`, `default_agent`
- `shell` - path to shell executable
- `logLevel` - DEBUG|INFO|WARN|ERROR
- `share` - manual|auto|disabled
- `autoupdate` - true|false|"notify"
- `snapshot` - true|false
- `instructions` - array of file paths walked up from cwd
- `skills` - `{ paths: [], urls: [] }`
- `references` - object keyed by alias (path/repo/shorthand)
- `agent` - object keyed by agent name
- `command` - object keyed by command name
- `provider` - object keyed by provider name
- `disabled_providers` - string array
- `enabled_providers` - string array
- `mcp` - object keyed by server name
- `plugin` - array of strings or `[name, options]` tuples
- `permission` - string or object keyed by tool name
- `formatter` - boolean
- `lsp` - boolean
- `experimental` - object

## Skills

- Scanned for `**/SKILL.md` inside `skills.paths` (relative/absolute) and `skills.urls`
- Each skill folder: `name` (required, lowercase hyphen-separated) + `description` (required) in `SKILL.md` frontmatter
- Optional: `license`, `compatibility`, `metadata` (string-string map)
- Skills without `description` are filtered out

## References

- Local `path` values: relative to config, absolute, or `~/`
- Git `repository` values: Git URLs, host/path, or GitHub `owner/repo` shorthand
- Both support optional `description` and `hidden` fields
- Only references with `description` are advertised in system context
- `hidden: true` removes from TUI `@` autocomplete only

## Agents

- File form: `.opencode/agent/<name>.md` or `.opencode/agents/<name>.md`
- Frontmatter fields: `description`, `mode` ("primary"/"subagent"/"all"), `model`, `variant`, `hidden`, `color`, `steps`, `options`, `permission`, `disable`, `temperature`, `top_p`
- Inline (in `opencode.json`): `agent: { <name>: { ... } }`
- `mode` is one of `"primary"`, `"subagent"`, `"all"`
- `default_agent` must point to a non-hidden, primary-mode agent
- Built-in: `build`, `plan`, `general`, `explore`. Hidden internal: `compaction`, `title`, `summary`

## Commands

- File form: `.opencode/command/<name>.md` or `.opencode/commands/<name>.md`
- Frontmatter: `description`, `agent`, `model`, `variant`, `subtask`
- `template` (body below frontmatter) is required
- Positional args replace `現在のシェルが何か...` placeholder

## Permissions

- Actions: `"allow"`, `"ask"`, `"deny"`
- Per-tool: `"allow"` shorthand = `{"*": "allow"}`, or `{ pattern: action }`
- **Insertion order matters**: opencode evaluates the LAST matching rule
- Top-level `permission: "allow"` = allow everything (rarely desired)
- Per-agent `permission:` overrides top-level
- Plan mode lives on `plan` agent's permission ruleset (`edit: deny *`)

## MCP servers

- `mcp[name].command` is always an array of strings (never single string)
- `type` is required: `"local"` or `"remote"`
- `enabled: false` disables a server inherited from parent config
- `environment` sets env vars for local MCP servers
- String values support `{env:VAR}` and `{file:path}` interpolation

## Escape hatches (env vars at startup)

- `OPENCODE_DISABLE_PROJECT_CONFIG=1`: skip project config, globals only
- `OPENCODE_CONFIG=/path/to/file.json`: load additional explicit config
- `OPENCODE_CONFIG_CONTENT='{"$schema":"https://opencode.ai/config.json"}'`: inline JSON merge
- `OPENCODE_DISABLE_DEFAULT_PLUGINS=1`: skip default plugins
- `OPENCODE_PURE=1`: skip external plugins entirely
- `OPENCODE_DISABLE_EXTERNAL_SKILLS=1`: skip `~/.claude/` and `~/.agents/` skills

## When proposing edits

- Validate against `https://opencode.ai/config.json` before writing
- Preserve `$schema` and existing fields not being changed
- Prefer creating new files in correct location over inlining in `opencode.json`
- If config is broken, use env-var escape hatches to edit from within opencode
- After saving config changes, **quit and restart opencode** for changes to take effect

## Shell awareness

Before constructing any bash/PowerShell command, always check what shell the user's current session is using:

- **PowerShell 5.1** (Windows default): Use `powershell -Command "..."` or `& "path/to/script.ps1"`. Commands chain with `; if ($?) { ... }`. Prefer full cmdlet names.
- **Git Bash** (WSL or MSGit): Use `bash -c "..."` or direct bash commands. Note WSL bash at `/usr/bin/bash` may differ from Git Bash at `C:/Program Files/Git/bin/bash.exe`.
- **Zsh**: Use `zsh -c "..."`

**Key practice**: When running scripts via the bash tool, always use the `BASH_EXE` environment variable (`C:/Program Files/Git/bin/bash.exe`) rather than assuming WSL bash. Shell scripts in `gh-app/` follow this convention: variable expansion uses `${var}` (braced) form, not `$var`.

For dependent commands, use PowerShell conditionals `cmd1; if ($?) { cmd2 }` rather than `&&`, or bash `cmd1 && cmd2`. Always confirm with the user before executing commands that modify their system (git operations, file deletions, etc.).