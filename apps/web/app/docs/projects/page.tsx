import type { Metadata } from "next";
import { InlineCode } from "../components/code-block";
import { DocsShell } from "../components/docs-shell";
import { Prose, Section } from "../components/section";

export const metadata: Metadata = {
  title: "Projects",
  description: "Project configuration, templates, and directory structure.",
};

export default function ProjectsDocsPage() {
  return (
    <DocsShell
      title="Projects"
      description="A project is a directory-based unit of configuration that defines templates for processes, browser sessions, and services."
      pagePath="/docs/projects"
    >
      <Section title="What Is a Project?">
        <Prose>
          A project points at a directory on your Mac. If the directory is a Git repo, Spaces treats each workspace as a branch worktree. Otherwise, each workspace points at the project directory directly.
        </Prose>
      </Section>

      <Section title="Project Settings">
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <strong>Directory</strong> &mdash; the project folder. Spaces uses the folder name as the display name.</li>
          <li>• <strong>Setup script</strong> &mdash; runs once when a new workspace is created. A good place for <code>npm install</code> or copying a shared <code>.env</code> file into the workspace.</li>
          <li>• <strong>Stop script</strong> &mdash; runs whenever a workspace is stopped (including on restart and delete), after Spaces shuts its processes down. Use it to tear down any extra services the workspace left behind.</li>
        </ul>
      </Section>

      <Section title="Project Templates">
        <Prose>
          You configure processes, browser sessions, and services once on the project. New workspaces start from those templates. Each workspace can edit its own copy without affecting the project or other workspaces.
        </Prose>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <strong>Processes</strong> &mdash; commands Spaces runs alongside the workspace (servers, workers, coding agents).</li>
          <li>• <strong>Browser Sessions</strong> &mdash; URLs tied to a workspace; each opens as a Chrome tab when you focus it.</li>
          <li>• <strong>Services</strong> &mdash; unique DNS-safe names like <code>web</code> and <code>api</code>. Spaces assigns each workspace its own port per service and a stable URL through a bundled Caddy proxy, so two workspaces never clash.</li>
        </ul>
      </Section>

      <Section title="Adding a Project">
        <Prose>
          Add a project from the app by pointing at a local directory or pasting a Git URL. For a Git URL, Spaces clones into <InlineCode>~/spaces/repos</InlineCode>. Either way, Spaces creates a default workspace for you automatically.
        </Prose>
      </Section>

      <Section title="Default Workspace">
        <Prose>
          Every project has a default workspace:
        </Prose>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <strong>Git projects</strong> &mdash; the default workspace tracks <code>main</code> or <code>master</code>.</li>
          <li>• <strong>Non-Git projects</strong> &mdash; the default workspace points at the project directory.</li>
          <li>• The default workspace can&apos;t be deleted on its own but you can delete a project entirely.</li>
        </ul>
      </Section>

      <Section title="Removing a Project">
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Spaces cleans up the project&apos;s workspaces and their worktree directories.</li>
          <li>• If Spaces cloned the repo (via Git URL), the clone under <code>~/spaces/repos</code> is removed too.</li>
          <li>• Directories you pointed Spaces at yourself are left alone.</li>
        </ul>
      </Section>
    </DocsShell>
  );
}
