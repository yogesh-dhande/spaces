import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";
import { Prose, Section } from "../components/section";

export const metadata: Metadata = {
  title: "Workspace Lifecycle",
  description: "How workspace state changes from create to delete.",
};

export default function WorkspaceLifecycleDocsPage() {
  return (
    <DocsShell
      title="Workspace Lifecycle"
      description="How workspace state changes from create through launch, stop, restart, and delete."
      pagePath="/docs/workspace-lifecycle"
    >
      <Section title="Runtime State">
        <Prose>
          A workspace is always in one of two runtime states. Runtime health (a failed process, a stale window) surfaces as a warning on top of these states rather than as a separate state.
        </Prose>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <strong>Stopped</strong> &mdash; the workspace exists but nothing is running. This covers both a workspace Spaces has never launched and one it explicitly stopped; either way it is directly launchable.</li>
          <li>• <strong>Running</strong> &mdash; Spaces has started its processes. Browser sessions stay configured but open on demand when you focus them.</li>
        </ul>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Visibility is separate from runtime state. Independently of being running or stopped, a workspace can be <strong>hidden</strong>, which collapses it into the Hidden section at the bottom of the sidebar and leaves it there until you unhide it.
        </p>
      </Section>

      <Section title="Create">
        <Prose>
          On create, Spaces copies the project&apos;s templates into the workspace, reserves its named ports, and runs the setup script. Git projects also get a branch worktree. If you named a branch that doesn&apos;t exist yet, Spaces creates it from the base branch.
        </Prose>
      </Section>

      <Section title="Launch">
        <Prose>
          Launching a stopped workspace:
        </Prose>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Starts each configured process in its own Spaces terminal window.</li>
          <li>• Leaves browser sessions unopened until you explicitly focus them.</li>
          <li>• Remembers those windows so you can jump back to any of them by keyboard shortcuts.</li>
        </ul>
      </Section>

      <Section title="Update While Running">
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Add a process &mdash; it appears immediately with a non-running status; launch it when you&apos;re ready.</li>
          <li>• Edit a process command &mdash; Spaces asks you to confirm, then restarts just that process.</li>
          <li>• Add a browser session &mdash; it appears immediately and opens as a Chrome tab when you focus it.</li>
        </ul>
      </Section>

      <Section title="Stop and Restart">
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Stop gracefully interrupts each process, then escalates if needed.</li>
          <li>• Spaces closes the terminal and browser windows it opened for the workspace.</li>
          <li>• The stop script runs after the processes are down.</li>
          <li>• Restart is stop followed by launch.</li>
        </ul>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          From a workspace directory, <code>spaces workspace start</code> is the concise, convergent way to make sure it is running, and <code>spaces workspace restart</code> stops and relaunches it unconditionally. Scripts and paired-device commands can pass <code>--workspace &lt;id&gt;</code> explicitly. Start launches whichever configured processes aren&apos;t already running &mdash; fresh ones and exited ones alike &mdash; and leaves already-running processes, ad hoc terminals, and coding-agent sessions untouched; use the Mac app to foreground tracked workspace windows.
        </p>
      </Section>

      <Section title="Delete">
        <Prose>
          Delete retires a workspace for good: it stops the workspace, releases its named ports, removes its Git worktree, and deletes the workspace and its settings from Spaces. Its branch name and checkout directory are free to use again right away. The branch itself is kept unless you tick the local- or remote-branch deletion boxes in the confirmation. The default workspace can&apos;t be deleted &mdash; delete the project to remove it.
        </Prose>
      </Section>
    </DocsShell>
  );
}
