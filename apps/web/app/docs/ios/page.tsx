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
          <li>• On your Mac, open the Devices panel or run <code>spaces pair</code> to show a pairing QR code.</li>
          <li>• Scan it with the Spaces iOS app, or open the link on your phone.</li>
          <li>• Pair more than one Mac and switch between them from the app.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">What You Can Do</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Browse the live terminal sessions running across your workspaces.</li>
          <li>• Open a session to watch its output and type into it from your phone.</li>
          <li>• Check on a coding agent that&apos;s working or waiting on you while you&apos;re away from your desk.</li>
          <li>• Relaunch the Mac app remotely if it quit or crashed.</li>
        </ul>
      </article>
    </DocsShell>
  );
}
