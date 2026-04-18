import type { Metadata } from "next";
import { ScreenshotFrame } from "../../components/screenshot-frame";
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
        <h2 className="text-2xl font-semibold tracking-tight">Lifecycle States</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <strong>Default</strong>: auto-created per project and cannot be archived.</li>
          <li>• <strong>Stopped</strong>: persisted workspace with no active processes or tracked windows.</li>
          <li>• <strong>Running</strong>: processes and windows tracked and available for switching.</li>
          <li>• <strong>Archived</strong>: hidden from normal lists; worktree removed for Git projects.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Create</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Creating a workspace copies project templates into workspace settings, runs the setup
          script, and reserves ports based on port definitions.
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Git projects create a worktree directory for the workspace.</li>
          <li>• Branch creation uses this precedence: local branch, then remote branch, then new branch from target.</li>
          <li>• A branch is required for Git workspaces.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Launch</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Launch is allowed only when a workspace is stopped. If the workspace is already
          running, use restart instead.
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Starts workspace processes in iTerm2 (one tab/session per process in a shared window when possible).</li>
          <li>• Opens browser sessions and tracks matching Chrome tabs by URL prefix.</li>
          <li>• Captures workspace windows so they can be focused later by shortcut.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Update While Running</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Newly added processes start immediately in new terminal windows.</li>
          <li>• Process command changes restart the process in the same terminal window.</li>
          <li>• Newly added browser session URLs open immediately.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Stop and Restart</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Restart runs stop first, then launch, for the same workspace.
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Processes are gracefully interrupted, then terminated if needed.</li>
          <li>• The stop script runs after process termination (if configured).</li>
          <li>• Tracked workspace windows are closed (terminals and browsers).</li>
        </ul>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Use <code>mx workspace up</code> for idempotent automation: it launches stopped workspaces and,
          when already running, restarts exited processes by default. Add <code>--force-restart</code> to
          force stop then launch when runtime state is already present.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Archive</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• The default workspace cannot be archived.</li>
          <li>• Archive runs the same stop flow as stop/restart.</li>
          <li>• For Git projects, the worktree directory is removed but branches are kept.</li>
          <li>• For non-Git projects, the project directory is never deleted.</li>
          <li>• Reserved ports are released on archive.</li>
        </ul>
      </article>

      <article className="grid gap-4 border-t border-line/70 pt-8 first:border-t-0 first:pt-0 md:grid-cols-2">
        <ScreenshotFrame
          title="Workspace Action Bar"
          caption="Launch/Restart/Stop/Archive controls with state-aware availability."
        />
        <ScreenshotFrame
          title="Workspace Tabs"
          caption="Run, Env, and Settings tabs tied to the selected workspace."
        />
      </article>
    </DocsShell>
  );
}
