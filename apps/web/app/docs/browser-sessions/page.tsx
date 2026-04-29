import type { Metadata } from "next";
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
      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">What Is a Browser Session?</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          A browser session is a URL you want open whenever the workspace is running — your local app, an admin page, a PR, a runbook. Configure them on the project and Spaces opens them for every workspace.
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Each session has a URL and an optional name.</li>
          <li>• URLs can reference your named ports, for example <code>http://localhost:$FRONTEND_PORT</code>.</li>
          <li>• Attach as many as you need to a workspace.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">When the Workspace Launches</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Spaces opens each session in its own Chrome window.</li>
          <li>• Session rows show up in the workspace&apos;s window list, focusable with <code>cmd+1</code>…<code>cmd+9</code>.</li>
          <li>• If you close a session&apos;s Chrome window and then focus it again, Spaces reopens it.</li>
          <li>• Stopping the workspace closes the windows Spaces opened.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Example</h2>
        <pre className="mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-lg border border-line/70 bg-background-soft/60 p-3 text-xs leading-6 text-foreground">
          <code>{`frontend   http://localhost:$FRONTEND_PORT
admin      http://localhost:$FRONTEND_PORT/admin
pr-review  https://github.com/org/repo/pull/912
           https://docs.example.com/runbook/checkout`}</code>
        </pre>
      </article>
    </DocsShell>
  );
}
