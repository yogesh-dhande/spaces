import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";
import { DocLink } from "../components/doc-link";
import { Prose, Section } from "../components/section";

export const metadata: Metadata = {
  title: "Resources",
  description:
    "See which terminals use the most CPU and memory on each device, and what Spaces itself costs.",
};

export default function ResourcesDocsPage() {
  return (
    <DocsShell
      title="Resources"
      description="Resources shows what the work in your terminals is costing each device, so you can find the build, test run, or agent that is slowing a machine down."
      pagePath="/docs/resources"
    >
      <Section id="measured" title="What it measures">
        <Prose>
          Open the Resources row in the sidebar, under Automations. Two cards stay separate and are
          never added together, so a heavy build never reads as Spaces&apos; own usage:
        </Prose>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Your terminals: the sum of every terminal on each device, with its core count and memory.</li>
          <li>• Spaces itself: the App line (this Mac&apos;s Spaces window, panes, and editor) and a Daemon line for the background service on each device.</li>
        </ul>
        <Prose>
          A device that is unreachable is named offline, and a device whose Spaces version is
          incompatible is left out (see{" "}
          <DocLink href="/docs/troubleshooting">Troubleshooting</DocLink>).
        </Prose>
      </Section>

      <Section id="table" title="The table">
        <Prose>
          Below the cards, every live terminal on every device is listed, busiest first. Click the CPU
          or Memory header to sort by that column. A terminal is named project, workspace, then
          terminal, with a sparkle when it runs a coding agent. Idle terminals are listed too. Switch
          to Workspaces to see one row per workspace, summing its terminals. The arrow button on a row,
          or a double-click, opens that terminal, or selects that workspace.
        </Prose>
        <Prose>
          CPU is a share of one core, so a busy process can pass 100%. Memory is the footprint
          Activity Monitor shows on a Mac, and resident memory on Linux. The &quot;Since opened&quot;
          column charts CPU from when you opened the pane, up to the last 10 minutes.
        </Prose>
        <Prose>
          A terminal&apos;s figures cover its shell and everything still attached to it. Processes that
          detach from a terminal, like Docker containers and background daemons, are not counted.
        </Prose>
      </Section>

      <Section id="sampling" title="When it measures">
        <Prose>
          Spaces measures only while the pane is open, every 2 seconds, with the first figure about 2
          seconds after you open it. Leave the pane and measurement stops and the history is
          discarded, so a closed pane costs nothing.
        </Prose>
      </Section>
    </DocsShell>
  );
}
