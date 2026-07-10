import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";

export const metadata: Metadata = {
  title: "iOS Companion",
  description: "Pair the Spaces iOS app with your Mac to watch and steer terminal sessions from your phone.",
};

export default function IOSDocsPage() {
  return (
    <DocsShell
      title="iOS Companion"
      description="The Spaces iOS app pairs with your Mac so you can check in on terminal sessions and coding agents from your phone."
      pagePath="/docs/ios"
    >
      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Pairing</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• On your Mac, open the Devices panel to show a pairing QR code, or run <code>spaces device pair</code> to print a <code>spaces://pair</code> link.</li>
          <li>• Scan the QR code with the Spaces iOS app, or open the printed link on your phone.</li>
          <li>• The iOS app pairs with any Mac or Linux device running Spaces. Pair more than one and switch between them from the app.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">What You Can Do</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Browse the live terminal sessions running across your workspaces.</li>
          <li>• Open a session to watch its output and type into it from your phone.</li>
          <li>• Check on a coding agent that&apos;s working or waiting on you while you&apos;re away from your desk.</li>
          <li>• Create a workspace in any existing project, and open or stop workspace terminals.</li>
          <li>• Run, stop, or restart configured processes and coding agents.</li>
          <li>• Open a workspace&apos;s browser sessions right inside the app &mdash; tap a row to load the dev server in an in-app web view with back, forward, reload, and Open in Safari, isolated per service just like Chrome on the Mac. See <a className="text-accent hover:underline" href="/docs/browser-sessions">Browser Sessions</a> for details.</li>
          <li>• Keep working even if the Mac app quit or crashed &mdash; as long as the Spaces daemon is reachable, acting from your phone brings the Mac app back automatically.</li>
        </ul>
      </article>
    </DocsShell>
  );
}
