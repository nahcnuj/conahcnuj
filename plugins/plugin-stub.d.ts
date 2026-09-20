// Minimal offline type surface for the opencode-specific module
// (npm install only provides @types/node + typescript; see package.json).
// Covers only what plugins/gh-app-token.ts uses: Plugin, hook input/output.
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
