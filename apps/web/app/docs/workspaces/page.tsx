import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";

export const metadata: Metadata = {
  title: "Workspaces",
  description: "Workspace concepts, ports, env vars, and switching.",
};

export default function WorkspacesDocsPage() {
  return (
    <DocsShell
      title="Workspaces"
      description="A workspace is the core runtime unit in Spaces. It owns process templates, browser sessions, window tracking, and reserved ports."
      pagePath="/docs/workspaces"
    >
      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">What Is a Workspace?</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          A workspace is one stream of work — a feature, a bug fix, an experiment. It belongs to a project, has its own directory (a git worktree for Git projects), and keeps its own copy of the project&apos;s processes, browser sessions, and ports.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Creating a Workspace</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Open the New Workspace form from the <code>+</code> on any project or workspace row, or press <code>cmd+n</code>. For a Git project you&apos;ll fill in:
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <strong>Title</strong> &mdash; the display name in the sidebar.</li>
          <li>• <strong>Branch</strong> &mdash; pick an existing branch or enter a name to create a new one.</li>
          <li>• <strong>Target branch</strong> &mdash; the base for a new branch. Defaults to the project&apos;s default, falling back to <code>main</code> or <code>master</code>.</li>
          <li>• <strong>Directory name</strong> &mdash; the folder name for the worktree. Auto-generated, editable later.</li>
          <li>• <strong>Notes</strong> &mdash; optional context you can edit any time or ask a coding agent to keep in sync with the work.</li>
        </ul>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          For a non-Git project, the workspace uses the project directory itself and doesn&apos;t need a branch.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Per-Workspace Settings</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          A new workspace inherits the project&apos;s processes, browser sessions, and ports. From there, each workspace edits its own copy — the project&apos;s templates stay unchanged.
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Double-click the title, branch, or notes to rename them inline. <code>Escape</code> or click away to cancel.</li>
          <li>• Renaming the branch inline renames the underlying git branch.</li>
          <li>• Add, remove, or rename named ports per workspace.</li>
          <li>• Edit a process command while the workspace is running and Spaces restarts just that process.</li>
          <li>• Add a browser session and Spaces opens it right away if the workspace is already running.</li>
          <li>• The GUI is the place to edit workspace settings after creation. The CLI stays focused on import, launch, and agent events.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Named Ports</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Name the ports your project uses (for example <code>FRONTEND_PORT</code>, <code>API_PORT</code>) and Spaces gives each workspace its own port number behind those names. Two workspaces can run the same project at the same time without fighting over a port.
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Each named port is exposed as an environment variable to every workspace process, plus the setup and stop scripts.</li>
          <li>• Spaces reserves the port number while the workspace exists, so nothing else on your Mac can grab it.</li>
          <li>• Ports are released when the workspace is archived.</li>
        </ul>
        <pre className="mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-lg border border-line/70 bg-background-soft/60 p-3 text-xs leading-6 text-foreground">
          <code>{`Workspace: bugfix/login-timeout
FRONTEND_PORT=21001
API_PORT=21002`}</code>
        </pre>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Environment Variables</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Every workspace process, setup script, and stop script runs with:
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• The workspace&apos;s named ports (for example <code>FRONTEND_PORT=20001</code>, <code>API_PORT=20002</code>).</li>
          <li>• <code>SPACES_PROJECT_DIR</code> &mdash; the project directory.</li>
          <li>• <code>SPACES_WORKSPACE_DIR</code> &mdash; this workspace&apos;s directory.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Switching Between Workspaces</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Selecting another workspace swaps the whole context — its windows and processes all follow you.
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <code>cmd+alt+=</code> from anywhere brings Spaces forward; pick the workspace you want.</li>
          <li>• Inside Spaces, <code>cmd+alt+]</code> / <code>cmd+alt+[</code> step between workspaces.</li>
          <li>• <code>cmd+1</code> through <code>cmd+9</code> focus a specific window of the selected workspace.</li>
          <li>• Click any workspace in the sidebar or window row in the workspace run tab to jump directly.</li>
        </ul>
      </article>
    </DocsShell>
  );
}
