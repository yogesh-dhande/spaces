import type { Metadata } from "next";
import { InlineCode } from "../components/code-block";
import { DocLink } from "../components/doc-link";
import { DocsShell } from "../components/docs-shell";
import { Prose, Section } from "../components/section";

export const metadata: Metadata = {
  title: "Projects",
  description:
    "Add a folder or Git repository on your Mac or a paired device, and set how its workspaces run.",
};

export default function ProjectsDocsPage() {
  return (
    <DocsShell
      title="Projects"
      description="A project is a folder or Git repository on one of your devices. You configure how it runs once, then create workspaces from it."
      pagePath="/docs/projects"
    >
      <Section title="What a project is">
        <Prose>
          A project is a folder or Git repository on one device: your Mac, or a paired device. A
          Git project can have many workspaces, each on its own branch. A folder project has
          exactly one workspace, the folder itself.
        </Prose>
      </Section>

      <Section id="adding-a-project" title="Adding a project">
        <Prose>
          Add a project from the &quot;New project&quot; button in the Projects header. The flow
          has three steps, each fixed once you make a choice:
        </Prose>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>
            • <strong>Device</strong>: skipped when your Mac is the only device. An offline
            device is shown disabled.
          </li>
          <li>
            • <strong>Source</strong>: &quot;Existing folder&quot; (a path field with directory
            autocomplete on the chosen device) or &quot;Clone a repo&quot; (a Git URL). Continue
            reads any <InlineCode>spaces.yaml</InlineCode> it finds: for a folder, from the folder
            itself; for a repo, straight from its declared default branch, without cloning
            anything yet.
          </li>
          <li>
            • <strong>Configure</strong>: the setup script, stop script, services, processes, and
            browser sessions, prefilled from that <InlineCode>spaces.yaml</InlineCode> or empty
            with a note that none was found.
          </li>
        </ul>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Create clones the repo when the source was a Git URL, creates the default workspace,
          and saves the settings you were shown, not a re-read of the file, so canceling any
          earlier step leaves nothing behind. If a managed clone from an earlier attempt already
          exists but is not registered to any project, Continue asks first before Create replaces
          it.
        </p>
      </Section>

      <Section id="git-and-folder-projects" title="Git and folder projects">
        <Prose>
          A Git project&apos;s default workspace is the existing folder itself when you added one that
          way, or, when you cloned a repo, a worktree of the declared default branch checked out from
          the managed clone Create made. Every other workspace is a worktree on its own branch, sharing
          the project&apos;s one clone, in a folder Spaces manages, kept separate from the default
          workspace&apos;s folder. A folder project&apos;s single workspace is the folder itself.
        </Prose>
      </Section>

      <Section id="default-workspace" title="The default workspace">
        <Prose>
          Every project has a default workspace, listed first, that can&apos;t be deleted on its
          own; delete the project to remove it. For a Git project added as an existing folder,
          it&apos;s the folder itself, labeled with the repository&apos;s declared default
          branch. For a cloned repo, it&apos;s a worktree of the declared default branch. A
          folder project has no repository branch to label its workspace with: its one and only
          workspace is the folder itself, labeled with the folder name.
        </Prose>
      </Section>

      <Section id="project-settings" title="Project settings">
        <Prose>
          The row&apos;s settings action (a gearshape icon) opens a dialog: setup script, stop
          script, services, processes, and browser sessions. Save persists your edits. Import and
          export <InlineCode>spaces.yaml</InlineCode> from the same dialog (see{" "}
          <DocLink href="/docs/spaces-yaml#import-and-export">
            spaces.yaml: Import and export
          </DocLink>
          ). After an import on a Git project, Save offers &quot;Update All Workspaces&quot; or
          &quot;Project Only&quot;; saving without an import never rewrites existing workspaces. A
          folder project has no separate workspace settings: its settings dialog edits its one
          workspace directly.
        </Prose>
      </Section>

      <Section id="home-workspace" title="The home workspace (~)">
        <Prose>
          Every device has one, at the top of its sidebar section, rooted at your home directory,
          for terminals that belong to no project. It has no settings, can&apos;t be deleted, and
          can be hidden.
        </Prose>
      </Section>

      <Section title="Hiding a project">
        <Prose>
          A project hides the same way a workspace does; see{" "}
          <DocLink href="/docs/workspaces#hiding">Workspaces: Hiding</DocLink>.
        </Prose>
      </Section>

      <Section id="deleting-a-project" title="Deleting a project">
        <Prose>
          Deleting a project stops everything it is running, removes the automations attached to
          its workspaces, removes its Git worktrees, and, if Spaces cloned the repository, removes
          the managed clone. A folder or repository you pointed Spaces at directly is left on
          disk. The default workspace goes with the project; there is no separate confirmation for
          it.
        </Prose>
      </Section>
    </DocsShell>
  );
}
