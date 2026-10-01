import type { Metadata } from "next";
import { SiteHeader } from "../components/site-header";
import { SiteFooter } from "../components/site-footer";

const githubDiscussionsURL = "https://github.com/yogesh-dhande/spaces/discussions";

export const metadata: Metadata = {
  title: "Privacy Policy",
  description:
    "The Spaces apps have no accounts, collect no personal data, and route nothing through developer-operated servers. The website counts visits without cookies.",
};

export default function PrivacyPolicyPage() {
  return (
    <div className="relative min-h-screen overflow-x-clip">
      <SiteHeader />

      <main className="mx-auto w-full max-w-3xl px-6 pb-20">
        <section className="border-b border-line/70 pb-10 pt-10 md:pt-14">
          <h1 className="text-3xl font-semibold leading-tight tracking-tight md:text-5xl">
            Privacy Policy
          </h1>
          <p className="mt-4 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
            Effective October 1, 2026. Spaces (the macOS app, the iOS app, and the
            <code className="mx-1 rounded bg-background-soft px-1.5 py-0.5 text-sm">spacesd</code>
            daemon) is built so your terminal and workspace data never has a reason to leave your
            own devices. This website, usespaces.dev, counts visits; the &ldquo;This website&rdquo;
            section explains exactly what it records.
          </p>
        </section>

        <div className="space-y-10 pt-10">
          <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
            <h2 className="text-2xl font-semibold tracking-tight">No accounts, no sign-in</h2>
            <p className="mt-3 text-sm leading-7 text-foreground-soft">
              Spaces does not ask you to create an account or sign in. There is no
              developer-operated identity system behind the app.
            </p>
          </article>

          <article className="border-t border-line/70 pt-8">
            <h2 className="text-2xl font-semibold tracking-tight">No data collection in the apps</h2>
            <p className="mt-3 text-sm leading-7 text-foreground-soft">
              The developer collects no personal data from the Spaces apps or the daemon. They
              contain no analytics, no usage tracking, and no third-party SDK phoning data home,
              and they do not report what you run, what you type, or which projects and
              workspaces you have.
            </p>
          </article>

          <article className="border-t border-line/70 pt-8">
            <h2 className="text-2xl font-semibold tracking-tight">Your data stays on your devices</h2>
            <p className="mt-3 text-sm leading-7 text-foreground-soft">
              Terminal output, workspace state, and everything else Spaces manages flows directly
              between your own devices — for example, your iPhone and your Mac, or your Mac and a
              remote Linux box you control — over a TLS connection pinned to that device&apos;s
              certificate. None of it is routed through, or stored on, servers operated by the
              developer. Pairing only ever connects to a device you chose to pair.
            </p>
          </article>

          <article className="border-t border-line/70 pt-8">
            <h2 className="text-2xl font-semibold tracking-tight">Pairing credentials</h2>
            <p className="mt-3 text-sm leading-7 text-foreground-soft">
              When you pair a device, Spaces stores the resulting credentials locally on that
              device only: in the iOS Keychain on iPhone, and in owner-only local files on Mac and
              Linux. Credentials are never uploaded anywhere and are removed when you unpair a
              device.
            </p>
          </article>

          <article className="border-t border-line/70 pt-8">
            <h2 className="text-2xl font-semibold tracking-tight">Camera use</h2>
            <p className="mt-3 text-sm leading-7 text-foreground-soft">
              The iOS app requests camera access for one purpose: scanning the pairing QR code
              shown on your Mac or Linux device. Scanning is processed entirely on your iPhone —
              no image or video is stored or transmitted anywhere.
            </p>
          </article>

          <article className="border-t border-line/70 pt-8">
            <h2 className="text-2xl font-semibold tracking-tight">Subscriptions</h2>
            <p className="mt-3 text-sm leading-7 text-foreground-soft">
              The iOS app&apos;s subscription is purchased and managed through Apple via the App
              Store. Apple handles payment; the developer never receives your payment details.
            </p>
          </article>

          <article className="border-t border-line/70 pt-8">
            <h2 className="text-2xl font-semibold tracking-tight">This website</h2>
            <p className="mt-3 text-sm leading-7 text-foreground-soft">
              usespaces.dev uses PostHog, a product analytics service, to count visits, so the
              developer can see which pages and links bring people to Spaces. It records the pages
              you view, the site that sent you, campaign tags and ad click IDs in the link (such as
              utm_source or gclid), which Download link you clicked, and your browser and device
              type. It does not record your IP address or your location.
            </p>
            <p className="mt-3 text-sm leading-7 text-foreground-soft">
              The site sets no cookies and stores nothing in your browser. PostHog tells visits
              apart with a hash of your IP address and browser that changes every day, so visits
              on different days cannot be linked to each other. There is no session recording, no
              click tracking beyond the Download links, and nothing you type is recorded. If your
              browser sends Do Not Track or Global Privacy Control, the site does not load PostHog
              at all, and blocking it with a content blocker does not change how the site works.
              PostHog processes this data in the United States.
            </p>
            <p className="mt-3 text-sm leading-7 text-foreground-soft">
              None of this applies to the Spaces apps or the daemon.
            </p>
          </article>

          <article className="border-t border-line/70 pt-8">
            <h2 className="text-2xl font-semibold tracking-tight">Changes to this policy</h2>
            <p className="mt-3 text-sm leading-7 text-foreground-soft">
              If this policy changes, the update will be published on this page with a new
              effective date.
            </p>
          </article>

          <article className="border-t border-line/70 pt-8">
            <h2 className="text-2xl font-semibold tracking-tight">Contact</h2>
            <p className="mt-3 text-sm leading-7 text-foreground-soft">
              Questions about this policy? Start a discussion on{" "}
              <a href={githubDiscussionsURL} className="text-accent hover:underline">
                GitHub
              </a>
              .
            </p>
          </article>
        </div>
      </main>

      <SiteFooter />
    </div>
  );
}
