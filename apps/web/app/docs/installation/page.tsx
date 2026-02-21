import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";
import Link from "next/link";

export const metadata: Metadata = {
  title: "Installation & Setup",
  description:
    "Download Muxy, install dependencies, and verify your setup.",
};

export default function InstallationDocsPage() {
  return (
    <DocsShell
      title="Installation & Setup"
      description="Download the latest release, install dependencies, and get Muxy running on your Mac."
      pagePath="/docs/installation"
    >
      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Download</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Grab the latest release:
        </p>
        <p className="mt-3">
          <Link
            href="/releases/latest"
            className="inline-flex rounded-full border border-line px-4 py-2 text-sm font-semibold transition-colors hover:border-accent hover:text-accent"
          >
            Download Latest Release
          </Link>
        </p>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Install</h2>
        <ol className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>
            1. Download <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">Muxy-&lt;version&gt;.dmg</code> from the latest release.
          </li>
          <li>
            2. Double-click the DMG file to mount it.
          </li>
          <li>
            3. Drag the <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">Muxy.app</code> to your <strong>Applications</strong> folder.
          </li>
          <li>
            4. Double-click the <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">Install mx CLI</code> script in the DMG to install the command-line tool.
          </li>
          <li>
            5. Eject the DMG volume.
          </li>
        </ol>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Dependencies</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Muxy relies on three external tools. Install them before launching.
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>
            • <strong>yabai</strong> — window management and focus routing.
            <pre className="mt-1 rounded-lg bg-background-soft p-3 text-xs leading-6">brew install koekeishiya/formulae/yabai</pre>
          </li>
          <li>• <strong>iTerm2</strong> — process terminals. Download from <a href="https://iterm2.com" className="text-accent hover:underline" target="_blank" rel="noopener noreferrer">iterm2.com</a> or install via <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">brew install --cask iterm2</code>.</li>
          <li>• <strong>Google Chrome</strong> — browser sessions. Download from <a href="https://www.google.com/chrome/" className="text-accent hover:underline" target="_blank" rel="noopener noreferrer">google.com/chrome</a> or install via <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">brew install --cask google-chrome</code>.</li>
        </ul>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">macOS Permissions</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Muxy and yabai need Accessibility permissions to manage windows.
        </p>
        <ol className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>1. Open <strong>System Settings → Privacy &amp; Security → Accessibility</strong>.</li>
          <li>2. Click the lock icon and authenticate.</li>
          <li>3. Add <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">Muxy</code>, <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">yabai</code>, and <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">iTerm2</code> to the list.</li>
          <li>4. Ensure each entry has its toggle enabled.</li>
        </ol>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Verify</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Confirm the CLI and GUI are working:
        </p>
        <pre className="mt-3 rounded-lg bg-background-soft p-3 text-xs leading-6">
{`mx --version
Muxy`}
        </pre>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          The first command prints the installed version. The second launches the menu bar app.
        </p>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Auto-Update</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Muxy includes a built-in update checker. When a new version is available, you will see a notification in the menu bar with a link to download the update.
        </p>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Uninstall</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          To remove Muxy completely:
        </p>
        <pre className="mt-3 rounded-lg bg-background-soft p-3 text-xs leading-6">
{`rm /usr/local/bin/Muxy /usr/local/bin/mx
rm -rf ~/.muxy/`}
        </pre>
      </article>
    </DocsShell>
  );
}
