import type { Metadata } from "next";
import { DocLink } from "../components/doc-link";
import { DocsShell } from "../components/docs-shell";
import { Prose, Section, SubHeading } from "../components/section";

export const metadata: Metadata = {
  title: "Settings",
  description: "The Mac and iPhone settings, and where each is explained.",
};

export default function SettingsDocsPage() {
  return (
    <DocsShell
      title="Settings"
      description="Each control links to the page that explains what it does; this page is only the index."
      pagePath="/docs/settings"
    >
      <Section id="mac" title="On the Mac">
        <Prose>
          Open Settings with <code>⌘,</code> or the settings action in the sidebar footer.
        </Prose>

        <SubHeading>General</SubHeading>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>
            • &quot;Preferred editor&quot;: see{" "}
            <DocLink href="/docs/editor#other-editors">The Editor: Other editors</DocLink>.
          </li>
          <li>
            • &quot;Receive pre-release updates&quot;: see{" "}
            <DocLink href="/docs/installation#updates">Install on your Mac: Updates</DocLink>.
          </li>
          <li>• Appearance: System, Light, or Dark.</li>
        </ul>

        <SubHeading>Shortcuts</SubHeading>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Every configurable shortcut; see{" "}
          <DocLink href="/docs/shortcuts">Keyboard shortcuts</DocLink>.
        </p>

        <SubHeading>Devices</SubHeading>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>
            • &quot;Pair iPhone&quot;, Rename, Remove, and &quot;Add remote device over SSH&quot;:
            see <DocLink href="/docs/remote-access">Remote machines</DocLink>.
          </li>
          <li>
            • &quot;Restart Local Daemon&quot; restarts the Spaces service on this Mac.
          </li>
        </ul>

        <SubHeading>Coding Agents</SubHeading>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Status hooks for each agent; see{" "}
          <DocLink href="/docs/coding-agents#hooks">Agent status: Status hooks</DocLink>.
        </p>

        <SubHeading>MCP</SubHeading>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Per-client setup snippets; see <DocLink href="/docs/mcp#setup">MCP tools: Setup</DocLink>
          .
        </p>
      </Section>

      <Section id="ios" title="On the iPhone">
        <Prose>The settings you can change:</Prose>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>
            • Connection (Paired Devices): see{" "}
            <DocLink href="/docs/remote-access#pair-your-iphone">
              Remote machines: Pair your iPhone
            </DocLink>
            .
          </li>
          <li>
            • Subscription: its status, &quot;Manage Subscription&quot;, and &quot;Restore Purchases&quot;.
          </li>
          <li>• Appearance: theme, and terminal font size from 9 to 12 points.</li>
          <li>
            • Demo Mode: see <DocLink href="/docs/ios#demo-mode">iPhone app: Demo Mode</DocLink>.
          </li>
          <li>• About: the installed app version.</li>
        </ul>
      </Section>
    </DocsShell>
  );
}
