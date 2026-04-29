import type { Metadata } from "next";
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
            3. Drag <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">Spaces.app</code> to your <strong>Applications</strong> folder.
          </li>
          <li>
            4. Double-click <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">Install spaces CLI</code> in the DMG to install the <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">spaces</code> command.
          </li>
          <li>
            5. Eject the DMG.
          </li>
        </ol>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Dependencies</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Spaces relies on a few external tools. Install them before launching.
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>
            • <strong>yabai</strong> — used to focus workspace windows.
            <pre className="mt-1 rounded-lg bg-background-soft p-3 text-xs leading-6">brew install koekeishiya/formulae/yabai</pre>
          </li>
          <li>• <strong>tmux</strong> — keeps workspace processes alive when their terminal window is closed. Install with <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">brew install tmux</code>.</li>
          <li>• <strong>Ghostty or iTerm2</strong> — the terminal app Spaces uses for workspace processes. If both are installed, Spaces defaults to Ghostty. Install Ghostty with <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">brew install --cask ghostty</code> or iTerm2 from <a href="https://iterm2.com" className="text-accent hover:underline" target="_blank" rel="noopener noreferrer">iterm2.com</a> / <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">brew install --cask iterm2</code>.</li>
          <li>• <strong>Google Chrome</strong> — required for browser sessions. Download from <a href="https://www.google.com/chrome/" className="text-accent hover:underline" target="_blank" rel="noopener noreferrer">google.com/chrome</a> or install with <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">brew install --cask google-chrome</code>.</li>
        </ul>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          On first launch, Spaces walks you through anything that is missing in a guided setup flow.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">macOS Permissions</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Spaces and yabai need Accessibility permission to focus windows. Spaces&apos;s setup flow will open the right System Settings pane on first launch, but you can also grant it manually:
        </p>
        <ol className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>1. Open <strong>System Settings → Privacy &amp; Security → Accessibility</strong>.</li>
          <li>2. Enable <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">Spaces</code> and <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">yabai</code>, plus your terminal app if macOS prompts for it.</li>
        </ol>
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
        <h2 className="text-2xl font-semibold tracking-tight">Updates</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Spaces checks GitHub Releases on its own. When a new version is available, you can install it from inside the app or open the release page directly.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Uninstall</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          To remove Spaces completely:
        </p>
        <pre className="mt-3 rounded-lg bg-background-soft p-3 text-xs leading-6">
{`rm -rf /Applications/Spaces.app
rm -f /usr/local/bin/spaces ~/.local/bin/spaces
rm -rf ~/.spaces ~/spaces`}
        </pre>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">~/.spaces</code> holds Spaces&apos;s local database; <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">~/spaces</code> holds any git repos Spaces cloned for you and its workspace worktrees. Leave them alone if you want to keep that state.
        </p>
      </article>
    </DocsShell>
  );
}
