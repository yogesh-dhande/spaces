import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";
import { DocLink } from "../components/doc-link";
import { InlineCode } from "../components/code-block";
import { Prose, Section } from "../components/section";

export const metadata: Metadata = {
  title: "What survives a restart",
  description:
    "What keeps running when you quit Spaces, restart your Mac, or update, and how agents come back.",
};

export default function RestartsDocsPage() {
  return (
    <DocsShell
      title="What survives a restart"
      description="What quitting Spaces, restarting a machine, or updating does to your workspaces, and how agents come back afterward."
      pagePath="/docs/restarts"
    >
      <Section id="quitting" title="Quitting Spaces">
        <Prose>
          Quitting the Mac app asks what to do with this Mac&apos;s work: &quot;Quit and Keep
          Running&quot; (the default) leaves every workspace, process, terminal, and agent running on
          this Mac; &quot;Stop All and Quit&quot; stops this Mac&apos;s workspaces and ends its ad hoc
          terminals and agents first; &quot;Cancel&quot; leaves Spaces open. Neither option touches a
          paired remote device, which keeps running Spaces or not on its own.
        </Prose>
      </Section>

      <Section id="reboot" title="Restarting or shutting down a machine">
        <Prose>
          Restarting or shutting down a device ends every terminal, process, and agent running on it, the
          same as the Spaces service on that device crashing. Logging out of the macOS account on a Mac
          does the same, since the Spaces service runs in that login session. Logging out of a Linux
          machine does not: the installer enables lingering, so the Spaces service and everything running
          under it keep going without a login session open (see{" "}
          <DocLink href="/docs/remote-access#install-on-linux">install on Linux</DocLink>). Configured
          processes stay stopped until you start the workspace again. A pane whose session was lost this
          way shows &quot;Session failed. The process stopped unexpectedly.&quot; and stays read-only
          until you start that target again (see{" "}
          <DocLink href="/docs/workspaces#start-stop-and-restart">start, stop, and restart</DocLink>).
        </Prose>
      </Section>

      <Section id="restore" title="Bringing agents back">
        <Prose>
          A device keeps a record of the coding agents its work was cut short on: by a restart, logout,
          shutdown, a crash, or &quot;Stop All and Quit&quot;. Stopping a single workspace or a single
          agent yourself records nothing, since that is a deliberate end. On the next launch, or as soon
          as a device reports a record while Spaces is running, Spaces offers &quot;Restore all&quot; or
          &quot;Skip&quot; on both the Mac and the iPhone.
        </Prose>
        <Prose>
          Restoring relaunches each agent in the workspace and pane it was in, resuming its conversation
          when the agent supports that. An agent started as a one-shot run, such as{" "}
          <InlineCode>claude -p</InlineCode>, <InlineCode>codex exec</InlineCode>, or{" "}
          <InlineCode>opencode run</InlineCode> (but not <InlineCode>opencode run -i</InlineCode>, which
          resumes), has no conversation to resume, so it comes back as another run of the same command
          instead.
        </Prose>
      </Section>

      <Section id="updates" title="Updates">
        <Prose>
          Applying an update to the Mac app or to a device&apos;s Spaces service does not end its
          sessions: workspaces, processes, terminals, and agents keep running through it. See{" "}
          <DocLink href="/docs/installation#updates">updates</DocLink>.
        </Prose>
      </Section>

      <Section id="ended-sessions" title="Ended sessions">
        <Prose>
          A session that has ended, whether it exited cleanly, failed, or was closed, stays listed with
          its transcript viewable for seven days, up to 2 GB of ended-session data per device. Past
          either limit, the oldest ended sessions are removed first.
        </Prose>
      </Section>
    </DocsShell>
  );
}
