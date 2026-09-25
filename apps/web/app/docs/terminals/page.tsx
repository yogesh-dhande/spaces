import type { Metadata } from "next";
import { DocLink } from "../components/doc-link";
import { DocsShell } from "../components/docs-shell";
import { Prose, Section } from "../components/section";

export const metadata: Metadata = {
  title: "Terminals, tabs, and panes",
  description:
    "Open terminals, arrange them in tabs, split panes, and separate windows, and what happens when you close one.",
};

export default function TerminalsDocsPage() {
  return (
    <DocsShell
      title="Terminals, tabs, and panes"
      description="Every process, agent, and ad hoc terminal runs on its device and shows as a pane in its workspace's panel."
      pagePath="/docs/terminals"
    >
      <Section title="Where terminals live">
        <Prose>
          Every process, agent, and ad hoc terminal runs on its own device and shows as a pane in
          its workspace&apos;s panel. It keeps running when the app quits or its pane closes.
        </Prose>
      </Section>

      <Section id="tabs-and-panes" title="Tabs and panes">
        <Prose>
          Tabs run across the top of the panel; split the focused pane right or down. Drag a tab
          to reorder it. The layout, tabs, panes, and splits, is saved per workspace and restored
          the next time you open Spaces.
        </Prose>
      </Section>

      <Section title="Opening a terminal">
        <Prose>
          <code>⌘⌥T</code> opens a fresh ad hoc terminal in the selected workspace; with no workspace
          selected (for example while Alerts is open), it does nothing. Rename one from its sidebar row&apos;s context
          menu (&quot;Rename&quot;).
        </Prose>
      </Section>

      <Section id="session-picker" title="The session picker">
        <Prose>
          The panel&apos;s &quot;+&quot; button or <code>⌘T</code> opens the session picker:
          &quot;New terminal session&quot; first, then the workspace&apos;s sessions that
          aren&apos;t already open in a pane.
        </Prose>
      </Section>

      <Section id="panel-windows" title="Separate windows">
        <Prose>
          Right-clicking a tab offers &quot;Open Tab in New Window&quot;, and, when the tab holds
          more than one pane, &quot;Open Selected Pane in New Window&quot;. A sidebar row&apos;s
          context menu offers &quot;Open in New Window&quot; directly. Closing its last pane
          closes the window the same way closing any other pane does (see below): its sessions
          keep running, unless the pane held an ad hoc terminal sitting at a bare shell prompt.
        </Prose>
      </Section>

      <Section id="closing" title="Closing a pane">
        <Prose>
          <code>⌘W</code> or a pane&apos;s close button closes the pane; the session behind it
          keeps running. The one exception is an ad hoc terminal sitting at a bare shell prompt:
          closing that pane ends the session too. An ad hoc terminal running a program, or holding
          a background job, closes its pane but keeps running, still listed in the sidebar and the
          session picker.
        </Prose>
      </Section>

      <Section id="pane-banners" title="Pane banners">
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>
            • &quot;Session ended. This pane is read-only.&quot; after any exit.
          </li>
          <li>
            • &quot;Session failed. The process stopped unexpectedly.&quot; when the process
            couldn&apos;t start, or the device lost track of it, for example after a reboot; see{" "}
            <DocLink href="/docs/restarts">What survives a restart</DocLink>.
          </li>
        </ul>
      </Section>

      <Section id="keys-inside-a-terminal" title="Keys inside a terminal">
        <Prose>
          Fixed macOS keys work inside every pane: <code>⌘C</code> copy, <code>⌘V</code> paste,{" "}
          <code>⌘A</code> select all, <code>⌘F</code> find, <code>⌘E</code> use selection for
          find, <code>⌘G</code> and <code>⇧⌘G</code> step through matches, and <code>Esc</code>{" "}
          closes find. Zoom terminal text with <code>⌘=</code> and <code>⌘-</code>, from 9 to 18
          points; Spaces starts at 12 points and there is no reset key. One size is shared across
          every open pane in the app.
        </Prose>
      </Section>
    </DocsShell>
  );
}
