import type { Metadata } from "next";
import { ScreenshotFrame } from "../../components/screenshot-frame";
import { DocsShell } from "../components/docs-shell";

export const metadata: Metadata = {
  title: "Projects",
  description: "Project configuration, templates, and directory structure.",
};

export default function ProjectsDocsPage() {
  return (
    <DocsShell
      title="Projects"
      description="A project is a directory-based unit of configuration that defines templates for processes, status checks, browser sessions, and port definitions."
      pagePath="/docs/projects"
    >
      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">What Is a Project?</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          A project points to a local directory. Muxy detects whether the directory is a Git
          repository and adjusts workspace behavior accordingly.
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Git detection runs when a project is added and at application startup.</li>
          <li>• Project configuration can be shared across machines.</li>
        </ul>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Project Settings</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <strong>Directory</strong> &mdash; the project folder. The display name is inferred from the directory name.</li>
          <li>• <strong>Setup script</strong> &mdash; a shell script that runs once when a new workspace is created (e.g. copy environment files into a worktree).</li>
          <li>• <strong>Stop script</strong> &mdash; a shell script that runs whenever a workspace is stopped (including restart and archive), after processes are terminated.</li>
        </ul>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Project Templates</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Projects define templates that are copied into each workspace on creation. After
          creation, each workspace maintains its own independent overrides.
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <strong>Processes</strong> &mdash; commands to run in terminal windows (servers, workers, coding agents).</li>
          <li>• <strong>Status Checks</strong> &mdash; health commands that run at intervals and update status indicators.</li>
          <li>• <strong>Browser Sessions</strong> &mdash; URLs opened in Chrome at workspace launch and tracked for focus cycling.</li>
          <li>• <strong>Port Definitions</strong> &mdash; named env vars (e.g. `FRONTEND_PORT`, `API_PORT`) that receive reserved port numbers per workspace.</li>
        </ul>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Adding a Project</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Add a project by pointing to a local directory or providing a Git repository URL.
          Git URLs are cloned into a Muxy-managed location.
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• On add, Muxy checks whether the directory is a Git repo and creates a default workspace automatically.</li>
          <li>• You can then configure processes, status checks, browser sessions, and port definitions.</li>
        </ul>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Default Workspace</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Every project gets a non-archivable default workspace created automatically.
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <strong>Git projects</strong> &mdash; default workspace corresponds to the `main` or `master` branch.</li>
          <li>• <strong>Non-Git projects</strong> &mdash; default workspace corresponds to the project directory itself.</li>
          <li>• The default workspace cannot be archived.</li>
        </ul>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Removing a Project</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Removing a project cleans up related workspaces and workspace directories.</li>
          <li>• For Git projects cloned by Muxy, the cloned directory is also removed.</li>
          <li>• Projects pointing to directories you manage yourself are never deleted from disk.</li>
        </ul>
      </article>

      <article className="grid gap-4 rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm md:grid-cols-2">
        <ScreenshotFrame
          title="Add Project Form"
          caption="Local directory or Git URL input with port definitions and process templates."
        />
        <ScreenshotFrame
          title="Project Detail View"
          caption="Project settings with inline editors for scripts, ports, processes, and browser sessions."
        />
      </article>
    </DocsShell>
  );
}
