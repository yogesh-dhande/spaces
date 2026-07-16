import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";

export const metadata: Metadata = {
  title: "iOS Companion",
  description: "Your terminals and coding agents in your pocket — pair the Spaces iOS app with a Mac or Linux device to watch and steer live sessions from your phone.",
};

export default function IOSDocsPage() {
  return (
    <DocsShell
      title="iOS Companion"
      description="Your terminals and coding agents, in your pocket. The Spaces iOS app pairs with any Mac or Linux device so you can watch live sessions and steer coding agents from your phone."
      pagePath="/docs/ios"
    >
      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <div className="grid items-start gap-8 lg:grid-cols-[minmax(0,1fr)_minmax(0,18rem)]">
          <div className="min-w-0">
            <h2 className="text-2xl font-semibold tracking-tight">Check on your coding agents from anywhere</h2>
            <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
              <li>• Browse the live terminal sessions running across all your workspaces, with the coding agents that are working or waiting on you called out at a glance.</li>
              <li>• Catch an agent that&apos;s blocked on you and clear it, or watch a build finish, without walking back to your desk.</li>
              <li>• Create a workspace in any existing project, and open or stop its terminals.</li>
              <li>• Run, stop, or restart configured processes and coding agents.</li>
            </ul>
          </div>

          <figure className="mx-auto w-full max-w-[280px] overflow-hidden rounded-[2rem] border border-line/80 bg-surface/60 shadow-[0_40px_100px_-60px_color-mix(in_oklab,var(--ink)_55%,transparent)]">
            <img
              src="/media/ios-sessions.png"
              alt="The Spaces iOS app showing a workspace's live terminal sessions and coding agents with their status"
              className="aspect-[9/19.5] h-auto w-full object-cover"
            />
          </figure>
        </div>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <div className="grid items-start gap-8 lg:grid-cols-[minmax(0,1fr)_minmax(0,18rem)]">
          <div className="min-w-0">
            <h2 className="text-2xl font-semibold tracking-tight">Jump into any session</h2>
            <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
              <li>• Open a session to watch its output stream in and type into the same shell — answer an agent&apos;s prompt, run a command, or nudge a stuck task.</li>
              <li>• Compose a longer, multi-line message and attach a screenshot or image, then send it to the session in one go.</li>
              <li>• Everything you send goes to the same live session your Mac is attached to, so your phone and your desk stay in sync.</li>
            </ul>
          </div>

          <figure className="mx-auto w-full max-w-[280px] overflow-hidden rounded-[2rem] border border-line/80 bg-surface/60 shadow-[0_40px_100px_-60px_color-mix(in_oklab,var(--ink)_55%,transparent)]">
            <img
              src="/media/ios-terminal.png"
              alt="A live terminal session open in the Spaces iOS app, showing output and an input field"
              className="aspect-[9/19.5] h-auto w-full object-cover"
            />
          </figure>
        </div>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Open browser sessions on your phone</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• A workspace&apos;s browser sessions show up as rows in the app. Tap one to load the dev server right inside an in-app web view — no need to unlock your Mac or remember a URL.</li>
          <li>• Each web view has back, forward, reload, and screenshot controls, and stays isolated per service just like Chrome on the Mac.</li>
          <li>• This works for a remote Linux workspace too, and even while the Mac is asleep. See <a className="text-accent hover:underline" href="/docs/browser-sessions">Browser Sessions</a> for details.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Runs with or without the desktop app</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Your sessions run in the Spaces daemon, not the desktop app, so they keep running even if the Mac app quit or crashed.</li>
          <li>• Acting from your phone works whether or not the desktop app is open — the daemon handles it directly, no need to reopen anything on the Mac.</li>
          <li>• The next time you open the Mac app, it reattaches to the same live sessions right where they were.</li>
          <li>• Steer workspaces on a remote Linux device the same way you would a Mac.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <div className="flex flex-wrap items-center gap-3">
          <h2 className="text-2xl font-semibold tracking-tight">Pairing</h2>
          <span className="inline-flex rounded-full border border-accent-2/50 px-2 py-0.5 font-mono text-[0.62rem] uppercase tracking-[0.18em] text-accent-2">
            Coming soon
          </span>
        </div>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• On your Mac, open the Devices panel to show a pairing QR code, or run <code>spaces device pair</code> to print a <code>spaces://pair</code> link.</li>
          <li>• Scan the QR code with the Spaces iOS app, or open the printed link on your phone.</li>
          <li>• The iOS app pairs with any Mac or Linux device running Spaces. Pair more than one and switch between them from the app.</li>
          <li>• The iOS app is $29/year, with a 7-day free trial. Spaces on Mac and Linux is free.</li>
        </ul>
      </article>
    </DocsShell>
  );
}
