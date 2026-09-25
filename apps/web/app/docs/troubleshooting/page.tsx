import type { Metadata } from "next";
import { InlineCode } from "../components/code-block";
import { DocLink } from "../components/doc-link";
import { DocsShell } from "../components/docs-shell";
import { Prose, Section } from "../components/section";

const githubIssuesURL = "https://github.com/yogesh-dhande/spaces/issues";

export const metadata: Metadata = {
  title: "Troubleshooting",
  description:
    "Fixes for Chrome permission, setup, shortcut, device, and agent status problems.",
};

export default function TroubleshootingDocsPage() {
  return (
    <DocsShell
      title="Troubleshooting"
      description="Fixes for Chrome permission, setup, shortcut, device, and agent status problems."
      pagePath="/docs/troubleshooting"
    >
      <Section id="browser-sessions" title="Browser sessions">
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>
            • <strong>A browser session does not open or focus Chrome.</strong> Spaces controls Google
            Chrome under the macOS Automation permission. Enable Spaces for Google Chrome under System
            Settings ▸ Privacy &amp; Security ▸ Automation.
          </li>
          <li>
            • <strong>The permission prompt never appears.</strong> Reset the stale record with{" "}
            <InlineCode>tccutil reset AppleEvents dev.usespaces.spaces</InlineCode> in Terminal, then
            click &ldquo;Recheck&rdquo;.
          </li>
          <li>
            • <strong>A session opens nothing.</strong> Confirm the session has a valid URL and that
            Chrome is installed.
          </li>
        </ul>
      </Section>

      <Section id="setup" title="Setup failed">
        <Prose>
          See <DocLink href="/docs/workspaces#setup">Setup</DocLink> for the setup screen and its retry,
          log, and repair-terminal options. If a process exits during startup, its output shows in its
          own pane.
        </Prose>
      </Section>

      <Section title="Something keeps running after Stop">
        <Prose>
          Add the teardown command to the workspace&apos;s stop script so Stop cleans up state Spaces
          does not manage on its own.
        </Prose>
      </Section>

      <Section id="shortcuts" title="A shortcut does nothing">
        <Prose>
          Another app owns that key combination. Rebind Spaces&apos; shortcut in Settings → Shortcuts;
          see <DocLink href="/docs/shortcuts#changing-shortcuts">Changing shortcuts</DocLink>.
        </Prose>
      </Section>

      <Section id="devices" title="A device is unreachable or blocked">
        <Prose>
          Work through the checklist in{" "}
          <DocLink href="/docs/remote-access#troubleshooting">Remote machines</DocLink>. If it is a
          version mismatch, see <DocLink href="/docs/installation#updates">Updates</DocLink>.
        </Prose>
      </Section>

      <Section id="agents" title="Agent status missing">
        <Prose>
          Check Settings → Coding Agents for the agent&apos;s hook state; see{" "}
          <DocLink href="/docs/coding-agents#hooks">Status hooks</DocLink>.
        </Prose>
      </Section>

      <Section id="panes" title='A pane says "Session failed"'>
        <Prose>
          The device lost track of the session without recording how it ended, usually after a
          reboot or a crash of the Spaces service, not a normal Stop or Restart. See{" "}
          <DocLink href="/docs/restarts#reboot">What survives a restart</DocLink>.
        </Prose>
      </Section>

      <Section title="See recent output">
        <Prose>
          <InlineCode>spaces terminal tail &lt;session-id&gt;</InlineCode> prints a session&apos;s recent
          output from the command line.
        </Prose>
      </Section>

      <Section id="reporting-a-bug" title="Report a bug">
        <Prose>
          Open an issue on{" "}
          <a className="text-accent hover:underline" href={githubIssuesURL} target="_blank" rel="noopener noreferrer">
            GitHub
          </a>
          .
        </Prose>
      </Section>
    </DocsShell>
  );
}
