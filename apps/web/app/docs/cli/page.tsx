import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";

export const metadata: Metadata = {
  title: "CLI Reference",
  description:
    "Reference for the minimal mx command-line interface used by coding agents and terminal workflows.",
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
      description="The mx CLI is intentionally minimal. It exists for workspace import, idempotent workspace launch, and explicit coding-agent lifecycle events."
      pagePath="/docs/cli"
    >
      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Overview</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Use <Cmd>mx</Cmd> when you are already in a terminal or when a coding agent needs to register a workspace, make sure it is running, or report its lifecycle state back to Muxy.
        </p>
        <CodeBlock>{`mx --version
mx workspace import
mx workspace up
mx agent event --type waiting`}</CodeBlock>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Version</h2>
        <CodeBlock>{`mx --version`}</CodeBlock>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Prints the installed Muxy CLI version.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Workspace Import</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Registers the current directory as a Muxy workspace by default. This is the normal bootstrap step for coding agents and terminal-first workflows.
        </p>
        <CodeBlock>{`# Import the current directory
mx workspace import

# Import another directory
mx workspace import --dir /path/to/worktree

# Set or update visible metadata
mx workspace import --title "OAuth rollout" --tooltip "Waiting on staging verification"`}</CodeBlock>
        <ul className="mt-3 space-y-1">
          <Flag name="--dir <path>" description="Workspace directory to register. Defaults to the current working directory." />
          <Flag name="--title <title>" description="Optional workspace title. If the workspace already exists, the title is updated." />
          <Flag name="--tooltip <text>" description="Optional workspace tooltip. If the workspace already exists, the tooltip is updated." />
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Workspace Up</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          <Cmd>mx workspace up</Cmd> is the idempotent runtime command. It launches a stopped workspace and restores exited runtime when the workspace is already running.
        </p>
        <CodeBlock>{`# Ensure the current workspace is running
mx workspace up

# Target another workspace directory
mx workspace up --dir /path/to/workspace

# Force a full stop and relaunch
mx workspace up --dir /path/to/workspace --force-restart

# Launch and focus one named tracked window
mx workspace up --dir /path/to/workspace --focus frontend`}</CodeBlock>
        <ul className="mt-3 space-y-1">
          <Flag name="--dir <path>" description="Workspace directory to launch. Defaults to the current working directory." />
          <Flag name="--force-restart" description="Always perform a full stop and fresh launch instead of the normal idempotent path." />
          <Flag name="--focus <name>" description="After launch, focus one tracked browser, process, or agent window by its unique workspace-local name." />
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Agent Events</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Coding agents report their lifecycle explicitly. Muxy uses these events to surface waiting and done states in the app and dashboard.
        </p>
        <CodeBlock>{`mx agent event --type init
mx agent event --type start
mx agent event --type waiting
mx agent event --type done
mx agent event --type stop`}</CodeBlock>
        <ul className="mt-3 space-y-1">
          <Flag name="--type <event>" description="Required event type: init, start, waiting, done, or stop." />
          <Flag name="--dir <path>" description="Workspace directory to associate with the event. Defaults to the current working directory." />
          <Flag name="--provider iterm2|ghostty" description="Optional terminal host override when auto-detection is not enough." />
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Typical Flow</h2>
        <CodeBlock>{`mx workspace import --title "bugfix/login-timeout" --tooltip "Investigating flaky OAuth callback"
mx workspace up --force-restart
mx agent event --type start
# ... later ...
mx agent event --type waiting`}</CodeBlock>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          The GUI remains the primary place to create projects, configure templates, and adjust workspace settings. The CLI stays focused on launch-time workflows.
        </p>
      </article>
    </DocsShell>
  );
}
