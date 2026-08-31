import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";
import { Prose, Section } from "../components/section";

export const metadata: Metadata = {
  title: "Keyboard Shortcuts",
  description: "Global and in-app shortcuts for workspace navigation.",
};

const shortcutRows = [
  { shortcut: "cmd+alt+=", action: "Show or hide Spaces", scope: "Global" },
  { shortcut: "cmd+alt+-", action: "Open the command palette", scope: "Global" },
  { shortcut: "cmd+alt+]", action: "Next already-open window in the current workspace", scope: "Global + App" },
  { shortcut: "cmd+alt+[", action: "Previous already-open window in the current workspace", scope: "Global + App" },
  { shortcut: "cmd+alt+down", action: "Select the next workspace in the sidebar (Alerts and workspaces)", scope: "App" },
  { shortcut: "cmd+alt+up", action: "Select the previous workspace in the sidebar (Alerts and workspaces)", scope: "App" },
  { shortcut: "cmd+alt+a", action: "Open Alerts", scope: "App" },
  { shortcut: "cmd+n", action: "New workspace for the selected project", scope: "App" },
  { shortcut: "cmd+alt+e", action: "Open the selected workspace in your configured editor", scope: "Global + App" },
  { shortcut: "cmd+alt+t", action: "Open a terminal for the selected workspace", scope: "App" },
  { shortcut: "cmd+alt+f", action: "Reveal the selected workspace in Finder", scope: "App" },
  { shortcut: "cmd+1 … cmd+0", action: "Open or focus workspace target by number", scope: "App" },
  { shortcut: "cmd+= / cmd+shift+=", action: "Zoom terminal text in one point", scope: "Terminal pane" },
  { shortcut: "cmd+- / cmd+shift+-", action: "Zoom terminal text out one point", scope: "Terminal pane" },
];

export default function ShortcutsDocsPage() {
  return (
    <DocsShell
      title="Keyboard Shortcuts"
      description="Spaces is designed for keyboard-first context switching between running workspaces and captured windows."
      pagePath="/docs/shortcuts"
    >
      <Section title="Default Shortcuts">
        <div className="mt-3 overflow-x-auto rounded-sm border border-line/70">
          <table className="min-w-full border-collapse text-left text-sm">
            <thead className="bg-background-soft/70 text-foreground">
              <tr>
                <th className="px-3 py-2 font-mono text-xs uppercase tracking-[0.12em]">Shortcut</th>
                <th className="px-3 py-2 font-mono text-xs uppercase tracking-[0.12em]">Action</th>
                <th className="px-3 py-2 font-mono text-xs uppercase tracking-[0.12em]">Scope</th>
              </tr>
            </thead>
            <tbody>
              {shortcutRows.map((row) => (
                <tr key={row.shortcut} className="border-t border-line">
                  <td className="px-3 py-2 font-mono text-xs text-foreground">{row.shortcut}</td>
                  <td className="px-3 py-2 text-foreground-soft">{row.action}</td>
                  <td className="px-3 py-2 text-foreground-soft">{row.scope}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Section>

      <Section title="Focus vs Cycle">
        <Prose>
          Numbered shortcuts open or focus the selected workspace&apos;s ordered targets, including configured browser sessions, stopped process rows, and live coding agents. Next/previous window shortcuts cycle only through targets that already have an open tracked Chrome tab or Spaces terminal pane.
        </Prose>
      </Section>

      <Section title="The Leader">
        <Prose>
          The leader is the shared modifier — <code>cmd+alt</code> by default — used for workspace and app shortcuts like next/previous window, next/previous workspace, Alerts, editor, new terminal, and Finder. Change the leader once and all of those move with it. Moving the sidebar selection is bound only to leader+up/leader+down, so plain arrow keys stay out of navigation.
        </Prose>
      </Section>

      <Section title="Terminal Text Zoom">
        <Prose>
          The zoom shortcuts work while a terminal pane has focus, and range from 9 to 18 points; Spaces starts at 12 points and there is no reset key, so you step back down to return to it. One size is shared across the app, so zooming resizes text in every open terminal pane at once, and it is remembered the next time you launch Spaces. <code>cmd+0</code> is not a zoom key: it keeps focusing the tenth numbered target, in a terminal pane the same as everywhere else.
        </Prose>
      </Section>

      <Section title="Customization">
        <Prose>
          The workspace and app shortcuts are configurable from Settings (<code>cmd+,</code>) Menu. The terminal text zoom shortcuts are fixed.
        </Prose>
      </Section>
    </DocsShell>
  );
}
