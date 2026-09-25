import type { Metadata } from "next";
import { InlineCode } from "../components/code-block";
import { DocsShell } from "../components/docs-shell";
import { DocLink } from "../components/doc-link";
import { Prose, Section } from "../components/section";

export const metadata: Metadata = {
  title: "Browser sessions",
  description:
    "Named Chrome tabs a workspace opens on focus and closes when it stops.",
};

export default function BrowserSessionsDocsPage() {
  return (
    <DocsShell
      title="Browser sessions"
      description="A browser session is a URL you want one focus away while a workspace is running, your local app, an admin page, a PR, a runbook."
      pagePath="/docs/browser-sessions"
    >
      <Section title="What a browser session is">
        <Prose>
          A browser session has a name and a URL, often a service&apos;s{" "}
          <DocLink href="/docs/services#stable-urls">stable URL</DocLink>. Configure them on the
          project and every workspace inherits them; attach as many as a workspace needs.
        </Prose>
      </Section>

      <Section id="opening" title="Opening and focusing">
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>Sessions stay closed when the workspace starts, so startup stays fast even with many attached.</li>
          <li>Focus a session by clicking its row, its number key, or the command palette, and it opens as a Chrome tab, not at Start.</li>
          <li>Spaces reuses the tab it opened; a closed Chrome is started, and a minimized window is restored.</li>
          <li>If you move a session&apos;s tab to another Chrome window, focusing it again finds that tab by its URL.</li>
          <li>If you close a session&apos;s tab and focus it again, Spaces reopens it.</li>
        </ul>
      </Section>

      <Section id="chrome-permission" title="The Chrome permission">
        <Prose>
          Spaces opens and focuses tabs through the macOS Automation permission, &ldquo;Spaces
          wants to control Google Chrome&rdquo;. If Chrome is not installed or the permission was
          denied, focusing a session shows an error naming Chrome instead of opening the URL. See{" "}
          <DocLink href="/docs/troubleshooting#browser-sessions">Troubleshooting</DocLink> if the
          permission prompt never appears or was denied by mistake.
        </Prose>
      </Section>

      <Section id="stopping" title="When a workspace stops">
        <Prose>
          Stop from the Mac closes the workspace&apos;s tabs. Today, when another device, the
          iPhone or the CLI on another machine, stops a workspace on a paired device, this Mac
          leaves that workspace&apos;s tabs open.
        </Prose>
      </Section>

      <Section id="on-iphone" title="On iPhone">
        <Prose>
          A browser session opens inside the app&apos;s own browser, with back, forward, reload,
          and Screenshot controls. Screenshot captures the visible view and opens it in Markup for
          annotation; the resulting image can then be attached from a terminal&apos;s message
          composer. This works for a remote Linux workspace too, as long as your phone is paired
          with the device that owns the workspace. If the service is not running yet, the row shows
          an error naming the service instead of a blank page.
        </Prose>
        <Prose>
          Cookies and local storage stay isolated per service, the same way they do in Chrome on
          the Mac. See <InlineCode>SPACES_&lt;SERVICE&gt;_URL</InlineCode> in{" "}
          <DocLink href="/docs/environment-variables#service-variables">
            Environment variables
          </DocLink>{" "}
          for how a session&apos;s URL is built.
        </Prose>
      </Section>
    </DocsShell>
  );
}
