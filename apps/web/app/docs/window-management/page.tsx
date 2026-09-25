import type { Metadata } from "next";
import { DocLink } from "../components/doc-link";
import { DocsShell } from "../components/docs-shell";
import { Prose, Section } from "../components/section";

export const metadata: Metadata = {
  title: "Finding your way around",
  description:
    "The sidebar, numbered targets, the command palette, and cycling through windows.",
};

export default function WindowManagementDocsPage() {
  return (
    <DocsShell
      title="Finding your way around"
      description="The sidebar lists everything a workspace can focus; the command palette, numbered shortcuts, and cycling get you to any of it without reaching for the mouse."
      pagePath="/docs/window-management"
    >
      <Section id="sidebar" title="The sidebar">
        <Prose>
          One section per device (&quot;Local&quot; for this Mac), with the home workspace first,
          then that device&apos;s projects and workspaces. Expand a workspace to see its targets,
          grouped in a fixed order: browser sessions, configured processes, coding agents, then ad
          hoc terminals. Target rows show their <code>⌘</code> number.
        </Prose>
      </Section>

      <Section id="numbered-targets" title="Numbered targets">
        <Prose>
          <code>⌘1</code> through <code>⌘9</code>, and <code>⌘0</code> for the tenth, in the same
          order as the sidebar rows. Clicking a row does the same thing its number does: it
          focuses the pane or Chrome tab, or starts a not-yet-running process and opens it.
        </Prose>
      </Section>

      <Section id="command-palette" title="Command palette">
        <Prose>
          <code>⌘⌥-</code> opens the command palette from anywhere. With nothing typed it shows
          Alerts first, then your most recently focused targets. Typing fuzzy-searches by name
          first, then by secondary text. <code>⌘X</code> dismisses the highlighted alert.
        </Prose>
      </Section>

      <Section id="cycling" title="Cycling">
        <Prose>
          <code>⌘⌥]</code> and <code>⌘⌥[</code> step forward and back through the open windows of
          the current cycling mode; <code>⌘⌥\</code> switches mode. There are four modes:
          Workspace, Alerts, All agents, and Open sessions. A row pinned at the bottom of the
          sidebar shows the current mode and how many windows it holds; a small panel confirms
          each mode switch. The chosen mode is remembered across launches.
        </Prose>
      </Section>

      <Section id="workspace-switching" title="Switching workspaces">
        <Prose>
          <code>⌘⌥↓</code> and <code>⌘⌥↑</code> select the next or previous workspace in the
          sidebar.
        </Prose>
      </Section>

      <Section id="toggle-the-app" title="Showing and hiding Spaces">
        <Prose>
          <code>⌘⌥=</code> works from any app. It hides the whole app, panel windows included,
          when Spaces&apos; main window is focused; otherwise it brings the main window forward,
          even if a panel window or the Editor is what&apos;s focused instead.
        </Prose>
      </Section>

      <Section title="Recovery">
        <Prose>
          Spaces never polls a tracked browser-session window; it checks only when you focus that
          session and resolves a stale one silently, reopening a closed tab or finding a moved one
          by its URL, with nothing to confirm (see{" "}
          <DocLink href="/docs/browser-sessions#opening">Browser sessions</DocLink>). A workspace
          with a stale window or a failed process carries a warning icon next to its status
          instead of a prompt; hover it to see what needs attention.
        </Prose>
      </Section>
    </DocsShell>
  );
}
