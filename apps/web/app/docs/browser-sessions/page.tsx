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
          A browser session is a URL you want one focus away while the workspace is running — your local app, an admin page, a PR, a runbook. Configure them on the project and every workspace inherits them.
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Each session has a URL and an optional name.</li>
          <li>• URLs can reference a service&apos;s assigned port or its Caddy URL, for example <code>http://localhost:$SPACES_WEB_PORT</code> or <code>$SPACES_WEB_URL</code>. Chrome treats <code>*.localhost</code> as a secure loopback context, so these hosts resolve without extra setup.</li>
          <li>• For remote Linux workspaces, service browser sessions use the same Caddy URL on the Mac while Spaces forwards the daemon-local service port over SSH.</li>
          <li>• Attach as many as you need to a workspace.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Opening and Focusing</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Sessions stay closed when the workspace launches, so startup stays fast even with many URLs attached.</li>
          <li>• Focus a session with <code>cmd+1</code>…<code>cmd+0</code> or the command palette, and Spaces opens it as a Chrome tab in the workspace&apos;s tracked Chrome window when one is available.</li>
          <li>• If you move a session tab to another Chrome window, direct focus finds that matching URL and updates tracking.</li>
          <li>• Next/previous window cycling includes a browser session only after its tracked Chrome tab is open.</li>
          <li>• If you close a session&apos;s Chrome tab and then focus it again, Spaces reopens it.</li>
          <li>• Stopping the workspace closes the session tabs Spaces opened or adopted.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">On iPhone</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Browser sessions show up as rows in the iOS app too, alongside each workspace&apos;s processes, coding agents, and terminals.</li>
          <li>• Tap one to open the dev server right inside the app, with back, forward, reload, and Open in Safari controls — no need to unlock your Mac or remember a URL.</li>
          <li>• Cookies and local storage stay isolated per service, the same way they do in Chrome on the Mac.</li>
          <li>• This works for a remote Linux workspace too, and even while the Mac is asleep, as long as your phone is paired with the device that owns the workspace.</li>
          <li>• If the service isn&apos;t running yet, tapping the row shows a clear message instead of a blank page.</li>
          <li>• Open in Safari only works while Spaces is in the foreground; backgrounding the app closes the connection, and reopening it restores your sessions automatically.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Example</h2>
        <pre className="mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-lg border border-line/70 bg-background-soft/60 p-3 text-xs leading-6 text-foreground">
          <code>{`web        $SPACES_WEB_URL
admin      $SPACES_WEB_URL/admin
pr-review  https://github.com/org/repo/pull/912
           https://docs.example.com/runbook/checkout`}</code>
        </pre>
      </article>
    </DocsShell>
  );
}
