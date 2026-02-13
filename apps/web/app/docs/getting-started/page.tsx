import type { Metadata } from "next";
import { ScreenshotFrame } from "../../components/screenshot-frame";
import { DocsShell } from "../components/docs-shell";

export const metadata: Metadata = {
  title: "Getting Started",
  description: "Install prerequisites and launch your first workspace.",
};

export default function GettingStartedDocsPage() {
  return (
    <DocsShell
      title="Getting Started"
      description="Start from a project directory or a Git URL, then launch a workspace with processes, browser sessions, and reserved ports."
      pagePath="/docs/getting-started"
    >
      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Requirements</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• macOS 14 or later.</li>
          <li>• `yabai` installed and running (window IDs and focus routing).</li>
          <li>• iTerm2 installed (process terminals).</li>
          <li>• Google Chrome installed (browser sessions).</li>
          <li>• Accessibility permissions granted to Spaceship dependencies.</li>
        </ul>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">First Session Flow</h2>
        <ol className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>1. Install dependencies (`yabai`, iTerm2, Google Chrome) and grant permissions.</li>
          <li>2. Add or connect a project.</li>
          <li>3. Create a workspace for the branch or task you are starting.</li>
          <li>4. Launch the workspace and continue where you left off.</li>
          <li>5. Switch to another workspace without rebuilding context from scratch.</li>
        </ol>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Core Paths</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Spaceship keeps shared configuration in YAML and runtime state in SQLite.
        </p>
        <pre className="mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-xl border border-line bg-background-soft/80 p-3 text-xs leading-6 text-foreground">
          <code>{`~/.spaceship/config.yaml            # global settings + project templates
~/.spaceship/spaceship.db            # workspace/runtime state
/Users/<username>/spaceship/projects # app-managed git clones
/Users/<username>/spaceship/workspaces/<project>/<dirname> # git worktrees`}</code>
        </pre>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Add Your First Project</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Use either a local directory or a Git repository URL.
        </p>
        <pre className="mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-xl border border-line bg-background-soft/80 p-3 text-xs leading-6 text-foreground">
          <code>{`# existing local directory
spaceship project add --dir /path/to/repo

# clone from Git URL into /Users/<username>/spaceship/projects/<repo_name>
spaceship project add --git-url https://github.com/org/repo.git`}</code>
        </pre>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          On project add, Spaceship detects whether the directory is a Git repository and creates a non-archivable default workspace.
        </p>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Create a Workspace</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          For Git projects, create a workspace with workspace name, branch, and target branch.
          Target branch defaults to `main` or `master` when available.
        </p>
        <pre className="mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-xl border border-line bg-background-soft/80 p-3 text-xs leading-6 text-foreground">
          <code>{`spaceship workspace create \
  --project-dir /path/to/repo \
  --name payments-work \
  --branch feat/payments \
  --target-branch main`}</code>
        </pre>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Non-Git projects create workspaces from the project directory and do not require branch inputs.
        </p>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Launch and Validate</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Launch is valid only for stopped workspaces. A launch allocates ports, starts configured processes,
          opens browser sessions, and opens the preferred editor.
        </p>
        <pre className="mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-xl border border-line bg-background-soft/80 p-3 text-xs leading-6 text-foreground">
          <code>{`spaceship workspace launch --project-dir /path/to/repo --name payments-work
spaceship workspace list --project-dir /path/to/repo --all`}</code>
        </pre>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Confirm the workspace row shows as running.</li>
          <li>• Confirm process rows appear in the Run tab.</li>
          <li>• Confirm URLs in browser sessions are open in Chrome.</li>
          <li>• Confirm `PORT0` to `PORT9` appear in the Env tab.</li>
        </ul>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Product Boundaries</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Spaceship manages workspace context and switching.</li>
          <li>• Spaceship does not manage tiling geometry; keep using yabai for layout.</li>
          <li>• Browser session focus and cleanup are URL-based; tab-title matching is intentionally avoided.</li>
          <li>• Existing tools still handle editing and coding.</li>
          <li>• Multiple workspaces can run in parallel while you stay focused on one.</li>
        </ul>
      </article>

      <article className="grid gap-4 rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm md:grid-cols-2">
        <ScreenshotFrame
          title="Project and Workspace Sidebar"
          caption="Projects on the left, with nested workspaces and running-state status icons."
        />
        <ScreenshotFrame
          title="Workspace Run Tab"
          caption="Launch/restart/stop/archive actions, running processes, and window shortcuts."
        />
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Starter Config Example</h2>
        <pre className="mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-xl border border-line bg-background-soft/80 p-3 text-xs leading-6 text-foreground">
          <code>{`editor: vscode
port_range:
  start: 20000
  end: 30000
projects:
  - dir: /path/to/repo
    setup_script: cp /shared/.env .env
    stop_script: docker compose down --remove-orphans
    processes:
      - name: web
        command: PORT=$PORT0 npm run dev
      - name: worker
        command: PORT=$PORT1 npm run worker
    status_checks:
      - name: web-health
        process: web
        command: curl -fsS http://localhost:$PORT0/health
        interval: 10
        timeout: 2
        on_exit: notify
    browser_sessions:
      - url: http://localhost:$PORT0
      - url: http://localhost:$PORT0/admin`}</code>
        </pre>
      </article>
    </DocsShell>
  );
}
