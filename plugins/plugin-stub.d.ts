// Minimal offline type surface for CI typechecking (no npm install).
// Covers only what plugins/gh-app-token.ts uses: Plugin, hook input/output.
declare const __dirname: string;

declare module "node:child_process" {
  export function execFileSync(
    file: string,
    args: readonly string[],
    options: Record<string, unknown>
  ): string;
}

declare module "node:fs" {
  export function existsSync(path: string): boolean;
  export function readFileSync(path: string, encoding: string): string;
  const _default: {
    existsSync(path: string): boolean;
    readFileSync(path: string, encoding: string): string;
  };
  export default _default;
}

declare module "node:os" {
  export function homedir(): string;
  const _default: {
    homedir(): string;
  };
  export default _default;
}

declare module "node:path" {
  export function join(...parts: string[]): string;
  const _default: {
    join(...parts: string[]): string;
  };
  export default _default;
}

declare module "@opencode-ai/plugin" {
  export interface HookInput {
    tool: string;
    cwd: string;
  }
  export interface HookOutput {
    args: unknown;
    env: Record<string, string>;
  }
  export type Hook = (
    input: HookInput,
    output: HookOutput
  ) => void | Promise<void>;
  export interface PluginContext {
    project: unknown;
    client: unknown;
    $: unknown;
    directory: string;
    worktree: string;
  }
  export type Plugin = (
    ctx: PluginContext
  ) => Promise<Record<string, Hook>> | Record<string, Hook>;
}
