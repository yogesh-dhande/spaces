import type { Metadata } from "next";
import { CodeBlock, Cmd } from "../components/code-block";
import { DocsShell } from "../components/docs-shell";

export const metadata: Metadata = {
  title: "CLI Reference",
  description:
    "Reference for the minimal spaces command-line interface used by coding agents and terminal workflows.",
};

function Flag({ name, description }: { name: string; description: string }) {
  return (
    <li className="flex flex-col gap-0.5 sm:flex-row sm:gap-3">
      <span className="w-56 shrink-0 font-mono text-xs text-accent">{name}</span>
      <span className="text-sm leading-6 text-foreground-soft">{description}</span>
    </li>
  );
}

export default function CliReferencePage() {
  return (
    <DocsShell
      title="CLI Reference"
      description="The spaces CLI is intentionally minimal. It exposes grouped project, workspace, agent, terminal, and MCP commands for automation and terminal workflows."
      pagePath="/docs/cli"
    >
      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Overview</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Use <Cmd>spaces</Cmd> when automation needs to inspect projects or workspaces, create host-scoped workspaces, launch workspace runtime, report coding-agent lifecycle state, or control Spaces terminal sessions. To expose these actions to an MCP client such as Claude Code, Codex, or opencode, see the <a className="text-accent hover:underline" href="/docs/mcp">Model Context Protocol</a> reference.
        </p>
        <CodeBlock>{`spaces --version
spaces project list
spaces workspace list
spaces workspace start --workspace <id>
spaces agent signal blocked`}</CodeBlock>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Version</h2>
        <CodeBlock>{`spaces --version`}</CodeBlock>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Prints the installed Spaces CLI version.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Projects</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          <Cmd>spaces project list</Cmd> prints the projects in the active profile, or on a paired device with <Cmd>--device</Cmd>.
        </p>
        <CodeBlock>{`spaces project list [--device <name-or-id>]`}</CodeBlock>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Workspaces</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Workspace commands list, create, start, and restart workspaces on the same-machine daemon, or on a paired device with <Cmd>--device</Cmd> so an orchestrator can discover and prepare work before spawning agents there. A remote listing reads the device overview, so it shows only active workspaces and <Cmd>--include-archived</Cmd> is not accepted with <Cmd>--device</Cmd>.
        </p>
        <CodeBlock>{`spaces workspace list [--project <project-id>] [--include-archived] [--device <name-or-id>]
spaces workspace create --project <project-id> --branch <branch> [--base-branch <branch>] [--existing-branch] [--device <name-or-id>]
spaces workspace start --workspace <workspace-id> [--device <name-or-id>]
spaces workspace restart --workspace <workspace-id> [--device <name-or-id>]`}</CodeBlock>
        <ul className="mt-3 space-y-1">
          <Flag name="--project <id>" description="Project filter for list; project ID for workspace creation." />
          <Flag name="--include-archived" description="Includes archived workspaces in list output. Not supported with --device." />
          <Flag name="--branch <branch>" description="Workspace branch for creation." />
          <Flag name="--base-branch <branch>" description="Base branch. Defaults to the project default branch, then main or master." />
          <Flag name="--existing-branch" description="Uses an existing branch instead of creating one." />
          <Flag name="--workspace <id>" description="Workspace ID for runtime commands." />
          <Flag name="--device <name-or-id>" description="Paired device selector for list, create, start, and restart. Defaults to this machine." />
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Terminals</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Terminal commands inspect and drive Spaces-owned terminal sessions on the same-machine daemon. Sessions survive app quit, so commands started here stay discoverable through <Cmd>spaces terminal list</Cmd>.
        </p>
        <CodeBlock>{`spaces terminal list [--device <name-or-id>]
spaces terminal command [--workspace <workspace-id>] [--command <cmd>] [--title <title>]
spaces terminal send text <session-id> <text> [--submit] [--device <name-or-id>]
spaces terminal send bytes <session-id> <byte> [<byte>...] [--device <name-or-id>]
spaces terminal tail <session-id> [--lines <count>] [--device <name-or-id>]
spaces terminal show <session-id>`}</CodeBlock>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Tail reconstructs rendered terminal output. For identified coding-agent sessions, it omits an inline suggestion at the cursor while preserving status lines, dialogs, menus, and real input. Ordinary terminal sessions preserve faint text at the cursor.
        </p>
        <ul className="mt-3 space-y-1">
          <Flag name="--device <name-or-id>" description="Paired device selector for list, send, and tail. Defaults to this machine's local sessions." />
          <Flag name="--workspace <id>" description="Workspace ID for terminal command; omit inside a workspace." />
          <Flag name="--command <cmd>" description="Shell command. Defaults to a login shell." />
          <Flag name="--title <title>" description="Session title. Defaults to shell." />
          <Flag name="--submit" description="Sends the text as a paste followed by a separate Enter keystroke so every supported agent TUI (Claude Code, Codex, OpenCode) submits the line instead of leaving it as an unsubmitted paste." />
          <Flag name="<byte>" description="Decimal byte value from 0 through 255." />
          <Flag name="--lines <count>" description="Number of lines to print. Defaults to 20." />
          <Flag name="show <session>" description="Opens a native Spaces window for the session in owner-seeking mode on macOS." />
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Agent Signal</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Coding agents report their lifecycle explicitly for a workspace and terminal session. Inside a Spaces-managed terminal, the command reads the workspace and terminal-session IDs from environment. Spaces uses these events to surface blocked and done states in the app and Alerts. This command records state only; it does not launch or stop an agent.
        </p>
        <CodeBlock>{`spaces agent signal init
spaces agent signal working
spaces agent signal blocked
spaces agent signal done
spaces agent signal exit`}</CodeBlock>
        <ul className="mt-3 space-y-1">
          <Flag name="--workspace <id>" description="Workspace ID to associate with the event. Defaults to SPACES_WORKSPACE_ID." />
          <Flag name="--session <id>" description="Spaces terminal session ID that owns the agent. Defaults to SPACES_TERMINAL_TRACKING_ID." />
          <Flag name="<event>" description="Required event type: init, working, blocked, done, or exit." />
        </ul>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Spaces records agent lifecycle events only for Spaces-managed terminal sessions. Outside one, <code>spaces agent signal</code> exits successfully without reporting an event. Passing <code>--workspace</code> without <code>--session</code>, or the reverse, is an error rather than a silent no-op. Use <code>init</code> to establish the agent row; later events update that row, or establish one when the terminal runtime identifies the session as a coding agent.
        </p>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Agent labels come from configured launcher names or the terminal runtime when it identifies known Codex, Claude Code, and opencode foreground commands.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Agent Orchestration</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Beyond reporting state, the CLI lets one terminal drive other coding agents. <Cmd>spaces agent list</Cmd> and <Cmd>spaces agent status</Cmd> show tracked agents (add <Cmd>--json</Cmd> for machine output); <Cmd>spaces agent annotate</Cmd> leaves a note. <Cmd>spaces agent spawn</Cmd> starts a supported agent (claude, codex, or opencode) in a new workspace terminal and blocks until Spaces detects it running — no hooks required. Spawn delivers no prompt: once it returns, send the first prompt with <Cmd>spaces terminal send</Cmd>. <Cmd>spaces agent subscribe</Cmd> watches a child and injects a clickable notice block into your terminal when it goes blocked, done, or exits. <Cmd>spaces agent kill</Cmd> ends a child and its terminal; it refuses a session that is not a coding agent. To steer a child, send it keystrokes with <Cmd>spaces terminal send</Cmd> — an agent&apos;s status still reflects only what the agent itself reports. Every command except <Cmd>signal</Cmd> accepts <Cmd>--device</Cmd> to target a paired device (remote spawn requires <Cmd>--workspace</Cmd>).
        </p>
        <CodeBlock>{`spaces agent list [--workspace <id>] [--json]
spaces agent status [--session <id>] [--json]
spaces agent annotate "waiting on review" [--session <id>]
spaces agent spawn --command claude [--workspace <id>] [--timeout <s>]
spaces agent subscribe <child-session> [--subscriber <id>] [--device <name>]
spaces agent unsubscribe <child-session> [--subscriber <id>] [--device <name>]
spaces agent kill <session>`}</CodeBlock>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Subscriptions can watch a child on this device or, with <Cmd>--device</Cmd>, on a paired one. Notices are delivered only while the subscriber is idle, so one never lands mid-task, and a subscription that would form a watch cycle is rejected. The same actions are available to an MCP client, but <code>spaces agent signal</code> is deliberately never an MCP tool.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Pairing</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          <Cmd>spaces device pair</Cmd> with no source opens a short-lived pairing window on the same-machine daemon and prints a <code>spaces://pair</code> link for connecting an iOS client from the terminal. Add <Cmd>--json</Cmd> for machine-readable output. Pass <Cmd>--link</Cmd> to redeem a link from another device, or <Cmd>--ssh user@host</Cmd> to pair with a remote daemon over SSH. Use <Cmd>--ssh-port</Cmd> for SSH ports other than 22.
        </p>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          On Ubuntu 24.04 devices, the Linux installer exposes the CLI at <Cmd>~/.local/bin/spaces</Cmd> for terminal use and keeps the managed helper at <Cmd>~/.spaces/bin/spaces</Cmd>.
        </p>
        <CodeBlock>{`spaces device pair [--json]
spaces device pair --ssh user@host [--ssh-port <port>]
spaces device pair --link <spaces-pair-link>
spaces device list
spaces device remove <name-or-id>`}</CodeBlock>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Typical Flow</h2>
        <CodeBlock>{`spaces project list
spaces workspace create --project <project-id> --branch bugfix/login-timeout
spaces workspace start --workspace <workspace-id>
spaces agent signal init
spaces agent signal working
# ... later ...
spaces agent signal blocked`}</CodeBlock>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          The GUI remains the primary place to configure templates and edit workspace details. The CLI stays focused on explicit profile, workspace, terminal, and agent automation.
        </p>
      </article>
    </DocsShell>
  );
}
