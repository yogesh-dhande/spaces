import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";

export const metadata: Metadata = {
  title: "Workspace Lifecycle",
  description: "How workspace state changes from create to archive.",
};

export default function WorkspaceLifecycleDocsPage() {
  return (
    <DocsShell
      title="Workspace Lifecycle"
      description="How workspace state changes from create through launch, stop, restart, and archive."
      pagePath="/docs/workspace-lifecycle"
    >
      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">States</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <strong>Stopped</strong> &mdash; the workspace exists but nothing is running.</li>
          <li>• <strong>Running</strong> &mdash; Spaces has started its processes. Browser sessions stay configured but open on demand when you focus them.</li>
          <li>• <strong>Archived</strong> &mdash; hidden from the sidebar. For Git projects the worktree is removed; for non-Git projects the project directory is left alone. The default workspace can&apos;t be archived.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Create</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          On create, Spaces copies the project&apos;s templates into the workspace, reserves its named ports, and runs the setup script. Git projects also get a branch worktree. If you named a branch that doesn&apos;t exist yet, Spaces creates it from the target branch.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Launch</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Launching a stopped workspace:
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Starts each configured process with tmux and attaches to it in its own terminal window (Ghostty or iTerm2, per your setting).</li>
          <li>• Leaves browser sessions unopened until you explicitly focus them.</li>
          <li>• Remembers those windows so you can jump back to any of them by keyboard shortcuts.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Update While Running</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Add a process &mdash; Spaces starts it right away in a new terminal window.</li>
          <li>• Edit a process command &mdash; Spaces restarts just that process.</li>
          <li>• Add a browser session &mdash; Spaces opens it in Chrome immediately.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Stop and Restart</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Stop gracefully interrupts each process, then escalates if needed.</li>
          <li>• Spaces closes the terminal and browser windows it opened for the workspace.</li>
          <li>• The stop script runs after the processes are down.</li>
          <li>• Restart is stop followed by launch.</li>
        </ul>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          For scripts and coding agents, <code>spaces start</code> is the idempotent way to make sure a workspace is running: it launches when stopped and restarts any exited processes when already running. Use <code>spaces restart</code> to stop and relaunch unconditionally, or <code>spaces open &lt;name&gt;</code> to foreground one named tracked window directly.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Archive</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Archive stops the workspace, releases its named ports, and hides it from the sidebar. For Git projects the worktree directory is removed; the branch itself is kept. The default workspace can&apos;t be archived.
        </p>
      </article>
    </DocsShell>
  );
}
