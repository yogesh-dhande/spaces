import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";

export const metadata: Metadata = {
  title: "Getting Started",
  description: "Install prerequisites and launch your first workspace.",
};

export default function GettingStartedDocsPage() {
  return (
    <DocsShell
      title="Getting Started"
      description="Start from a project directory or a Git URL, then launch a workspace with processes, browser sessions, and reserved ports."
      pagePath="/docs/getting-started"
    >
      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Requirements</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• macOS 14 or later.</li>
          <li>• Google Chrome installed for browser sessions.</li>
          <li>• Permission for Spaces to control Google Chrome (the macOS Automation permission), so Spaces can focus browser sessions.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">First Session Flow</h2>
        <ol className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>1. Install the dependencies above and launch Spaces. On first launch, if the permission to control Google Chrome is missing, Spaces shows an &ldquo;Allow Spaces to control Google Chrome&rdquo; screen. Choose <strong>Grant Access</strong> to approve the macOS prompt, or open System Settings ▸ Privacy &amp; Security ▸ Automation if Spaces was previously denied. Spaces continues to the workspace UI as soon as access is granted.</li>
          <li>2. Add a project from a local directory or a Git URL.</li>
          <li>3. Create a workspace for the branch or task you&apos;re starting.</li>
          <li>4. Launch the workspace. Spaces starts its processes; browser sessions open when you focus them.</li>
          <li>5. Focus any of the workspace&apos;s windows with <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">cmd+1</code> through <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">cmd+9</code>, or cycle through them with <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">cmd+alt+]</code> / <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">cmd+alt+[</code>.</li>
        </ol>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Add Your First Project</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Point Spaces at a local directory or paste a Git URL. Spaces creates a default workspace automatically — for a Git repo it corresponds to <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">main</code> / <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">master</code>; for a plain directory it corresponds to the directory itself.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Create a Workspace</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Use the <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">+</code> button on a project in the sidebar, or press <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">cmd+n</code>. For a Git project, pick an existing branch or name a new one; the base branch defaults to <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">main</code> or <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">master</code>. Spaces sets up a git worktree for the branch.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Launch and Validate</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Launching a workspace starts its processes in Spaces terminal windows. Confirm it worked:
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• The workspace shows as running in the sidebar.</li>
          <li>• Processes start in dedicated Spaces terminal windows.</li>
          <li>• Focusing a browser session opens its URL in Chrome.</li>
        </ul>
      </article>
    </DocsShell>
  );
}
