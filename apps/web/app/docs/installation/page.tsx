import type { Metadata } from "next";
import Link from "next/link";
import { CodeBlock, InlineCode } from "../components/code-block";
import { DocLink } from "../components/doc-link";
import { DocsShell } from "../components/docs-shell";
import { Prose, Section } from "../components/section";

const githubReleasesURL = "https://github.com/yogesh-dhande/spaces/releases/latest";

export const metadata: Metadata = {
  title: "Install on your Mac",
  description:
    "Requirements, installing the Mac app and its command-line tools, updates, and uninstalling.",
};

export default function InstallationDocsPage() {
  return (
    <DocsShell
      title="Install on your Mac"
      description="Requirements, installing the Mac app and its command-line tools, updates, and uninstalling."
      pagePath="/docs/installation"
    >
      <Section id="requirements" title="Requirements">
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• macOS 14 or later.</li>
          <li>• Google Chrome, for browser sessions.</li>
        </ul>
      </Section>

      <Section id="install" title="Install">
        <ol className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>
            1. Download the DMG from the{" "}
            <Link
              href={githubReleasesURL}
              className="text-accent hover:underline"
              target="_blank"
              rel="noopener noreferrer"
            >
              latest release
            </Link>
            .
          </li>
          <li>2. Double-click the DMG to mount it.</li>
          <li>
            3. Double-click <InlineCode>Install Spaces</InlineCode> in the DMG.
          </li>
          <li>
            4. Installing asks for an admin password. The installer copies{" "}
            <InlineCode>Spaces.app</InlineCode> to Applications, installs the command-line tools, and
            sets up the background service that keeps your terminal sessions running after you close
            the app.
          </li>
          <li>5. Eject the DMG.</li>
        </ol>
      </Section>

      <Section id="first-launch" title="First launch">
        <Prose>
          On first launch, Spaces shows only the setup steps that are still pending.
        </Prose>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>
            • <strong>Allow Spaces to control Google Chrome.</strong> Spaces focuses browser sessions
            by controlling Chrome, which macOS gates under Automation permission. Choose &ldquo;Grant
            Access&rdquo; and approve the macOS prompt, or &ldquo;Open System Settings&rdquo; if Chrome
            control was denied before; a &ldquo;Recheck&rdquo; button re-reads the permission. The step
            advances on its own once access is granted. If Chrome is not installed, this step does not
            appear.
          </li>
          <li>
            • <strong>Coding-agent hooks.</strong> Skippable, and offered again later in Settings →
            Coding Agents. See <DocLink href="/docs/coding-agents#hooks">Agent status</DocLink>.
          </li>
        </ul>
      </Section>

      <Section id="command-line-tools" title="Command-line tools">
        <Prose>
          Install places the <InlineCode>spaces</InlineCode> command at{" "}
          <InlineCode>/usr/local/bin/spaces</InlineCode>. Confirm it is on your <InlineCode>PATH</InlineCode>:
        </Prose>
        <CodeBlock>{`spaces --version`}</CodeBlock>
        <Prose>
          See the <DocLink href="/docs/cli">CLI reference</DocLink> for every command.
        </Prose>
      </Section>

      <Section id="updates" title="Updates">
        <Prose>
          The Mac app updates itself. Settings → General → &ldquo;Receive pre-release updates&rdquo; is
          off by default; turning it on means you get each release as soon as it is published, before
          it is promoted to everyone.
        </Prose>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Paired devices update the same way, without ending anything running on them. When a device has
          a newer Spaces installed than the one it is running, its row shows &ldquo;update pending&rdquo;
          while Spaces applies the update in place; running terminals, processes, and agents keep
          running throughout.
        </p>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          A device that is too old or too new to talk to shows both versions and the one fix that
          applies: open Spaces on a remote Mac, use &ldquo;Check for Updates&rdquo; on this Mac, or run
          the install command on a Linux machine (see{" "}
          <DocLink href="/docs/remote-access#update-and-uninstall-on-linux">
            updating Linux
          </DocLink>
          ). A Linux device paired over SSH also offers an &ldquo;Update over SSH&rdquo; action that runs
          the same command for you.
        </p>
      </Section>

      <Section id="uninstall" title="Uninstall">
        <Prose>To remove Spaces completely:</Prose>
        <CodeBlock>{`launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/dev.usespaces.spacesd.plist
rm -f ~/Library/LaunchAgents/dev.usespaces.spacesd.plist
rm -rf /Applications/Spaces.app
sudo rm -f /usr/local/bin/spaces /usr/local/bin/spacesd /usr/local/bin/spaces-caddy
sudo rm -f /usr/local/bin/libghostty-vt*.dylib
rm -f ~/.spaces/bin/spaces ~/.spaces/bin/spacesd
rm -rf ~/.spaces ~/spaces`}</CodeBlock>
        <Prose>
          <InlineCode>~/.spaces</InlineCode> holds the local database; <InlineCode>~/spaces</InlineCode>{" "}
          holds any git repos Spaces cloned for you and your workspace worktrees. Leave them alone if
          you want to keep that state.
        </Prose>
      </Section>

      <Section id="install-on-linux" title="Install on Linux">
        <Prose>
          A Linux machine runs Spaces as a remote device. See{" "}
          <DocLink href="/docs/remote-access#install-on-linux">Remote machines</DocLink> for the install
          command and pairing.
        </Prose>
      </Section>
    </DocsShell>
  );
}
