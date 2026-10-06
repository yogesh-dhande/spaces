import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";
import { DocLink } from "../components/doc-link";
import { InlineCode } from "../components/code-block";
import { Prose, Section } from "../components/section";

export const metadata: Metadata = {
  title: "Alerts",
  description:
    "One list of what needs you: blocked and finished agents, exited processes and terminals, bells, failed automation runs, and terminals you marked to come back to.",
};

export default function AlertsDocsPage() {
  return (
    <DocsShell
      title="Alerts"
      description="Alerts is one list of what needs your attention, across every workspace and every paired device."
      pagePath="/docs/alerts"
    >
      <Section id="sources" title="What raises an alert">
        <Prose>These put a row in Alerts, on the Mac and on iPhone alike:</Prose>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>
            • A coding agent waiting on you (see{" "}
            <DocLink href="/docs/coding-agents#states">agent states</DocLink>).
          </li>
          <li>• A coding agent that finished.</li>
          <li>• A configured process that exited.</li>
          <li>• A terminal (one opened directly, not a configured process) that exited or failed.</li>
          <li>
            • A terminal bell, while you were not looking at that terminal. A bell in a terminal that
            already has keyboard focus, or is open in the iPhone terminal viewer, does not raise an
            alert on any of your devices, since you already heard it.
          </li>
          <li>• A failed or timed-out automation run.</li>
          <li>
            • An agent, process, or terminal you marked{" "}
            <DocLink href="/docs/alerts#come-back-later">Come Back Later</DocLink>.
          </li>
        </ul>
        <Prose>
          Terminals and processes ended by a Mac restart or logout, or by the Spaces service
          restarting or crashing, raise no exited alert, and those processes show as not started.
          A terminal&apos;s bell and failed automation runs still alert.
        </Prose>
      </Section>

      <Section id="where" title="Where alerts show">
        <Prose>
          The sidebar&apos;s Alerts row (<InlineCode>⌘⌥A</InlineCode>, which works inside Spaces and is
          not a global key), first in the command palette, the Alerts cycling mode, and the iPhone
          Alerts tab. Both the Mac sidebar and the iPhone Alerts tab aggregate alerts across every paired
          device, newest first, with no per-device or per-workspace grouping. A row names its project and
          workspace, and names its device too whenever more than one device is paired or any paired
          device is offline. A hidden workspace or project is skipped, the same as everywhere else it is
          hidden from (see <DocLink href="/docs/workspaces#hiding">hiding</DocLink>).
        </Prose>
        <Prose>
          <InlineCode>⌘1</InlineCode> through <InlineCode>⌘9</InlineCode>, and{" "}
          <InlineCode>⌘0</InlineCode> for the tenth, follow that same order on the Mac, and clicking a
          row does the same thing its number does. On iPhone, tapping another paired device&apos;s row
          opens its terminal without switching which device is selected elsewhere in the app. A paired
          device that has gone unreachable keeps its alerts listed, dimmed, with its last-known state,
          rather than dropping them.
        </Prose>
      </Section>

      <Section id="visiting" title="Visiting clears finished work">
        <Prose>
          Staying on a terminal for about 2 seconds clears its finished work: a finished agent, an
          exited process, and a terminal that exited or failed. On the Mac, that means its pane has
          keyboard focus while Spaces is the frontmost app. On iPhone, it means the terminal is open
          with the app in the foreground, counted from when its content appears. An alert that arrives
          while you are on the terminal clears after the same 2 seconds.
        </Prose>
        <Prose>
          An agent waiting on you stays in Alerts until you answer it or dismiss it, and bells follow
          their own rule above. You leave a terminal by focusing another one, closing the iPhone
          terminal viewer, or switching to another app.
        </Prose>
      </Section>

      <Section id="come-back-later" title="Come Back Later">
        <Prose>
          Come Back Later keeps an agent, process, or terminal in Alerts until you return to it. On
          the Mac, mark the focused terminal with the bell button in its pane footer, the pane&apos;s
          &quot;&#8943;&quot; menu, or <InlineCode>⌘⌥L</InlineCode>, or mark any row from its
          right-click menu in the sidebar. On iPhone, use the terminal&apos;s &quot;&#8943;&quot; menu
          or the long-press menu on a Spaces or Agents tab row.
        </Prose>
        <Prose>
          A marked row counts in the badges and in alert cycling like any other alert, and the mark
          lasts through restarts. It clears on your next visit to that terminal, so marking the
          terminal you are on keeps the mark until you leave and come back. Remove from Alerts, in the
          same menus, or dismissing its alert clears it too. Come Back Later is not offered on a
          process that has never started.
        </Prose>
      </Section>

      <Section id="dismissing" title="Dismissing an alert">
        <Prose>
          Dismiss one alert from its row (&quot;Dismiss Alert&quot;), with <InlineCode>⌘X</InlineCode>{" "}
          in the command palette, or with &quot;Clear All&quot; on the Mac or &quot;Clear&quot; on
          iPhone, which dismiss every listed alert across every reachable paired device at once. The
          device an alert came from keeps its dismissal, so dismissing it on one of your devices
          dismisses it on all of them. A dismissed
          alert stays dismissed until the event behind it changes again, except a blocked agent&apos;s
          alert: that one clears on its own the moment the agent starts working again.
        </Prose>
        <Prose>
          An unreachable device&apos;s alerts cannot be dismissed or marked until it is back. Dismissing
          an alert only removes it from Alerts. It never hides the process or agent row it came from,
          which stays where it is in the sidebar. A process whose exit you dismissed shows as not
          started until it exits again.
        </Prose>
      </Section>

      <Section id="badges" title="Badges">
        <Prose>
          The sidebar&apos;s Alerts row, the Dock icon, and the iPhone Alerts tab each carry a count of
          undismissed alerts.
        </Prose>
      </Section>
    </DocsShell>
  );
}
