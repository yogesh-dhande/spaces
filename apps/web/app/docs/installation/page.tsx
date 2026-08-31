import type { Metadata } from "next";
import { CodeBlock, InlineCode } from "../components/code-block";
import { DocsShell } from "../components/docs-shell";
import { Prose, Section } from "../components/section";
import Link from "next/link";

const githubReleasesURL = "https://github.com/yogesh-dhande/spaces/releases/latest";

export const metadata: Metadata = {
  title: "Installation & Setup",
  description:
    "Download Spaces, install dependencies, verify your setup on macOS and Linux, and prepare a remote machine or cloud VM for pairing.",
};

export default function InstallationDocsPage() {
  return (
    <DocsShell
      title="Installation & Setup"
      description="Download the latest release, install dependencies, and get Spaces running on your Mac, plus the daemon on any Linux machine you want to work on and what a remote machine or cloud VM needs before it can pair."
      pagePath="/docs/installation"
    >
      <Section title="Download">
        <Prose>
          Grab the latest release:
        </Prose>
        <p className="mt-3">
          <Link
            href={githubReleasesURL}
            className="inline-flex rounded-full border border-line px-4 py-2 text-sm font-semibold transition-colors hover:border-accent hover:text-accent"
            target="_blank"
            rel="noopener noreferrer"
          >
            Download Latest Release
          </Link>
        </p>
      </Section>

      <Section title="Install">
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
          <li>
            2. Double-click the DMG to mount it.
          </li>
          <li>
            3. Double-click <InlineCode>Install Spaces</InlineCode> in the DMG.
          </li>
          <li>
            4. The installer copies <InlineCode>Spaces.app</InlineCode>, links the required <InlineCode>spaces</InlineCode> CLI and <InlineCode>spacesd</InlineCode> daemon helpers to the app bundle, and sets up the per-user background service (LaunchAgent) that keeps your terminal sessions alive.
          </li>
          <li>
            5. Eject the DMG.
          </li>
        </ol>
      </Section>

      <Section title="Dependencies">
        <Prose>
          Spaces relies on Google Chrome for browser sessions. Install it before launching.
        </Prose>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <strong>Google Chrome</strong> — required for browser sessions. Download from <a href="https://www.google.com/chrome/" className="text-accent hover:underline" target="_blank" rel="noopener noreferrer">google.com/chrome</a> or install with <InlineCode>brew install --cask google-chrome</InlineCode>.</li>
          <li>• <strong>Automation permission</strong> — Spaces controls Google Chrome to focus browser sessions, which macOS gates under Privacy &amp; Security ▸ Automation. On first launch Spaces shows a setup screen to grant it; you can also enable it later from System Settings.</li>
        </ul>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Spaces includes its own terminal, so workspaces do not depend on any external terminal app.
        </p>
      </Section>

      <Section title="Verify">
        <Prose>
          Confirm the CLI and GUI are working:
        </Prose>
        <CodeBlock>{`spaces --version
open -a Spaces`}</CodeBlock>
        <Prose>
          The first command prints the installed version. The second launches the app.
        </Prose>
      </Section>

      <Section title="Updates">
        <Prose>
          Spaces checks for updates automatically through its built-in updater, and you can also check manually from the app menu. New versions install in place. Manual DMG downloads stay available on the releases page if you prefer to update by hand.
        </Prose>
      </Section>

      <Section title="Uninstall">
        <Prose>
          To remove Spaces completely:
        </Prose>
        <CodeBlock>{`launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/dev.usespaces.spacesd.plist
rm -f ~/Library/LaunchAgents/dev.usespaces.spacesd.plist
rm -rf /Applications/Spaces.app
rm -f /usr/local/bin/spaces /usr/local/bin/spacesd /usr/local/bin/spaces-caddy
rm -f ~/.spaces/bin/spaces ~/.spaces/bin/spacesd
rm -rf ~/.spaces ~/spaces`}</CodeBlock>
        <Prose>
          <InlineCode>~/.spaces</InlineCode> holds Spaces&apos;s local database; <InlineCode>~/spaces</InlineCode> holds any git repos Spaces cloned for you and its workspace worktrees. Leave them alone if you want to keep that state.
        </Prose>
      </Section>

      <Section title="Linux">
        <Prose>
          Install the Spaces daemon on a Linux machine to run workspaces there and drive them from your Mac or iPhone. Ubuntu 24.04 on x86_64 or arm64 is supported. Pairing a Linux machine that does not have Spaces installed installs it as part of connecting: the pairing screen runs the installer over the same SSH connection, shows its progress until it finishes (usually a few minutes), and pairs automatically once it does. You can also run the installer on the machine yourself first, which pairing then uses directly.
        </Prose>

        <h3 className="mt-6 text-sm font-semibold text-foreground">Install</h3>
        <Prose>
          On the Linux machine, install the latest release:
        </Prose>
        <CodeBlock>{`curl -fsSL https://usespaces.dev/install.sh | bash`}</CodeBlock>
        <Prose>
          To pin a specific release, pass its version — replacing <InlineCode>&lt;version&gt;</InlineCode> with a released version such as <InlineCode>0.1.0</InlineCode>:
        </Prose>
        <CodeBlock>{`curl -fsSL https://usespaces.dev/install.sh | bash -s -- <version>`}</CodeBlock>
        <Prose>
          The Mac app and the <InlineCode>spaces</InlineCode> CLI print the version-pinned command with the right version already filled in whenever they reach a Linux machine whose daemon is missing or out of date. Released versions are listed on the{" "}
          <Link
            href={githubReleasesURL}
            className="text-accent hover:underline"
            target="_blank"
            rel="noopener noreferrer"
          >
            releases page
          </Link>
          .
        </Prose>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          The installer checks the download against the signed release before running it, then:
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Installs the daemon under <InlineCode>~/.spaces</InlineCode> and puts the <InlineCode>spaces</InlineCode> CLI on your PATH at <InlineCode>~/.local/bin/spaces</InlineCode>.</li>
          <li>• Registers <InlineCode>spacesd.service</InlineCode> as a systemd user service and starts it. The service keeps running after you disconnect, so your terminal sessions survive closing SSH.</li>
          <li>• Listens for clients on port <InlineCode>47847</InlineCode>, which the devices you pair from need to reach — see <strong>Remote Machines &amp; Cloud VMs</strong> below.</li>
        </ul>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          It needs <InlineCode>curl</InlineCode>, <InlineCode>tar</InlineCode>, <InlineCode>sha256sum</InlineCode>, <InlineCode>openssl</InlineCode>, and <InlineCode>python3</InlineCode>. If it can&apos;t keep background services running for your account on its own, it stops and tells you to run <InlineCode>sudo loginctl enable-linger $USER</InlineCode> and try again.
        </p>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Once the daemon is running, pair the machine with your Mac or iPhone. See the <Link href="/docs/cli" className="text-accent hover:underline">CLI reference</Link> for <InlineCode>spaces device pair</InlineCode>.
        </p>

        <h3 className="mt-6 text-sm font-semibold text-foreground">Update</h3>
        <Prose>
          Re-run the same command with the new version to update in place. There is no separate update command: it hands the running daemon over to the new version without a full restart, so your terminal sessions, processes, and coding agents keep running across the update.
        </Prose>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          The Mac app also keeps track of whether a machine&apos;s daemon is behind. If a newer version is already on the machine, the app puts it in place on its own, with nothing running there interrupted; if that doesn&apos;t land within a bit, the app says so and offers to try again. If nothing newer is installed yet and the machine was paired over SSH, the app offers an <strong>Update over SSH</strong> action that runs the same update over that connection for you — terminals, processes, and coding agents keep running throughout. The command above stays available if you&apos;d rather run it by hand, and it&apos;s the only option for a machine paired from a link instead of over SSH.
        </p>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          A client and a daemon can only talk to each other when they speak the same protocol, and Spaces will not connect them when they don&apos;t. When that happens Spaces tells you which side is behind: update the Mac app through its built-in updater, or update the Linux daemon as described above.
        </p>

        <h3 className="mt-6 text-sm font-semibold text-foreground">Uninstall</h3>
        <Prose>
          On the Linux machine:
        </Prose>
        <CodeBlock>{`systemctl --user disable --now spacesd.service
rm -f ~/.config/systemd/user/spacesd.service
systemctl --user daemon-reload
rm -f ~/.local/bin/spaces
rm -rf ~/.spaces ~/spaces`}</CodeBlock>
        <Prose>
          As on macOS, <InlineCode>~/.spaces</InlineCode> holds the daemon&apos;s local database and <InlineCode>~/spaces</InlineCode> holds its repos and workspace worktrees. Leave them alone if you want to keep that state.
        </Prose>
      </Section>

      <Section title="Remote Machines & Cloud VMs">
        <Prose>
          A machine you want to work on from your Mac or iPhone — a Linux box under your desk, a cloud VM, or a second Mac — has to meet a few requirements before it can pair. Set them up first and pairing goes through on the first attempt.
        </Prose>

        <h3 className="mt-6 text-sm font-semibold text-foreground">Spaces on the machine</h3>
        <Prose>
          Pairing connects two Spaces installs, so the machine needs its own. A Linux machine needs the daemon on Ubuntu 24.04 (x86_64 or arm64); pairing installs it automatically over SSH if it isn&apos;t there yet, or you can run the installer yourself first — both covered under <strong>Linux</strong> above. A second Mac needs <InlineCode>Spaces.app</InlineCode> installed and opened once, exactly like the Mac in front of you.
        </Prose>

        <h3 className="mt-6 text-sm font-semibold text-foreground">SSH access that needs no prompts</h3>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <strong>Key-based access.</strong> Spaces pairs over SSH with no terminal for you to type into, so a password prompt can never be answered. The account you pair as needs key-based SSH access, or an SSH agent that is unlocked and can authenticate for it.</li>
          <li>• <strong>A host you already trust.</strong> Spaces connects only to a machine whose host key is already in your <InlineCode>known_hosts</InlineCode>. Connecting to it once by hand — <InlineCode>ssh user@host</InlineCode> — records the key and is enough. If that host key changes later, on a rebuilt VM for example, pairing fails until you replace the stale <InlineCode>known_hosts</InlineCode> entry.</li>
          <li>• <strong>A non-default SSH port.</strong> Supported — set the port when you add the device.</li>
        </ul>

        <h3 className="mt-6 text-sm font-semibold text-foreground">Reaching the machine on port 47847</h3>
        <Prose>
          Pairing itself rides SSH, but nothing after it does: once paired, your Mac or iPhone talks to the machine&apos;s Spaces daemon on TCP <InlineCode>47847</InlineCode>. That port has to be reachable from the client over whatever network you use — LAN, VPN, or Tailscale.
        </Prose>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          On a cloud VM that means an ingress firewall rule allowing <InlineCode>tcp:47847</InlineCode> from the addresses you connect from, alongside the rule for SSH (<InlineCode>tcp:22</InlineCode> unless you moved it). Reaching the machine at its tailnet address rather than its public address needs no ingress rule at all.
        </p>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          This is the failure worth recognizing, because working SSH makes it look like the network is fine: pairing gets all the way through the SSH step, and then Spaces reports that the remote Device API is not reachable at that address and port. Open the port and pair again.
        </p>

        <h3 className="mt-6 text-sm font-semibold text-foreground">Work that outlives your SSH session</h3>
        <Prose>
          The daemon keeps workspaces, terminals, and coding agents running on the machine after your SSH session ends, which the machine has to allow for your account. The Linux installer arranges that for you; if it can&apos;t, it stops and prints the one command to run on the machine before you install again (see <strong>Linux</strong> above). On a Mac, the background service the installer sets up already covers it.
        </Prose>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          A client and a machine also have to run matching Spaces versions before they will connect at all — see <strong>Update</strong> under <strong>Linux</strong> above.
        </p>
      </Section>
    </DocsShell>
  );
}
