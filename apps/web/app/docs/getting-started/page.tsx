import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";
import { InlineCode } from "../components/code-block";
import { Prose, Section } from "../components/section";

export const metadata: Metadata = {
  title: "Getting Started",
  description: "Install prerequisites and launch your first workspace.",
};

export default function GettingStartedDocsPage() {
  return (
    <DocsShell
      title="Getting Started"
      description="Start from a project directory or a Git URL, then launch a workspace with processes, browser sessions, and named services routed through Caddy."
      pagePath="/docs/getting-started"
    >
      <Section title="Requirements">
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• macOS 14 or later.</li>
          <li>• Google Chrome installed for browser sessions.</li>
          <li>• Permission for Spaces to control Google Chrome (the macOS Automation permission), so Spaces can focus browser sessions.</li>
        </ul>
      </Section>

      <Section title="First Session Flow">
        <ol className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>1. Install the dependencies above and launch Spaces. On first launch, if the permission to control Google Chrome is missing, Spaces shows an &ldquo;Allow Spaces to control Google Chrome&rdquo; screen. Choose <strong>Grant Access</strong> to approve the macOS prompt, or open System Settings ▸ Privacy &amp; Security ▸ Automation if Spaces was previously denied. Spaces continues to the workspace UI as soon as access is granted.</li>
          <li>2. Add a project from a local directory or a Git URL.</li>
          <li>3. Create a workspace for the branch or task you&apos;re starting.</li>
          <li>4. Launch the workspace. Spaces starts its processes; browser sessions open when you focus them.</li>
          <li>5. Open or focus any of the workspace&apos;s ordered targets with <InlineCode>cmd+1</InlineCode> through <InlineCode>cmd+0</InlineCode>, or cycle through already-open windows with <InlineCode>cmd+alt+]</InlineCode> / <InlineCode>cmd+alt+[</InlineCode>.</li>
        </ol>
      </Section>

      <Section title="Add Your First Project">
        <Prose>
          Point Spaces at a local directory or paste a Git URL. Spaces creates a default workspace automatically — for a Git repo it corresponds to <InlineCode>main</InlineCode> / <InlineCode>master</InlineCode>; for a plain directory it corresponds to the directory itself.
        </Prose>
      </Section>

      <Section title="Create a Workspace">
        <Prose>
          Use the <InlineCode>+</InlineCode> button on a project in the sidebar, or press <InlineCode>cmd+n</InlineCode>. For a Git project, pick an existing branch or name a new one; the base branch defaults to <InlineCode>main</InlineCode> or <InlineCode>master</InlineCode>. Spaces sets up a git worktree for the branch.
        </Prose>
      </Section>

      <Section title="Launch and Validate">
        <Prose>
          Launching a workspace starts its processes in Spaces terminal windows. Confirm it worked:
        </Prose>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• The workspace shows as running in the sidebar.</li>
          <li>• Processes start in dedicated Spaces terminal windows.</li>
          <li>• Focusing a browser session opens its URL in Chrome.</li>
        </ul>
      </Section>
    </DocsShell>
  );
}
