import type { Metadata } from "next";
import { ScreenshotFrame } from "../../components/screenshot-frame";
import { DocsShell } from "../components/docs-shell";

export const metadata: Metadata = {
  title: "Workspaces",
  description: "Workspace concepts, ports, env vars, and switching.",
};

export default function WorkspacesDocsPage() {
  return (
    <DocsShell
      title="Workspaces"
      description="A workspace is the core runtime unit in Muxy. It owns process templates, browser sessions, status checks, window tracking, and reserved ports."
      pagePath="/docs/workspaces"
    >
      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">What Is a Workspace?</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          A workspace belongs to a project and represents a single stream of work. For Git
          projects it is typically backed by a worktree. Each workspace holds its own copies
          of process, status check, browser session, and port definition settings.
        </p>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Creating a Workspace</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Create a workspace from the sidebar using the add button on a project. For Git projects
          you provide a branch and target branch; the workspace name defaults to the branch name
          but can be customized.
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <strong>Branch</strong> &mdash; the Git branch associated with the workspace (required for Git projects).</li>
          <li>• <strong>Target branch</strong> &mdash; the base branch used when creating a new branch.</li>
          <li>• <strong>Directory name</strong> &mdash; an optional custom folder name for the worktree; auto-generated if left blank.</li>
        </ul>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Settings Overrides</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Workspace settings (processes, status checks, browser sessions, port definitions) start
          as copies of the project templates. After creation, each workspace maintains independent
          overrides that do not affect the project templates.
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Add, remove, or rename port definitions per workspace.</li>
          <li>• Edit process commands; changes restart the process immediately if the workspace is running.</li>
          <li>• Add browser sessions that open immediately when the workspace is running.</li>
        </ul>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Ports Per Workspace</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Each workspace receives reserved ports based on named port definitions so multiple
          workspaces can run in parallel without port conflicts.
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Port definitions are configured at the project level (e.g. `FRONTEND_PORT`, `API_PORT`) and inherited by workspaces.</li>
          <li>• Each definition is exposed as an environment variable to every workspace process.</li>
          <li>• Ports are reserved so they cannot be claimed by other processes between allocation and use.</li>
          <li>• Reserved ports are released when a workspace is archived.</li>
        </ul>
        <pre className="mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-xl border border-line bg-background-soft/80 p-3 text-xs leading-6 text-foreground">
          <code>{`Workspace: bugfix/login-timeout
FRONTEND_PORT=21001
API_PORT=21002`}</code>
        </pre>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Environment Variables</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Every workspace process receives the following environment variables at launch.
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Named port env vars from the workspace&apos;s port definitions (e.g. `FRONTEND_PORT=20001`, `API_PORT=20002`).</li>
          <li>• `MUXY_PROJECT_DIR` &mdash; the project directory.</li>
          <li>• `MUXY_WORKSPACE_DIR` &mdash; the workspace directory.</li>
        </ul>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          These variables are available in setup scripts, stop scripts, process commands,
          and status check commands.
        </p>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Switching Between Workspaces</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Switching workspaces changes active context in one action: windows, process list,
          browser session targets, and status output all follow the selected workspace.
        </p>
        <ol className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>1. Select another running workspace from the sidebar or with next/previous shortcuts.</li>
          <li>2. Focus it to bring the first tracked window forward (`cmd+shift+return`).</li>
          <li>3. Continue cycling within that workspace using next/previous or `cmd+1..9`.</li>
        </ol>
      </article>

      <article className="grid gap-4 rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm md:grid-cols-2">
        <ScreenshotFrame
          title="Workspace Settings Tab"
          caption="Per-workspace overrides for processes, status checks, browser sessions, and ports."
        />
        <ScreenshotFrame
          title="Workspace Env Tab"
          caption="Named port env vars and built-in Muxy env vars for the selected workspace."
        />
      </article>
    </DocsShell>
  );
}
