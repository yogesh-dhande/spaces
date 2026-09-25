import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";
import { DocLink } from "../components/doc-link";
import { InlineCode } from "../components/code-block";
import { Prose, Section } from "../components/section";

export const metadata: Metadata = {
  title: "Alerts",
  description:
    "One list of what needs you: blocked and finished agents, exited processes, bells, and failed automation runs.",
};

export default function AlertsDocsPage() {
  return (
    <DocsShell
      title="Alerts"
      description="Alerts is one list of what needs your attention, across every workspace and every paired device."
      pagePath="/docs/alerts"
    >
      <Section id="sources" title="What raises an alert">
        <Prose>These put a row in Alerts:</Prose>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>
            • A coding agent waiting on you (see{" "}
            <DocLink href="/docs/coding-agents#states">agent states</DocLink>).
          </li>
          <li>• A coding agent that finished.</li>
          <li>• A configured process that exited.</li>
          <li>
            • A terminal bell, while you were not looking at that terminal. A bell in a terminal that
            already has keyboard focus, or is open in the iPhone terminal viewer, does not raise an
            alert, since you already heard it.
          </li>
          <li>• A failed or timed-out automation run.</li>
          <li>• On iPhone, an ad hoc terminal (one opened directly, not a configured process) that exited or failed.</li>
        </ul>
      </Section>

      <Section id="where" title="Where alerts show">
        <Prose>
          The sidebar&apos;s Alerts row (<InlineCode>⌘⌥A</InlineCode>, which works inside Spaces and is
          not a global key), first in the command palette, the Alerts cycling mode, and the iPhone
          Alerts tab. The Mac sidebar aggregates alerts across every paired device; the iPhone Alerts tab
          shows only the currently selected device. A hidden workspace or project is skipped, the same as
          everywhere else it is hidden from (see{" "}
          <DocLink href="/docs/workspaces#hiding">hiding</DocLink>).
        </Prose>
      </Section>

      <Section id="dismissing" title="Dismissing an alert">
        <Prose>
          Dismiss one alert from its row (&quot;Dismiss Alert&quot;), with <InlineCode>⌘X</InlineCode>{" "}
          in the command palette, or with &quot;Clear&quot; on iPhone, which dismisses every alert on
          screen at once. A dismissed alert stays dismissed until the event behind it changes again,
          except a blocked agent&apos;s alert: that one clears on its own the moment the agent starts
          working again.
        </Prose>
        <Prose>
          Dismissing an alert only removes it from Alerts. It never hides the process or agent row it
          came from, which stays where it is in the sidebar.
        </Prose>
      </Section>

      <Section id="badges" title="Badges">
        <Prose>
          The sidebar&apos;s Alerts row and the Dock icon both carry a count of undismissed alerts.
        </Prose>
      </Section>
    </DocsShell>
  );
}
