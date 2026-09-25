import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";
import { DocLink } from "../components/doc-link";
import { PhoneFrame } from "../../components/device-frames";
import { Card, Prose, Section, SectionHeading } from "../components/section";

const githubIssuesURL = "https://github.com/yogesh-dhande/spaces/issues";

export const metadata: Metadata = {
  title: "iPhone app",
  description:
    "A full Spaces client for iPhone and iPad that connects straight to your Mac or Linux machines.",
};

export default function IOSDocsPage() {
  return (
    <DocsShell
      title="iPhone app"
      description="A full Spaces client for iPhone and iPad that connects straight to your Mac or Linux machines."
      pagePath="/docs/ios"
    >
      <Section id="availability" title="Availability">
        <Prose>
          The Spaces iOS app is an invite-only TestFlight beta for iPhone and iPad, on iOS 17 or later.{" "}
          <a className="text-accent hover:underline" href={githubIssuesURL} target="_blank" rel="noopener noreferrer">
            Ask for an invite
          </a>{" "}
          by opening an issue on GitHub. The app asks you to start a subscription before it opens; in the
          TestFlight beta that is a test purchase, and you are not charged.
        </Prose>
      </Section>

      <Section title="A full client">
        <Prose>
          The iOS app connects directly to any paired device, your Mac or a Linux machine, and works on
          its own: there is no Mac in the path. It keeps showing an offline device&apos;s rows, so you
          can see what was there even while it is unreachable.
        </Prose>
      </Section>

      <Section title="Pairing">
        <Prose>
          See <DocLink href="/docs/remote-access#pair-your-iphone">Pair your iPhone</DocLink>.
        </Prose>
      </Section>

      <Card id="tabs">
        <div className="grid items-start gap-8 lg:grid-cols-[minmax(0,1fr)_minmax(0,18rem)]">
          <div className="min-w-0">
            <SectionHeading>Tabs</SectionHeading>
            <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
              <li>• <strong>Alerts</strong>: blocked and finished agents, exited processes, terminals that exited or failed, bells, and failed or timed-out automation runs, for the device you have selected.</li>
              <li>• <strong>Spaces</strong>: your projects and workspaces, with their targets.</li>
              <li>• <strong>Agents</strong>: running coding agents, grouped Blocked, Done, and Working; an agent that isn&apos;t running stays reachable from its workspace on the Spaces tab.</li>
              <li>• <strong>Automations</strong>: your automations and their runs.</li>
              <li>• <strong>Settings</strong>: paired devices, subscription, appearance, and Demo Mode.</li>
            </ul>
          </div>

          <div className="mx-auto w-full max-w-[280px]">
            <PhoneFrame
              src="/media/ios-sessions.png"
              alt="The Spaces iOS app showing a workspace's live terminal sessions and coding agents with their status"
            />
          </div>
        </div>
      </Card>

      <Card id="terminals">
        <div className="grid items-start gap-8 lg:grid-cols-[minmax(0,1fr)_minmax(0,18rem)]">
          <div className="min-w-0">
            <SectionHeading>Terminals</SectionHeading>
            <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
              <li>• Open a session to watch its output and type into it, the same shell every other client sees.</li>
              <li>• Compose a longer message and attach an image, then send it in one go.</li>
              <li>• A tap acts as a click when the program inside the session tracks the mouse.</li>
              <li>• A connection banner with Retry shows when the app cannot reach the session&apos;s device.</li>
            </ul>
          </div>

          <div className="mx-auto w-full max-w-[280px]">
            <PhoneFrame
              src="/media/ios-terminal.png"
              alt="A live terminal session open in the Spaces iOS app, showing output and an input field"
            />
          </div>
        </div>
      </Card>

      <Section title="Workspaces and processes">
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Create, hide, and delete workspaces.</li>
          <li>• Start, stop, and restart a workspace&apos;s configured processes.</li>
        </ul>
      </Section>

      <Section id="agents" title="Agents">
        <Prose>
          View and open a running coding agent from the Agents tab; one that isn&apos;t running is
          still reachable from its workspace on the Spaces tab. From the app you can stop an agent;
          starting one happens from a terminal, or by running an agent automation from the{" "}
          <DocLink href="/docs/automations">Automations</DocLink> tab, the same as on the Mac.
        </Prose>
      </Section>

      <Section title="Browser sessions">
        <Prose>
          See <DocLink href="/docs/browser-sessions#on-iphone">Browser sessions on iPhone</DocLink>.
        </Prose>
      </Section>

      <Section id="demo-mode" title="Demo Mode">
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>
            • Turn on &ldquo;Demo Mode&rdquo; from Settings, or tap &ldquo;Try Demo Mode&rdquo; on the
            Spaces tab, to tour the app with sample data, workspaces, coding agents, alerts, and
            terminals, without pairing a device.
          </li>
          <li>
            • Demo terminals are read-only and have no scrollback: you can watch a session&apos;s
            recorded screen, and typing starts once you pair your own device. A banner keeps the
            sample-data context clear, and one tap turns it off.
          </li>
        </ul>
      </Section>
    </DocsShell>
  );
}
