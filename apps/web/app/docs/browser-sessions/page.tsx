import type { Metadata } from "next";
import { ScreenshotFrame } from "../../components/screenshot-frame";
import { DocsShell } from "../components/docs-shell";

export const metadata: Metadata = {
  title: "Browser Sessions",
  description: "URL-based browser session orchestration per workspace.",
};

export default function BrowserSessionsDocsPage() {
  return (
    <DocsShell
      title="Browser Sessions"
      description="Browser sessions keep URL context attached to a workspace so launch, focus, and cleanup stay deterministic."
      pagePath="/docs/browser-sessions"
    >
      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Session Model</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Browser sessions are configured at project level and copied into workspace settings.</li>
          <li>• Each session entry is a URL prefix.</li>
          <li>• Sessions can use named port variables like `$FRONTEND_PORT` or `$API_PORT`.</li>
          <li>• Multiple session URLs can be attached to one workspace.</li>
        </ul>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Launch Behavior</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• On workspace launch, Spaceship ensures session URLs are open in Chrome.</li>
          <li>• Existing matching tabs are reused when possible.</li>
          <li>• Matching is based on URL prefix, not window title.</li>
          <li>• Matching browser tabs are attached to workspace window navigation.</li>
        </ul>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Focus and Cleanup Rules</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Focus actions target matching tabs using URL information.</li>
          <li>• If a tab matches multiple session URLs, it appears once in workspace navigation.</li>
          <li>• Browser cleanup closes matching tabs only.</li>
          <li>• Spaceship does not close full Chrome windows during workspace cleanup.</li>
        </ul>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Ordering and Multi-Workspace Safety</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Browser rows are ordered by browser session definition order, then URL.</li>
          <li>• Workspace window listings rescan Chrome tabs to keep navigation current.</li>
          <li>• This avoids routing global next/previous shortcuts to the wrong workspace.</li>
        </ul>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Example Browser Session Config</h2>
        <pre className="mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-xl border border-line bg-background-soft/80 p-3 text-xs leading-6 text-foreground">
          <code>{`browser_sessions:
  - url: http://localhost:$FRONTEND_PORT
  - url: http://localhost:$FRONTEND_PORT/admin
  - url: https://github.com/org/repo/pull/912
  - url: https://docs.example.com/runbook/checkout`}</code>
        </pre>
      </article>

      <article className="grid gap-4 rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm md:grid-cols-2">
        <ScreenshotFrame
          title="Workspace Browser Sessions"
          caption="Workspace settings tab with URL entries bound to the selected workspace."
        />
        <ScreenshotFrame
          title="Run Tab Browser Window Rows"
          caption="Browser rows in window list showing URL-oriented titles and keyboard indices."
        />
      </article>
    </DocsShell>
  );
}
