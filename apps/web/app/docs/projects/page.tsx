import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";

export const metadata: Metadata = {
  title: "Projects",
  description: "Project configuration, templates, and directory structure.",
};

export default function ProjectsDocsPage() {
  return (
    <DocsShell
      title="Projects"
      description="A project is a directory-based unit of configuration that defines templates for processes, browser sessions, and port definitions."
      pagePath="/docs/projects"
    >
      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">What Is a Project?</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          A project points at a directory on your Mac. If the directory is a Git repo, Spaces treats each workspace as a branch worktree. Otherwise, each workspace points at the project directory directly.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Project Settings</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <strong>Directory</strong> &mdash; the project folder. Spaces uses the folder name as the display name.</li>
          <li>• <strong>Setup script</strong> &mdash; runs once when a new workspace is created. A good place for <code>npm install</code> or copying a shared <code>.env</code> file into the workspace.</li>
          <li>• <strong>Stop script</strong> &mdash; runs whenever a workspace is stopped (including on restart and archive), after Spaces shuts its processes down. Use it to tear down any extra services the workspace left behind.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Project Templates</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          You configure processes, browser sessions, and named ports once on the project. New workspaces start from those templates. Each workspace can edit its own copy without affecting the project or other workspaces.
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <strong>Processes</strong> &mdash; commands Spaces runs alongside the workspace (servers, workers, coding agents).</li>
          <li>• <strong>Browser Sessions</strong> &mdash; URLs tied to a workspace; each opens in a Chrome window when you focus it.</li>
          <li>• <strong>Named Ports</strong> &mdash; placeholder names like <code>FRONTEND_PORT</code> and <code>API_PORT</code>. Spaces assigns each workspace a unique port number per name so two workspaces never clash.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Adding a Project</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Add a project from the app by pointing at a local directory or pasting a Git URL. For a Git URL, Spaces clones into <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">~/spaces/repos</code>. Either way, Spaces creates a default workspace for you automatically.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Default Workspace</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Every project has a default workspace:
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <strong>Git projects</strong> &mdash; the default workspace tracks <code>main</code> or <code>master</code>.</li>
          <li>• <strong>Non-Git projects</strong> &mdash; the default workspace points at the project directory.</li>
          <li>• The default workspace can&apos;t be archived but you can delete a project entirely.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Removing a Project</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Spaces cleans up the project&apos;s workspaces and their worktree directories.</li>
          <li>• If Spaces cloned the repo (via Git URL), the clone under <code>~/spaces/repos</code> is removed too.</li>
          <li>• Directories you pointed Spaces at yourself are left alone.</li>
        </ul>
      </article>
    </DocsShell>
  );
}
