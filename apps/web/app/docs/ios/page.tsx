import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";
import { PhoneFrame } from "../../components/device-frames";

export const metadata: Metadata = {
  title: "iOS App",
  description: "Your terminals and coding agents in your pocket — the Spaces iOS app pairs directly with any Mac or Linux device to watch and steer live sessions from your phone.",
};

export default function IOSDocsPage() {
  return (
    <DocsShell
      title="iOS App"
      description="Your terminals and coding agents, in your pocket. The Spaces iOS app is a full client, not a remote for the Mac app: it pairs directly with any Mac or Linux device running Spaces and talks to it on its own."
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

          <div className="mx-auto w-full max-w-[280px]">
            <PhoneFrame
              src="/media/ios-sessions.png"
              alt="The Spaces iOS app showing a workspace's live terminal sessions and coding agents with their status"
            />
          </div>
        </div>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <div className="grid items-start gap-8 lg:grid-cols-[minmax(0,1fr)_minmax(0,18rem)]">
          <div className="min-w-0">
            <h2 className="text-2xl font-semibold tracking-tight">Jump into any session</h2>
            <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
              <li>• Open a session to watch its output stream in and type into the same shell — answer an agent&apos;s prompt, run a command, or nudge a stuck task.</li>
              <li>• Compose a longer, multi-line message and attach a screenshot or image, then send it to the session in one go.</li>
              <li>• Everything you send goes to the one live session on the device that owns it, so every client watching — your phone, your Mac — stays in sync.</li>
            </ul>
          </div>

          <div className="mx-auto w-full max-w-[280px]">
            <PhoneFrame
              src="/media/ios-terminal.png"
              alt="A live terminal session open in the Spaces iOS app, showing output and an input field"
            />
          </div>
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
        <h2 className="text-2xl font-semibold tracking-tight">The Mac app is never in the middle</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• The iOS app works by communicating directly to a connected device - any mac or linux machine running a Spaces daemon.</li>
          <li>• Your sessions run in the Spaces daemon, not the desktop app, so they keep running even if the Mac app quit or crashed.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Try Spaces without a Mac</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Not set up yet? Turn on <strong>Demo Mode</strong> from Settings, or tap <strong>Try Demo Mode</strong> on the Spaces tab, to tour the whole app with sample data — workspaces, coding agents, alerts, and terminals — before you pair a single device.</li>
          <li>• Demo terminals are read-only: you can watch and scroll a session, and typing into a terminal starts once you pair your own Mac. A banner keeps the sample-data context clear, and one tap turns it off.</li>
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
          <li>• On your Mac, open <strong>Settings → Devices</strong>. Every device connected to that Mac is listed — the Mac itself and each remote Mac or Linux box — and each one offers its own pairing QR code.</li>
          <li>• Show the QR code for the device you want your phone to reach, scan it with the Spaces iOS app, and you&apos;re paired. Repeat for as many devices as you like; the app switches between them and shows one at a time.</li>
          <li>• Pairing your phone to a Linux box works the same way, from the same Mac screen. The Mac only hands over the credential — once paired, your phone talks to that Linux daemon directly and the Mac is no longer involved.</li>
          <li>• If you&apos;d rather not go through a Mac at all, <code>spaces device pair</code> on any device prints a <code>spaces://pair</code> link you can open on your phone.</li>
          <li>• Once paired, your phone reconnects from the local network or over Tailscale — if you&apos;re away from home, keep Tailscale connected on your phone and the paired device and Spaces finds it automatically.</li>
          <li>• The iOS app is $29.99/year, with a 7-day free trial. Spaces on Mac and Linux is free.</li>
        </ul>
      </article>
    </DocsShell>
  );
}
