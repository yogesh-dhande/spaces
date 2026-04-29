import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";

export const metadata: Metadata = {
  title: "CLI Reference",
  description:
    "Reference for the minimal spaces command-line interface used by coding agents and terminal workflows.",
};

function CodeBlock({ children }: { children: string }) {
  return (
    <pre className="mt-3 overflow-x-auto rounded-xl border border-line bg-[#0f1820] px-4 py-3 font-mono text-xs leading-6 text-[#98efc7]">
      <code>{children}</code>
    </pre>
  );
}

function Cmd({ children }: { children: React.ReactNode }) {
  return (
    <code className="rounded bg-surface px-1.5 py-0.5 font-mono text-xs text-accent">
      {children}
    </code>
  );
}

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
      description="The spaces CLI is intentionally minimal. It exists for workspace import, workspace metadata updates, idempotent workspace launch, and explicit coding-agent lifecycle events."
      pagePath="/docs/cli"
    >
      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Overview</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Use <Cmd>spaces</Cmd> when you are already in a terminal or when a coding agent needs to register a workspace, update its visible metadata, make sure it is running, or report its lifecycle state back to Spaces.
        </p>
        <CodeBlock>{`spaces --version
spaces workspace import
spaces workspace update --tooltip "Ready for review"
spaces workspace up
spaces agent event --type waiting`}</CodeBlock>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Version</h2>
        <CodeBlock>{`spaces --version`}</CodeBlock>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Prints the installed Spaces CLI version.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Workspace Import</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Registers the current directory as a Spaces workspace by default. This is the normal bootstrap step for coding agents and terminal-first workflows.
        </p>
        <CodeBlock>{`# Import the current directory
spaces workspace import

# Import another directory
spaces workspace import /path/to/worktree

# Create or update visible metadata during import
spaces workspace import --title "OAuth rollout" --tooltip "Waiting on staging verification"`}</CodeBlock>
        <ul className="mt-3 space-y-1">
          <Flag name="[path]" description="Workspace directory to register. Defaults to the current working directory." />
          <Flag name="--title <title>" description="Optional workspace title. If the workspace already exists, the title is updated." />
          <Flag name="--tooltip <text>" description="Optional workspace tooltip. If the workspace already exists, the tooltip is updated." />
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Workspace Update</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          <Cmd>spaces workspace update</Cmd> changes workspace metadata after the workspace already exists. Use it for title or tooltip edits without relaunching anything.
        </p>
        <CodeBlock>{`# Update the current workspace tooltip
spaces workspace update --tooltip "Ready for review"

# Update another workspace
spaces workspace update /path/to/workspace --title "oauth-timeout" --tooltip "Waiting on staging verification"`}</CodeBlock>
        <ul className="mt-3 space-y-1">
          <Flag name="[path]" description="Workspace directory to update. Defaults to the current working directory." />
          <Flag name="--title <title>" description="Optional workspace title update." />
          <Flag name="--tooltip <text>" description="Optional workspace tooltip update." />
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Workspace Up</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          <Cmd>spaces workspace up</Cmd> is the idempotent runtime command. It launches a stopped workspace and restores exited runtime when the workspace is already running.
        </p>
        <CodeBlock>{`# Ensure the current workspace is running
spaces workspace up

# Target another workspace directory
spaces workspace up /path/to/workspace

# Force a full stop and relaunch
spaces workspace up /path/to/workspace --restart

# Launch and focus one named tracked window
spaces workspace up /path/to/workspace --focus frontend`}</CodeBlock>
        <ul className="mt-3 space-y-1">
          <Flag name="[path]" description="Workspace directory to launch. Defaults to the current working directory." />
          <Flag name="--restart" description="Always perform a full stop and fresh launch instead of the normal idempotent path." />
          <Flag name="--focus <name>" description="After launch, focus one tracked browser, process, or agent window by its unique workspace-local name." />
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Agent Events</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Coding agents report their lifecycle explicitly. Spaces uses these events to surface waiting and done states in the app and dashboard. This command records state only; it does not launch or stop an agent.
        </p>
        <CodeBlock>{`spaces agent event --type init
spaces agent event --type start
spaces agent event --type waiting
spaces agent event --type done
spaces agent event --type exit`}</CodeBlock>
        <ul className="mt-3 space-y-1">
          <Flag name="--type <event>" description="Required event type: init, start, waiting, done, or exit." />
          <Flag name="[path]" description="Workspace directory to associate with the event. Defaults to the current working directory." />
        </ul>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Spaces infers the terminal host automatically. If the current terminal host is not iTerm2 or Ghostty, Spaces drops the event instead of recording it.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Typical Flow</h2>
        <CodeBlock>{`spaces workspace import --title "bugfix/login-timeout"
spaces workspace up --restart
spaces workspace update --tooltip "Investigating flaky OAuth callback"
spaces agent event --type init
spaces agent event --type start
# ... later ...
spaces agent event --type waiting`}</CodeBlock>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          The GUI remains the primary place to create projects and configure templates. The CLI stays focused on registration, lightweight metadata updates, launch-time workflows, and agent reporting.
        </p>
      </article>
    </DocsShell>
  );
}
