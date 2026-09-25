import type { Metadata } from "next";
import { Cmd, InlineCode } from "../components/code-block";
import { DocLink } from "../components/doc-link";
import { DocsShell } from "../components/docs-shell";
import { Prose, Section } from "../components/section";

export const metadata: Metadata = {
  title: "Quickstart",
  description: "Add a project, create a workspace, start it, and open a coding agent.",
};

export default function GettingStartedDocsPage() {
  return (
    <DocsShell
      title="Quickstart"
      description="Add a project, create a workspace, start it, and open a coding agent."
      pagePath="/docs/getting-started"
    >
      <Section title="Install and open Spaces">
        <Prose>
          See <DocLink href="/docs/installation">Install on your Mac</DocLink>.
        </Prose>
      </Section>

      <Section id="add-a-project" title="Add a project">
        <Prose>
          Press &ldquo;+&rdquo; (&ldquo;New project&rdquo;) in the Projects header. Pick the device to
          add it on, then a source: &ldquo;Existing folder&rdquo; or &ldquo;Clone a repo&rdquo;. Nothing
          is cloned until you create the project. See{" "}
          <DocLink href="/docs/projects#adding-a-project">Adding a project</DocLink>.
        </Prose>
      </Section>

      <Section title="Describe how it runs">
        <Prose>
          In the Configure step, or in a <InlineCode>spaces.yaml</InlineCode> in the repo, declare the
          services, processes, and browser sessions a workspace should start with. See{" "}
          <DocLink href="/docs/spaces-yaml">spaces.yaml</DocLink>.
        </Prose>
      </Section>

      <Section id="create-a-workspace" title="Create a workspace">
        <Prose>
          Press &ldquo;+&rdquo; on the project row (&ldquo;New workspace in &lt;project&gt;&rdquo;), or{" "}
          <Cmd>⌘N</Cmd>. Choose &ldquo;Create branch&rdquo; or &ldquo;Use existing&rdquo;. See{" "}
          <DocLink href="/docs/workspaces#creating">Creating a workspace</DocLink>. A folder that is
          not a Git repository has no separate workspace to create: continue with its one workspace,
          the folder itself.
        </Prose>
      </Section>

      <Section id="start-it" title="Start it">
        <Prose>
          Press Start. Each configured process opens as a pane in the workspace panel; browser sessions
          open in Chrome when you focus them; each service gets a stable URL (see{" "}
          <DocLink href="/docs/services#stable-urls">Stable URLs</DocLink>).
        </Prose>
      </Section>

      <Section id="open-an-agent" title="Open a terminal and start an agent">
        <Prose>
          Press <Cmd>⌘⌥T</Cmd> to open a terminal in the workspace, then run{" "}
          <InlineCode>claude</InlineCode>, <InlineCode>codex</InlineCode>, or{" "}
          <InlineCode>opencode</InlineCode>. Its status shows on its sidebar row. See{" "}
          <DocLink href="/docs/coding-agents">Agent status</DocLink>.
        </Prose>
      </Section>

      <Section id="move-around" title="Move around">
        <Prose>
          <Cmd>⌘1</Cmd> through <Cmd>⌘0</Cmd> focus the numbered targets under the selected workspace.{" "}
          <Cmd>⌘⌥-</Cmd> opens the command palette. <Cmd>⌘⌥]</Cmd> and <Cmd>⌘⌥[</Cmd> cycle through open
          windows. See <DocLink href="/docs/window-management">Finding your way around</DocLink>.
        </Prose>
      </Section>

      <Section title="Stop it or leave it running">
        <Prose>
          Stop ends the workspace&apos;s terminals, including any agent running in one, closes its panes
          and tracked browser tabs, and runs its stop script if it has one. Quitting Spaces asks whether
          to keep everything running or stop it first. See{" "}
          <DocLink href="/docs/restarts#quitting">Quitting Spaces</DocLink>.
        </Prose>
      </Section>

      <Section title="Next">
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>
            • <DocLink href="/docs/ios">The iPhone app</DocLink>: your workspaces from your pocket.
          </li>
          <li>
            • <DocLink href="/docs/remote-access">Remote machines</DocLink>: pair another Mac or a Linux
            box.
          </li>
          <li>
            • <DocLink href="/docs/orchestration">Orchestrate agents</DocLink>: have one agent spawn and
            watch others.
          </li>
        </ul>
      </Section>
    </DocsShell>
  );
}
