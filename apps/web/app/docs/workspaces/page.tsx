import type { Metadata } from "next";
import { DocLink } from "../components/doc-link";
import { DocsShell } from "../components/docs-shell";
import { Prose, Section } from "../components/section";

export const metadata: Metadata = {
  title: "Workspaces",
  description: "Create, set up, start, stop, hide, and delete workspaces.",
};

export default function WorkspacesDocsPage() {
  return (
    <DocsShell
      title="Workspaces"
      description="A workspace is one branch of a Git project, checked out in its own directory with its own ports, processes, browser sessions, and terminals."
      pagePath="/docs/workspaces"
    >
      <Section title="What a workspace is">
        <Prose>
          A workspace is one branch of a Git project, in its own worktree and directory, with its
          own ports, processes, browser sessions, and terminals. A folder project has exactly one.
          The home workspace (<code>~</code>) holds terminals only.
        </Prose>
      </Section>

      <Section id="creating" title="Creating">
        <Prose>
          For a Git project, create a workspace from the &quot;+&quot; on its row (&quot;New
          workspace in &lt;project&gt;&quot;) or with <code>⌘N</code>, choosing &quot;Create
          branch&quot; (a branch name and a base branch) or &quot;Use existing&quot; (pick a
          branch), plus optional notes. A folder project that isn&apos;t a Git repository has
          only its one workspace and offers no &quot;New workspace&quot; action. There is no
          separate title or directory-name field: Spaces
          generates a directory name on its own, independent of the branch name, and it
          isn&apos;t editable; the sidebar shows the branch name. A workspace created on the
          iPhone always branches from the project&apos;s default branch. From the CLI, see{" "}
          <DocLink href="/docs/cli#workspaces">CLI: Workspaces</DocLink>.
        </Prose>
      </Section>

      <Section id="discovery" title="Existing worktrees">
        <Prose>
          A worktree you create with git outside Spaces, on a named branch, appears as a workspace
          on its own. A worktree on a detached HEAD is skipped. A non-default workspace whose
          worktree is gone is removed automatically; one whose directory still exists on disk
          keeps its record even when git&apos;s own listing omits it.
        </Prose>
      </Section>

      <Section id="setup" title="Setup">
        <Prose>
          A workspace&apos;s setup script runs before anything else launches, right after it is
          created. While it is
          pending, running, or failed, the workspace shows a setup screen instead of its panel:
          status, timestamps, exit code, error text, and a log tail, with Retry, Reveal in Finder,
          an ad hoc terminal for repairs, and copy/open actions for the log. After a failure you
          can also edit the setup script before retrying. Processes and browser sessions wait
          until setup succeeds.
        </Prose>
      </Section>

      <Section id="workspace-settings" title="Workspace settings">
        <Prose>
          Per-workspace browser sessions, processes, services, a stop script, and a read-only
          Environment section (see{" "}
          <DocLink href="/docs/environment-variables">Environment variables</DocLink>). Editing
          settings while a workspace is running never starts or stops anything on its own: a
          process name or on-exit edit updates the running process immediately, while a command
          edit asks you to confirm before restarting it.
        </Prose>
      </Section>

      <Section id="notes" title="Notes">
        <Prose>
          Your own free-text notes on a workspace, on the Mac. Set them from the Notes field when
          creating a workspace, or edit them from the notes button in the workspace footer, which
          opens a popover (<code>⌘↩</code> saves, <code>Esc</code> closes). The button shows a
          tint once notes exist and its tooltip previews them; empty, its tooltip reads &quot;Add
          notes&quot;. The home workspace has none. Coding agents keep their own status in a
          brief; see{" "}
          <DocLink href="/docs/coding-agents#briefs">Agent status: Agent briefs</DocLink>.
        </Prose>
      </Section>

      <Section id="start-stop-and-restart" title="Start, stop, and restart">
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>
            • <strong>Start</strong> launches configured processes that aren&apos;t already
            running and leaves running ones alone; it never touches ad hoc terminals or agents.
            It&apos;s offered whenever something is left to start.
          </li>
          <li>
            • <strong>Stop</strong> ends the workspace&apos;s processes and terminal sessions,
            closes its panes and its Chrome tabs, then runs the stop script.
          </li>
          <li>
            • <strong>Restart</strong> is a full stop followed by a fresh start, and it also ends
            the workspace&apos;s ad hoc terminals and agent sessions.
          </li>
        </ul>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Restarting a single process, from any client, keeps its pane in place: the replacement
          session takes over the same tab and split the old one had. Restarting a whole workspace
          keeps its Chrome tabs and the Editor open, and closes the panes of ad hoc terminals and
          agents, since their sessions end. Its process panes stay in place when you restart from
          the CLI or MCP on the Mac; today, restarting from the Mac app or the iPhone can close
          them. Starting or restarting a workspace from the CLI or MCP never moves focus in the Mac
          app. See{" "}
          <DocLink href="/docs/restarts">What survives a restart</DocLink> for quitting and
          rebooting.
        </p>
      </Section>

      <Section id="hiding" title="Hiding">
        <Prose>
          Hiding takes a workspace out of the sidebar and every other list, the command palette,
          Alerts, and the session picker, without asking first, and leaves everything in it
          running. An already-open panel for that workspace keeps its own session picker working,
          since hiding suppresses listings rather than closing panels. The Workspaces dialog (the
          &quot;Filter workspaces&quot; button in the Projects
          header) brings it back; on the iPhone, the Spaces tab&apos;s Workspaces sheet. Hidden on
          one client is hidden on both. Projects hide the same way: hiding a project takes it and
          every workspace under it off every list, without changing which of its workspaces were
          themselves hidden, so unhiding the project brings back exactly what was showing before.
        </Prose>
      </Section>

      <Section id="deleting" title="Deleting">
        <Prose>
          Deleting a non-default workspace stops its sessions and removes its worktree checkout
          from disk, including any uncommitted or untracked files in it. A confirmation names the
          workspace, with checkboxes to also delete the local branch and the remote branch, both
          off by default; those checkboxes only decide whether the branch itself is deleted. The
          default workspace can&apos;t be deleted; delete the project to remove it. While a delete
          is in progress, the row dims and shows a small progress mark in place of its status, and
          nothing on it can be acted on until it completes. Deleting removes the workspace&apos;s
          settings and port assignments with it.
        </Prose>
      </Section>
    </DocsShell>
  );
}
