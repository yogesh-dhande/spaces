import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";
import { CopyablePrompt } from "../components/copyable-prompt";

// Keep in step with `AgentHookCommand.hookVersion`: hooks written without the current version read
// back in the app as out of date.
const HOOK_MARKER = "# spaces-agent-hook v1";

// Spaces embeds the absolute path it resolved for the CLI; `/usr/local/bin/spaces` stands in here.
const spacesAgentSignalCommand = (event: string) =>
  `'/usr/local/bin/spaces' agent signal ${event} >/dev/null 2>&1 || true ${HOOK_MARKER}`;

const CLAUDE_PROMPT = `Add global Spaces lifecycle hooks to ~/.claude/settings.json so this agent
reports its state to Spaces.

  SessionStart      ->  ${spacesAgentSignalCommand("init")}
  UserPromptSubmit  ->  ${spacesAgentSignalCommand("working")}
  Stop              ->  ${spacesAgentSignalCommand("done")}
  PermissionRequest ->  ${spacesAgentSignalCommand("blocked")}
  SessionEnd        ->  ${spacesAgentSignalCommand("exit")}

Use an empty matcher ("") for every entry. Do not add or remove any
other keys. Replace '/usr/local/bin/spaces' with the absolute path to my
spaces CLI. These hooks run quietly, ignore transient Spaces failures,
and keep the ${HOOK_MARKER} marker.
After writing the file, show me the diff.`;

const CODEX_PROMPT = `Enable Codex hooks with [features].hooks in ~/.codex/config.toml and add global Spaces lifecycle hooks so this agent
reports its state to Spaces.

  SessionStart      ->  ${spacesAgentSignalCommand("init")}
  UserPromptSubmit  ->  ${spacesAgentSignalCommand("working")}
  Stop              ->  ${spacesAgentSignalCommand("done")}
  PermissionRequest ->  ${spacesAgentSignalCommand("blocked")}

Use an empty matcher ("") for every entry. Do not add or remove any
other keys. Replace '/usr/local/bin/spaces' with the absolute path to my
spaces CLI. These hooks run quietly, ignore transient Spaces failures,
and keep the ${HOOK_MARKER} marker.
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
          <li>• Run one in any workspace terminal; Spaces attaches it to the workspace when it reports an event or its process is detected running.</li>
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
          Events are accepted only from Spaces-managed terminal sessions. Start agents in a workspace terminal opened by Spaces so the session can be tracked and focused reliably. Events after <code>init</code> update the row that <code>init</code> created or attached; a foreground process Spaces recognizes as a known agent can also establish the row before the monitor tick runs.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Setting Up Hooks</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Spaces sets these lifecycle hooks up for you, but never behind your back: it asks first. On first launch it offers to install <code>spaces agent signal</code> hooks for every supported agent CLI it detects — Claude Code in <code>~/.claude/settings.json</code>, Codex in <code>~/.codex/hooks.json</code>, and opencode as a plugin in <code>~/.config/opencode/plugin/</code>. You can skip that step and install later, or never. Each hook calls the Spaces CLI by the absolute path found when the hooks were installed, so it runs no matter what <code>PATH</code> your agent hands it; if you move or reinstall the CLI, reinstall the hooks from Settings &rarr; Coding Agents. The command only reports from Spaces-managed terminals and does nothing anywhere else, so nothing else in your setup changes.
        </p>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Installation preserves your existing hooks and settings and never duplicates an entry, so it is safe to run again. If a later Spaces release changes the hooks it installs, your agents show as out of date and Spaces offers to update them once — updating replaces the old hooks rather than adding to them.
        </p>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Agents install independently, so one that Spaces will not touch — a Codex <code>config.toml</code> that already defines <code>features</code> in a shape Spaces refuses to rewrite, say — does not stop the others. That agent&apos;s row explains what stopped it.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Managing Hooks in Settings</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Open <strong>Settings &rarr; Coding Agents</strong> to see, for This Mac or any paired remote, which supported agent CLIs are detected and whether their Spaces hooks are installed, out of date, or missing. Detected agents have an Install, Update, or Reinstall button; unsupported or missing CLIs remain visible without an install action.
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
        <h2 className="text-2xl font-semibold tracking-tight">Orchestrate Agents From One Terminal</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Once agents report their state, one agent — or you at a single terminal — can drive the others. <code>spaces agent list</code> and <code>spaces agent status</code> show every agent and whether it is working, blocked, or done, and <code>spaces agent annotate</code> leaves a short note on one so you remember what it was doing. Each row includes a clickable <code>spaces://terminal/&lt;id&gt;</code> link that jumps straight to that agent&apos;s pane.
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <strong>Start one that&apos;s ready.</strong> <code>spaces agent spawn --command claude</code> opens a supported agent (Claude Code, Codex, or opencode) in a new workspace terminal and waits until Spaces detects it running before returning — no hooks required. Spawn sends no prompt of its own; deliver the first prompt with <code>spaces terminal send</code> once it returns.</li>
          <li>• <strong>Get told when one needs you.</strong> <code>spaces agent subscribe</code> watches a child agent from your terminal; when it goes blocked, done, or exits, Spaces drops a single line into your terminal with a link to open it — only while you are idle, so it never lands mid-task.</li>
          <li>• <strong>Steer or stop it.</strong> <code>spaces terminal send</code> types into a child — a follow-up turn, an answer, or a keystroke such as Escape. What a key does is up to the agent&apos;s own interface, so a keystroke never changes what Spaces says the agent is doing; only the agent&apos;s own reports do. <code>spaces agent kill</code> ends it and its terminal outright.</li>
          <li>• <strong>Across devices.</strong> These commands take <code>--device</code> to drive agents on a paired Mac or Linux box, and the same actions are available to an MCP client such as Claude Code (agent lifecycle <em>signals</em> stay off the tool surface, so an agent can read another&apos;s state but never forge it).</li>
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
