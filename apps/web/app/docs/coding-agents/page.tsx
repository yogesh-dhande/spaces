import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";
import { CopyablePrompt } from "../components/copyable-prompt";

const spacesAgentSignalCommand = (event: string) =>
  `if [ -n "\${SPACES_WORKSPACE_ID:-}" ] && [ -n "\${SPACES_TERMINAL_TRACKING_ID:-}" ]; then spaces agent signal --workspace "$SPACES_WORKSPACE_ID" --session "$SPACES_TERMINAL_TRACKING_ID" ${event}; fi`;

const CLAUDE_PROMPT = `Add global Spaces lifecycle hooks to ~/.claude/settings.json so this agent
reports its state to Spaces.

  SessionStart      ->  ${spacesAgentSignalCommand("init")}
  UserPromptSubmit  ->  ${spacesAgentSignalCommand("working")}
  Stop              ->  ${spacesAgentSignalCommand("done")}
  PermissionRequest ->  ${spacesAgentSignalCommand("blocked")}
  SessionEnd        ->  ${spacesAgentSignalCommand("exit")}

Use an empty matcher ("") for every entry. Do not add or remove any
other keys. Keep the environment-variable guard in every command so
non-Spaces terminal sessions exit successfully without reporting an event.
After writing the file, show me the diff.`;

const CODEX_PROMPT = `Enable Codex hooks with [features].hooks in ~/.codex/config.toml and add global Spaces lifecycle hooks so this agent
reports its state to Spaces.

  SessionStart      ->  ${spacesAgentSignalCommand("init")}
  UserPromptSubmit  ->  ${spacesAgentSignalCommand("working")}
  Stop              ->  ${spacesAgentSignalCommand("done")}
  PermissionRequest ->  ${spacesAgentSignalCommand("blocked")}

Use an empty matcher ("") for every entry. Do not add or remove any
other keys. Keep the environment-variable guard in every command so
non-Spaces terminal sessions exit successfully without reporting an event.
After writing the file, show me the diff.
`;

export const metadata: Metadata = {
  title: "Coding Agents",
  description: "Track Claude Code, Codex, opencode, and other coding agents per workspace.",
};

export default function CodingAgentsDocsPage() {
  return (
    <DocsShell
      title="Coding Agents"
      description="Coding agents run alongside a workspace and report their lifecycle to Spaces, so you always know which one is waiting for you next."
      pagePath="/docs/coding-agents"
    >
      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">What Is a Coding Agent?</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          A coding agent is a tool like Claude Code, Codex, or opencode that you run in a terminal to help you write code. Spaces tracks each agent as a row in the workspace so you can focus its terminal by shortcut and see at a glance whether it is working, blocked on you, or done.
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Configure agents on the project as launchers — Spaces opens them for every workspace.</li>
          <li>• Or start one ad-hoc in any workspace terminal; Spaces will attach it to the workspace when it reports an event.</li>
          <li>• Rows render under <strong>Coding Agents</strong> in the workspace, after browser and process rows.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Lifecycle Events</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Agents report their own state through <code>spaces agent signal --workspace &lt;id&gt; --session &lt;terminal-session-id&gt; &lt;event&gt;</code>. Spaces uses each event to update the agent row. Both <code>blocked</code> and <code>done</code> raise Alerts and dock attention; <code>blocked</code> clears when the agent&apos;s state changes, while <code>done</code> stays in Alerts until you dismiss it.
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <strong>init</strong> &mdash; identify the terminal and attach it to a tracked row.</li>
          <li>• <strong>working</strong> &mdash; agent is working; row shows a spinner.</li>
          <li>• <strong>blocked</strong> &mdash; agent is blocked on you; row shows a warning and raises attention.</li>
          <li>• <strong>done</strong> &mdash; agent finished; row shows a green dot and raises attention until dismissed.</li>
          <li>• <strong>exit</strong> &mdash; agent ended; row returns to idle, or is removed if the terminal is gone.</li>
        </ul>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Events are accepted only from Spaces-managed terminal sessions. Start agents in a workspace terminal opened by Spaces so the session can be tracked and focused reliably. Events after <code>init</code> update the row that <code>init</code> created or attached; configured launcher metadata and known agent runtime metadata can also establish the row before the monitor tick runs.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Global Hooks</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Claude Code and Codex both support global hooks that run a shell command at lifecycle points. opencode exposes plugin events that can run shell commands. Point those integrations at guarded <code>spaces agent signal</code> commands once in your user config and Spaces-managed sessions report automatically without per-repo setup.
        </p>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          The easiest way to install the recommended Claude Code or Codex config is to paste one of the prompts below into the agent you want to configure. Both prompts preserve any existing hooks and only add the Spaces entries.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Setup Prompt for Claude Code</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Paste this into Claude Code from any directory. It edits <code>~/.claude/settings.json</code> and leaves unrelated settings untouched.
        </p>
        <CopyablePrompt label="Prompt for Claude Code" text={CLAUDE_PROMPT} />
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Setup Prompt for Codex</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Paste this into Codex from any directory. It edits <code>~/.codex/config.toml</code>, enabling hooks with <code>[features].hooks</code> and adding the lifecycle entries as inline <code>[hooks]</code> tables, and leaves unrelated settings untouched. Codex has no session-end event, so the Codex setup omits <code>exit</code>.
        </p>
        <CopyablePrompt label="Prompt for Codex" text={CODEX_PROMPT} />
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Configured vs. Ad-hoc</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <strong>Configured launchers</strong> live on the project and open automatically when the workspace launches. Their name is reserved — relaunching reuses the same row rather than creating a duplicate.</li>
          <li>• <strong>Ad-hoc agents</strong> are any Spaces-managed terminal session in which you run an agent yourself. Spaces creates a row the first time the agent reports an event. If an ad-hoc agent reports the same name as a configured launcher, Spaces auto-renames it with a numeric suffix.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">See Also</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <a className="text-accent hover:underline" href="/docs/cli">CLI Reference</a> — full flag list for <code>spaces agent signal</code>.</li>
          <li>• <a className="text-accent hover:underline" href="/docs/processes">Processes</a> — how agents launched as processes share the process runtime.</li>
          <li>• <a className="text-accent hover:underline" href="/docs/window-management">Window Management</a> — how tracked agent terminals become focusable by shortcut.</li>
        </ul>
      </article>
    </DocsShell>
  );
}
