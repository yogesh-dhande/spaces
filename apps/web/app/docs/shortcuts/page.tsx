import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";

export const metadata: Metadata = {
  title: "Keyboard Shortcuts",
  description: "Global and in-app shortcuts for workspace navigation.",
};

const shortcutRows = [
  { shortcut: "cmd+alt+=", action: "Show or hide Spaces", scope: "Global" },
  { shortcut: "cmd+alt+-", action: "Open the command palette", scope: "Global" },
  { shortcut: "cmd+alt+]", action: "Next window in the current workspace (cycles workspaces when Spaces is frontmost)", scope: "Global + App" },
  { shortcut: "cmd+alt+[", action: "Previous window in the current workspace (cycles workspaces when Spaces is frontmost)", scope: "Global + App" },
  { shortcut: "cmd+alt+a", action: "Open Alerts", scope: "App" },
  { shortcut: "cmd+n", action: "New workspace for the selected project", scope: "App" },
  { shortcut: "cmd+alt+e", action: "Open the selected workspace in your configured editor", scope: "Global + App" },
  { shortcut: "cmd+alt+t", action: "Open a terminal for the selected workspace", scope: "App" },
  { shortcut: "cmd+alt+f", action: "Reveal the selected workspace in Finder", scope: "App" },
  { shortcut: "cmd+1 … cmd+9", action: "Focus workspace window by number", scope: "App" },
];

export default function ShortcutsDocsPage() {
  return (
    <DocsShell
      title="Keyboard Shortcuts"
      description="Spaces is designed for keyboard-first context switching between running workspaces and captured windows."
      pagePath="/docs/shortcuts"
    >
      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Default Shortcuts</h2>
        <div className="mt-3 overflow-x-auto rounded-xl border border-line/70">
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
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">The Leader</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          The leader is the shared modifier — <code>cmd+alt</code> by default — used for workspace and app shortcuts like next/previous window, Alerts, editor, new terminal, and Finder. Change the leader once and all of those move with it.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Customization</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Every shortcut is configurable from Settings (<code>cmd+,</code>) Menu
        </p>
      </article>
    </DocsShell>
  );
}
