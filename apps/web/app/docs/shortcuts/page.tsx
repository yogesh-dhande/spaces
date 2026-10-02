import type { Metadata } from "next";
import type { ReactNode } from "react";
import { DocLink } from "../components/doc-link";
import { DocsShell } from "../components/docs-shell";
import { RefTable } from "../components/ref-table";
import { Prose, Section } from "../components/section";

export const metadata: Metadata = {
  title: "Keyboard shortcuts",
  description: "Spaces' shortcuts, which ones work from any app, and how to change them.",
};

const rows: ReactNode[][] = [
  ["Show or hide Spaces", "⌘⌥=", "Any app"],
  ["Open the command palette", "⌘⌥-", "Any app"],
  ["Next window", "⌘⌥]", "Any app"],
  ["Previous window", "⌘⌥[", "Any app"],
  ["Open in Editor", "⌘⌥E", "Any app"],
  ["Show alerts", "⌘⌥A", "In Spaces"],
  ["Show or hide an agent's brief", "⌘⌥B", "In Spaces"],
  ["Create workspace", "⌘N", "In Spaces"],
  ["Reload", "⌘⌥R", "In Spaces"],
  ["Open terminal", "⌘⌥T", "In Spaces"],
  ["Open session picker", "⌘T", "In Spaces"],
  ["Open in Finder", "⌘⌥F", "In Spaces"],
  ["Settings", "⌘,", "In Spaces"],
  ["Cycle mode", "⌘⌥\\", "In Spaces"],
  ["Next workspace", "⌘⌥↓", "In Spaces"],
  ["Previous workspace", "⌘⌥↑", "In Spaces"],
  ["Focus target 1 through 10", "⌘1 … ⌘0", "In Spaces"],
];

export default function ShortcutsDocsPage() {
  return (
    <DocsShell
      title="Keyboard shortcuts"
      description="Spaces' own shortcuts share a configurable leader; the leader defaults to ⌘⌥."
      pagePath="/docs/shortcuts"
    >
      <Section id="spaces-shortcuts" title="Spaces' shortcuts">
        <Prose>
          The leader supplies the shared modifiers for the shortcuts below; it defaults to{" "}
          <code>⌘⌥</code>.
        </Prose>
        <RefTable columns={["Action", "Default", "Works from"]} rows={rows} />
      </Section>

      <Section id="fixed-keys" title="Fixed keys">
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>
            • <code>⌘W</code> closes the focused pane.
          </li>
          <li>
            • <code>⌘X</code> dismisses the highlighted alert in the command palette.
          </li>
        </ul>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Keys inside a terminal pane (copy, paste, find, zoom) are their own set; see{" "}
          <DocLink href="/docs/terminals#keys-inside-a-terminal">
            Terminals, tabs, and panes: Keys inside a terminal
          </DocLink>
          .
        </p>
      </Section>

      <Section id="changing-shortcuts" title="Changing shortcuts">
        <Prose>
          Change a shortcut from Settings → Shortcuts. Spaces&apos; own shortcuts are
          configurable, including the leader itself. Standard macOS keys, such as the fixed keys
          above, are not. A shortcut another app already owns may do nothing;
          see{" "}
          <DocLink href="/docs/troubleshooting#shortcuts">
            Troubleshooting: A shortcut does nothing
          </DocLink>
          .
        </Prose>
      </Section>
    </DocsShell>
  );
}
