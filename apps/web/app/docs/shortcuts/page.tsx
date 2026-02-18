import type { Metadata } from "next";
import { ScreenshotFrame } from "../../components/screenshot-frame";
import { DocsShell } from "../components/docs-shell";

export const metadata: Metadata = {
  title: "Keyboard Shortcuts",
  description: "Global and in-app shortcuts for workspace navigation.",
};

const shortcutRows = [
  { shortcut: "cmd+shift+=", action: "Toggle/focus Muxy window", scope: "Global" },
  { shortcut: "cmd+shift+]", action: "Next workspace (or next window for active workspace)", scope: "Global + App" },
  { shortcut: "cmd+shift+[", action: "Previous workspace (or previous window for active workspace)", scope: "Global + App" },
  { shortcut: "cmd+shift+return", action: "Focus selected workspace and first window", scope: "App" },
  { shortcut: "cmd+shift+e", action: "Open editor for workspace owning focused window", scope: "Global" },
  { shortcut: "cmd+shift+t", action: "Open selected workspace terminal", scope: "App" },
  { shortcut: "cmd+shift+f", action: "Open selected workspace in Finder", scope: "App" },
  { shortcut: "cmd+1 ... cmd+9", action: "Focus workspace window by index", scope: "App" },
];

export default function ShortcutsDocsPage() {
  return (
    <DocsShell
      title="Keyboard Shortcuts"
      description="Muxy is designed for keyboard-first context switching between running workspaces and captured windows."
      pagePath="/docs/shortcuts"
    >
      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Default Shortcuts</h2>
        <div className="mt-3 overflow-x-auto rounded-xl border border-line">
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

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Workspace vs Window Navigation</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• In-app next/previous cycles only running workspaces.</li>
          <li>• Focusing a workspace sets it as the target for global window cycling.</li>
          <li>• When Muxy is not focused, next/previous cycles windows for the active or focused workspace.</li>
          <li>• Browser window disambiguation uses active tab URL matching in addition to window ID.</li>
        </ul>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Customization</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Keyboard bindings can be overridden in the Settings view and through CLI settings commands.
        </p>
        <pre className="mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-xl border border-line bg-background-soft/80 p-3 text-xs leading-6 text-foreground">
          <code>{`mx settings get --gui-hotkey
mx settings set --gui-hotkey cmd+shift+9
mx settings set --gui-next-shortcut cmd+shift+]
mx settings set --gui-prev-shortcut cmd+shift+[
mx settings reset --gui-hotkey`}</code>
        </pre>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Text Input Safety</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          When a text field is focused, Muxy does not intercept standard text-edit shortcuts
          such as copy, cut, paste, undo, redo, and select-all.
        </p>
      </article>

      <article className="grid gap-4 rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm md:grid-cols-2">
        <ScreenshotFrame
          title="Settings Shortcuts Panel"
          caption="Shortcut capture buttons and reset actions in the Settings view."
        />
        <ScreenshotFrame
          title="Workspace Inline Shortcut Hints"
          caption="Run tab showing action labels and dynamic `cmd+<n>` window hints."
        />
      </article>
    </DocsShell>
  );
}
