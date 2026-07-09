import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";
import { CodeBlock } from "../components/code-block";
import Link from "next/link";

const githubReleasesURL = "https://github.com/yogesh-dhande/spaces/releases/latest";

export const metadata: Metadata = {
  title: "Installation & Setup",
  description:
    "Download Spaces, install dependencies, and verify your setup on macOS and Linux.",
};

export default function InstallationDocsPage() {
  return (
    <DocsShell
      title="Installation & Setup"
      description="Download the latest release, install dependencies, and get Spaces running on your Mac, plus the daemon on any Linux machine you want to work on."
      pagePath="/docs/installation"
    >
      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Download</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Grab the latest release:
        </p>
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
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Install</h2>
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
            3. Double-click <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">Install Spaces</code> in the DMG.
          </li>
          <li>
            4. The installer copies <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">Spaces.app</code>, links the required <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">spaces</code> CLI and <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">spacesd</code> daemon helpers to the app bundle, and sets up the per-user background service (LaunchAgent) that keeps your terminal sessions alive.
          </li>
          <li>
            5. Eject the DMG.
          </li>
        </ol>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Dependencies</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Spaces relies on Google Chrome for browser sessions. Install it before launching.
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <strong>Google Chrome</strong> — required for browser sessions. Download from <a href="https://www.google.com/chrome/" className="text-accent hover:underline" target="_blank" rel="noopener noreferrer">google.com/chrome</a> or install with <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">brew install --cask google-chrome</code>.</li>
          <li>• <strong>Automation permission</strong> — Spaces controls Google Chrome to focus browser sessions, which macOS gates under Privacy &amp; Security ▸ Automation. On first launch Spaces shows a setup screen to grant it; you can also enable it later from System Settings.</li>
        </ul>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Spaces includes its own terminal, so workspaces do not depend on any external terminal app.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Verify</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Confirm the CLI and GUI are working:
        </p>
        <CodeBlock>{`spaces --version
open -a Spaces`}</CodeBlock>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          The first command prints the installed version. The second launches the app.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Updates</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Spaces checks for updates automatically through its built-in updater, and you can also check manually from the app menu. New versions install in place. Manual DMG downloads stay available on the releases page if you prefer to update by hand.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Uninstall</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          To remove Spaces completely:
        </p>
        <CodeBlock>{`launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/dev.usespaces.spacesd.plist
rm -f ~/Library/LaunchAgents/dev.usespaces.spacesd.plist
rm -rf /Applications/Spaces.app
rm -f /usr/local/bin/spaces /usr/local/bin/spacesd /usr/local/bin/spaces-caddy
rm -f ~/.spaces/bin/spaces ~/.spaces/bin/spacesd
rm -rf ~/.spaces ~/spaces`}</CodeBlock>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">~/.spaces</code> holds Spaces&apos;s local database; <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">~/spaces</code> holds any git repos Spaces cloned for you and its workspace worktrees. Leave them alone if you want to keep that state.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Linux</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Install the Spaces daemon on a Linux machine to run workspaces there and drive them from your Mac or iPhone. Ubuntu 24.04 on x86_64 or arm64 is supported. Spaces never installs the daemon for you — run the installer on the Linux machine yourself.
        </p>

        <h3 className="mt-6 text-sm font-semibold text-foreground">Install</h3>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          On the Linux machine, run the installer for the version you want, replacing <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">&lt;version&gt;</code> with a released version such as <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">0.1.0</code>:
        </p>
        <CodeBlock>{`curl -fsSL https://github.com/yogesh-dhande/spaces/releases/download/v<version>/spaces-install-linux.sh | bash -s -- <version>`}</CodeBlock>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          The Mac app and the <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">spaces</code> CLI print this command with the right version already filled in whenever they reach a Linux machine whose daemon is missing or out of date. Released versions are listed on the{" "}
          <Link
            href={githubReleasesURL}
            className="text-accent hover:underline"
            target="_blank"
            rel="noopener noreferrer"
          >
            releases page
          </Link>
          .
        </p>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          The installer checks the download against the signed release before running it, then:
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Installs the daemon under <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">~/.spaces</code> and puts the <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">spaces</code> CLI on your PATH at <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">~/.local/bin/spaces</code>.</li>
          <li>• Registers <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">spacesd.service</code> as a systemd user service and starts it. The service keeps running after you disconnect, so your terminal sessions survive closing SSH.</li>
          <li>• Listens for clients on port <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">47847</code>. Open that port to the devices you pair from.</li>
        </ul>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          It needs <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">curl</code>, <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">tar</code>, <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">sha256sum</code>, <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">openssl</code>, and <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">python3</code>. If it can&apos;t keep background services running for your account on its own, it stops and tells you to run <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">sudo loginctl enable-linger $USER</code> and try again.
        </p>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Once the daemon is running, pair the machine with your Mac or iPhone. See the <Link href="/docs/cli" className="text-accent hover:underline">CLI reference</Link> for <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">spaces device pair</code>.
        </p>

        <h3 className="mt-6 text-sm font-semibold text-foreground">Update</h3>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Re-run the same command with the new version. There is no separate update command. The installer puts the new version in place alongside the old one, switches over, and restarts the service, so the daemon comes back on its own.
        </p>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          A client and a daemon can only talk to each other when they speak the same protocol, and Spaces will not connect them when they don&apos;t. When that happens Spaces tells you which side is behind: update the Mac app through its built-in updater, or update the Linux daemon with the command Spaces prints for you.
        </p>

        <h3 className="mt-6 text-sm font-semibold text-foreground">Uninstall</h3>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          On the Linux machine:
        </p>
        <CodeBlock>{`systemctl --user disable --now spacesd.service
rm -f ~/.config/systemd/user/spacesd.service
systemctl --user daemon-reload
rm -f ~/.local/bin/spaces
rm -rf ~/.spaces ~/spaces`}</CodeBlock>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          As on macOS, <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">~/.spaces</code> holds the daemon&apos;s local database and <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">~/spaces</code> holds its repos and workspace worktrees. Leave them alone if you want to keep that state.
        </p>
      </article>
    </DocsShell>
  );
}
