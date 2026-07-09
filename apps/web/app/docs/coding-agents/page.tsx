import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";
import { CopyablePrompt } from "../components/copyable-prompt";

// Spaces embeds the absolute path it resolved for the CLI; `/usr/local/bin/spaces` stands in here.
const spacesAgentSignalCommand = (event: string) =>
  `'/usr/local/bin/spaces' agent signal ${event} >/dev/null 2>&1 || true # spaces-agent-hook`;

const CLAUDE_PROMPT = `Add global Spaces lifecycle hooks to ~/.claude/settings.json so this agent
reports its state to Spaces.

  SessionStart      ->  ${spacesAgentSignalCommand("init")}
  UserPromptSubmit  ->  ${spacesAgentSignalCommand("working")}
  Stop              ->  ${spacesAgentSignalCommand("done")}
  PermissionRequest ->  ${spacesAgentSignalCommand("blocked")}
  SessionEnd        ->  ${spacesAgentSignalCommand("exit")}

Use an empty matcher ("") for every entry. Do not add or remove any
other keys. These hooks assume spaces is available on PATH, run quietly,
ignore transient Spaces failures, and keep the # spaces-agent-hook marker.
After writing the file, show me the diff.`;

const CODEX_PROMPT = `Enable Codex hooks with [features].hooks in ~/.codex/config.toml and add global Spaces lifecycle hooks so this agent
reports its state to Spaces.

  SessionStart      ->  ${spacesAgentSignalCommand("init")}
  UserPromptSubmit  ->  ${spacesAgentSignalCommand("working")}
  Stop              ->  ${spacesAgentSignalCommand("done")}
  PermissionRequest ->  ${spacesAgentSignalCommand("blocked")}

Use an empty matcher ("") for every entry. Do not add or remove any
other keys. These hooks assume spaces is available on PATH, run quietly,
ignore transient Spaces failures, and keep the # spaces-agent-hook marker.
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
          Agents report their own state through <code>spaces agent signal &lt;event&gt;</code>. In a Spaces-managed terminal, the command reads the workspace and session from environment; outside one, it exits successfully without reporting an event. Spaces uses each event to update the agent row. Both <code>blocked</code> and <code>done</code> raise Alerts and dock attention; <code>blocked</code> clears when the agent&apos;s state changes, while <code>done</code> stays in Alerts until you dismiss it.
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
        <h2 className="text-2xl font-semibold tracking-tight">Hooks Install Themselves</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Spaces wires these lifecycle hooks up for you. When you install Spaces, and whenever you connect a device, Spaces installs <code>spaces agent signal</code> hooks for every supported agent CLI it detects — Claude Code in <code>~/.claude/settings.json</code>, Codex in <code>~/.codex/hooks.json</code>, and opencode as a plugin in <code>~/.config/opencode/plugin/</code>. Each hook calls the Spaces CLI by the absolute path found when the hooks were installed, so it runs no matter what <code>PATH</code> your agent hands it; if you move or reinstall the CLI, reinstall the hooks from Settings &rarr; Coding Agents. The command only reports from Spaces-managed terminals and does nothing anywhere else, so nothing else in your setup changes.
        </p>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Installation preserves your existing hooks and settings and never duplicates an entry, so it is safe to run again. It happens once per device and agent: if you remove a Spaces hook it stays removed, and a detected agent without Spaces hooks is picked up the next time that device connects.
        </p>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Agents install independently, so one that Spaces will not touch — a Codex <code>config.toml</code> that already defines <code>features</code> in a shape Spaces refuses to rewrite, say — does not stop the others. That agent&apos;s row in Settings explains what stopped it, and Spaces tries again the next time the device connects.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Managing Hooks in Settings</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Open <strong>Settings &rarr; Coding Agents</strong> to see, for This Mac or any paired remote, which supported agent CLIs are detected and whether their Spaces hooks are installed. Detected agents have an Install or Reinstall button; unsupported or missing CLIs remain visible without an install action.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Manual Setup</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          You normally never need this — Spaces installs and manages the hooks for you. If you want to configure an agent by hand, paste one of these prompts into it. Both preserve any existing hooks and only add the Spaces entries. Claude Code edits <code>~/.claude/settings.json</code>; Codex edits <code>~/.codex/config.toml</code> to enable hooks and adds the lifecycle entries. Codex has no session-end event, so its setup omits <code>exit</code>.
        </p>
        <div className="mt-4 space-y-4">
          <CopyablePrompt label="Prompt for Claude Code" text={CLAUDE_PROMPT} />
          <CopyablePrompt label="Prompt for Codex" text={CODEX_PROMPT} />
        </div>
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
