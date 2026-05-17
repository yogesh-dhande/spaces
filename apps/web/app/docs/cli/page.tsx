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
      description="The spaces CLI is intentionally minimal. It exists for `import`, `update`, `start`, `restart`, `open`, explicit coding-agent lifecycle events through `signal`, and low-level built-in terminal session control."
      pagePath="/docs/cli"
    >
      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Overview</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Use <Cmd>spaces</Cmd> when you are already in a terminal or when a coding agent needs to register a workspace, update its visible metadata, make sure it is running, or report its lifecycle state back to Spaces.
        </p>
        <CodeBlock>{`spaces --version
spaces import
spaces update --notes "Ready for review"
spaces start
spaces signal waiting`}</CodeBlock>
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
spaces import

# Import another directory
spaces import /path/to/worktree

# Create or update visible metadata during import
spaces import --title "OAuth rollout" --notes "Waiting on staging verification"`}</CodeBlock>
        <ul className="mt-3 space-y-1">
          <Flag name="[path]" description="Workspace directory to register. Defaults to the current working directory." />
          <Flag name="--title <title>" description="Optional workspace title. If the workspace already exists, the title is updated." />
          <Flag name="--notes <text>" description="Optional workspace notes. If the workspace already exists, the notes are updated." />
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Workspace Update</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          <Cmd>spaces update</Cmd> changes workspace metadata after the workspace already exists. Use it for title or notes edits without relaunching anything.
        </p>
        <CodeBlock>{`# Update the current workspace notes
spaces update --notes "Ready for review"

# Update another workspace
spaces update /path/to/workspace --title "oauth-timeout" --notes "Waiting on staging verification"`}</CodeBlock>
        <ul className="mt-3 space-y-1">
          <Flag name="[path]" description="Workspace directory to update. Defaults to the current working directory." />
          <Flag name="--title <title>" description="Optional workspace title update." />
          <Flag name="--notes <text>" description="Optional workspace notes update." />
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Start</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          <Cmd>spaces start</Cmd> is the idempotent runtime command. It launches a stopped workspace and restores exited runtime when the workspace is already running.
        </p>
        <CodeBlock>{`# Ensure the current workspace is running
spaces start

# Target another workspace directory
spaces start /path/to/workspace`}</CodeBlock>
        <ul className="mt-3 space-y-1">
          <Flag name="[path]" description="Workspace directory to launch. Defaults to the current working directory." />
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Restart</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          <Cmd>spaces restart</Cmd> performs the explicit full stop-and-relaunch flow. Use it when you want a clean runtime reset instead of the normal ensure-running behavior.
        </p>
        <CodeBlock>{`spaces restart
spaces restart /path/to/workspace`}</CodeBlock>
        <ul className="mt-3 space-y-1">
          <Flag name="[path]" description="Workspace directory to relaunch. Defaults to the current working directory." />
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Open</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          <Cmd>spaces open</Cmd> focuses one named tracked browser, process, or coding-agent target. The target name is required so the CLI never guesses which window you meant.
        </p>
        <CodeBlock>{`spaces open frontend
spaces open frontend /path/to/workspace`}</CodeBlock>
        <ul className="mt-3 space-y-1">
          <Flag name="<name>" description="Tracked browser, process, or coding-agent name to open or focus." />
          <Flag name="[path]" description="Workspace directory to resolve. Defaults to the current working directory." />
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Signal</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Coding agents report their lifecycle explicitly. Spaces uses these events to surface waiting and done states in the app and Alerts. This command records state only; it does not launch or stop an agent.
        </p>
        <CodeBlock>{`spaces signal init
spaces signal start
spaces signal waiting
spaces signal done
spaces signal exit`}</CodeBlock>
        <ul className="mt-3 space-y-1">
          <Flag name="<event>" description="Required event type: init, start, waiting, done, or exit." />
          <Flag name="[path]" description="Workspace directory to associate with the event. Defaults to the current working directory." />
        </ul>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Spaces records agent lifecycle events only from Spaces-managed terminal sessions. If the current shell is not running inside a tracked Spaces terminal session, Spaces drops the event instead of recording it.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Typical Flow</h2>
        <CodeBlock>{`spaces import --title "bugfix/login-timeout"
spaces restart
spaces update --notes "Investigating flaky OAuth callback"
spaces signal init
spaces signal start
# ... later ...
spaces signal waiting`}</CodeBlock>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          The GUI remains the primary place to create projects and configure templates. The CLI stays focused on registration, lightweight metadata updates, launch-time workflows, and agent reporting.
        </p>
      </article>
    </DocsShell>
  );
}
