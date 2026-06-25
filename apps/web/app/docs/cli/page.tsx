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
          Use <Cmd>spaces</Cmd> when automation needs to inspect projects or workspaces, create host-scoped workspaces, launch workspace runtime, report coding-agent lifecycle state, or control Spaces terminal sessions. To expose these actions to an MCP client such as Claude Code, see the <a className="text-accent hover:underline" href="/docs/mcp">Model Context Protocol</a> reference.
        </p>
        <CodeBlock>{`spaces --version
spaces project list
spaces workspace list
spaces workspace start --workspace <id>
spaces agent signal --workspace <id> --session <terminal-session-id> waiting`}</CodeBlock>
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
          <Cmd>spaces project list</Cmd> prints the projects in the active profile.
        </p>
        <CodeBlock>{`spaces project list`}</CodeBlock>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Workspaces</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Workspace commands list, create, start, and restart workspaces on the same-machine daemon.
        </p>
        <CodeBlock>{`spaces workspace list
spaces workspace list --project <project-id> --include-archived
spaces workspace create --project <project-id> --branch <branch>
spaces workspace start --workspace <workspace-id>
spaces workspace restart --workspace <workspace-id>`}</CodeBlock>
        <ul className="mt-3 space-y-1">
          <Flag name="--project <id>" description="Project ID for listing or workspace creation." />
          <Flag name="--branch <branch>" description="Workspace branch for creation." />
          <Flag name="--workspace <id>" description="Workspace ID for runtime commands." />
          <Flag name="--title <title>" description="Optional title for workspace creation." />
          <Flag name="--base-branch <branch>" description="Optional base branch for new branch creation." />
          <Flag name="--existing-branch" description="Use an existing branch instead of creating one." />
          <Flag name="--include-archived" description="Include archived workspaces in list output." />
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Terminals</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Terminal commands inspect and drive Spaces-owned terminal sessions on the same-machine daemon. Sessions survive app quit, so commands started here stay discoverable through <Cmd>spaces terminal list</Cmd>.
        </p>
        <CodeBlock>{`spaces terminal list
spaces terminal command --command "npm run dev" --cwd <path>
spaces terminal send <session-id> "echo hello" --newline
spaces terminal key <session-id> ctrl+c
spaces terminal tail <session-id> --lines 40
spaces terminal show <session-id>
spaces terminal takeover <session-id> <client-id>`}</CodeBlock>
        <ul className="mt-3 space-y-1">
          <Flag name="list" description="List available terminal sessions by ID, runtime state, and working directory." />
          <Flag name="command" description="Start a persistent background terminal session. Omit --command for a login shell." />
          <Flag name="send <session> <text>" description="Send text to a session. Add --newline to submit it." />
          <Flag name="key <session> <key>" description="Send a named key or chord such as enter, esc, up, ctrl+c, or cmd+k." />
          <Flag name="tail <session>" description="Print recent output. --lines defaults to 20." />
          <Flag name="show <session>" description="Open a native Spaces window for the session in owner-seeking mode (macOS)." />
          <Flag name="takeover <session> <client>" description="Transfer input ownership to another attached client." />
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Agent Signal</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Coding agents report their lifecycle explicitly for a workspace and terminal session. Spaces uses these events to surface waiting and done states in the app and Alerts. This command records state only; it does not launch or stop an agent.
        </p>
        <CodeBlock>{`spaces agent signal --workspace <workspace-id> --session <terminal-session-id> init
spaces agent signal --workspace <workspace-id> --session <terminal-session-id> start
spaces agent signal --workspace <workspace-id> --session <terminal-session-id> waiting
spaces agent signal --workspace <workspace-id> --session <terminal-session-id> done
spaces agent signal --workspace <workspace-id> --session <terminal-session-id> exit`}</CodeBlock>
        <ul className="mt-3 space-y-1">
          <Flag name="--workspace <id>" description="Workspace ID to associate with the event." />
          <Flag name="--session <id>" description="Spaces terminal session ID that owns the agent." />
          <Flag name="<event>" description="Required event type: init, start, waiting, done, or exit." />
        </ul>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Spaces records agent lifecycle events only for Spaces-managed terminal sessions. Use <code>init</code> to establish the agent row; later events update that row, or establish one when the terminal runtime identifies the session as a coding agent.
        </p>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Agent labels come from configured launcher names or the terminal runtime when it identifies known Codex, Claude Code, and opencode foreground commands.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Pairing</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          <Cmd>spaces pair</Cmd> opens a short-lived pairing window on the same-machine daemon and prints a <code>spaces://pair</code> link for connecting an iOS client from the terminal. Add <Cmd>--json</Cmd> for machine-readable output.
        </p>
        <CodeBlock>{`spaces pair
spaces pair --json`}</CodeBlock>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Typical Flow</h2>
        <CodeBlock>{`spaces project list
spaces workspace create --project <project-id> --branch bugfix/login-timeout
spaces workspace start --workspace <workspace-id>
spaces agent signal --workspace <workspace-id> --session <terminal-session-id> init
spaces agent signal --workspace <workspace-id> --session <terminal-session-id> start
# ... later ...
spaces agent signal --workspace <workspace-id> --session <terminal-session-id> waiting`}</CodeBlock>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          The GUI remains the primary place to configure templates and edit workspace details. The CLI stays focused on explicit profile, workspace, terminal, and agent automation.
        </p>
      </article>
    </DocsShell>
  );
}
