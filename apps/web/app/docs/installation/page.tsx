import type { Metadata } from "next";
import { CodeBlock } from "../components/code-block";
import { DocsShell } from "../components/docs-shell";
import Link from "next/link";

const githubReleasesURL = "https://github.com/yogesh-dhande/spaces/releases/latest";

export const metadata: Metadata = {
  title: "Installation & Setup",
  description:
    "Download Spaces, install dependencies, and verify your setup.",
};

export default function InstallationDocsPage() {
  return (
    <DocsShell
      title="Installation & Setup"
      description="Download the latest release, install dependencies, and get Spaces running on your Mac."
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
            1. Download <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">Spaces-&lt;version&gt;.dmg</code> from the latest release.
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
        <pre className="mt-3 rounded-lg bg-background-soft p-3 text-xs leading-6">
{`spaces --version
open -a Spaces`}
        </pre>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          The first command prints the installed version. The second launches the app.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Linux Remote Devices</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Pair an Ubuntu 24.04 device (x86_64 or arm64) as a remote device by running the installer on it:
        </p>
        <CodeBlock>{`curl -fsSL https://usespaces.dev/install.sh | bash`}</CodeBlock>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          When pairing needs an exact version match, the Mac app prints a version-pinned variant of this command to run instead.
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
        <pre className="mt-3 rounded-lg bg-background-soft p-3 text-xs leading-6">
{`launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/dev.usespaces.spacesd.plist
rm -f ~/Library/LaunchAgents/dev.usespaces.spacesd.plist
rm -rf /Applications/Spaces.app
rm -f /usr/local/bin/spaces /usr/local/bin/spacesd /usr/local/bin/spaces-caddy
rm -f ~/.spaces/bin/spaces ~/.spaces/bin/spacesd
rm -rf ~/.spaces ~/spaces`}
        </pre>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">~/.spaces</code> holds Spaces&apos;s local database; <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">~/spaces</code> holds any git repos Spaces cloned for you and its workspace worktrees. Leave them alone if you want to keep that state.
        </p>
      </article>
    </DocsShell>
  );
}
