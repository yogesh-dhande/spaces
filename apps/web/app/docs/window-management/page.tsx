import type { Metadata } from "next";
import { ScreenshotFrame } from "../../components/screenshot-frame";
import { DocsShell } from "../components/docs-shell";

export const metadata: Metadata = {
  title: "Window Management",
  description: "How Muxy captures and focuses workspace windows.",
};

export default function WindowManagementDocsPage() {
  return (
    <DocsShell
      title="Window Management"
      description="Muxy maps workspace windows to captured IDs and browser URL targets so context switching stays deterministic across terminals and Chrome tabs."
      pagePath="/docs/window-management"
    >
      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Window Sources</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Terminal windows from workspace processes.</li>
          <li>• Browser tabs/windows discovered from browser session URL prefixes.</li>
          <li>• Terminal windows opened from workspace action buttons.</li>
          <li>• Reconciled window records persisted with workspace state.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Switching Order</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Workspace navigation is ordered for repeatability during rapid context switches.
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Browser session tabs first.</li>
          <li>• Terminal windows second.</li>
          <li>• Other captured windows third.</li>
          <li>• Subsequent next/previous navigation continues from remembered cycle position.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Browser Tab Matching</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Browser session matching is URL-prefix based.</li>
          <li>• Browser cleanup closes matching tabs only, never full Chrome windows.</li>
          <li>• If tabs already match session URLs, Muxy reuses them instead of opening duplicates.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Keyboard Window Focus</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• `cmd+1` through `cmd+9` focus numbered windows for the selected workspace.</li>
          <li>• Window shortcut hints are shown inline in the workspace detail pane.</li>
          <li>• `cmd+shift+]` and `cmd+shift+[` cycle workspace windows forward/backward.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Example Window Set</h2>
        <pre className="mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-lg border border-line/70 bg-background-soft/60 p-3 text-xs leading-6 text-foreground">
          <code>{`Workspace: feat/checkout
1. Google Chrome — http://localhost:21004/checkout
2. Google Chrome — https://github.com/org/repo/pull/912
3. iTerm2 — web process
4. iTerm2 — worker process`}</code>
        </pre>
      </article>

      <article className="grid gap-4 border-t border-line/70 pt-8 first:border-t-0 first:pt-0 md:grid-cols-2">
        <ScreenshotFrame
          title="Workspace Window List"
          caption="Window rows with inline `cmd+<n>` hints, app names, and titles/URLs."
        />
        <ScreenshotFrame
          title="Browser Session Focus"
          caption="Tracked browser entries focusing the matching tab by URL prefix."
        />
      </article>
    </DocsShell>
  );
}
