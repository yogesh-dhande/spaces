import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";

export const metadata: Metadata = {
  title: "Troubleshooting",
  description: "Common setup, launch, and runtime issues in Spaces.",
};

export default function TroubleshootingDocsPage() {
  return (
    <DocsShell
      title="Troubleshooting"
      description="Diagnosis paths for common dependency, workspace lifecycle, process, and window-routing failures."
      pagePath="/docs/troubleshooting"
    >
      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Quick Triage</h2>
        <ol className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>1. Check that yabai and Chrome are installed.</li>
          <li>2. Check that Spaces and yabai have Accessibility permission in System Settings.</li>
          <li>3. Confirm the workspace isn&apos;t archived.</li>
          <li>4. If launch complains about existing runtime, run <code>spaces workspace restart --workspace &lt;id&gt;</code>.</li>
        </ol>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Launch / Stop / Restart Issues</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <strong>&ldquo;Workspace is already running&rdquo;</strong> &mdash; use <code>spaces workspace restart --workspace &lt;id&gt;</code> to reset state.</li>
          <li>• <strong>No terminal windows appear</strong> &mdash; confirm your processes are running.</li>
          <li>• <strong>No browser windows appear</strong> &mdash; confirm Chrome is installed and the workspace has browser sessions configured.</li>
          <li>• <strong>Something is left running after stop</strong> &mdash; add the teardown command to the project or workspace stop script to clean up state not managed by Spaces.</li>
        </ul>
        <pre className="mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-lg border border-line/70 bg-background-soft/60 p-3 text-xs leading-6 text-foreground">
          <code>{`spaces workspace start --workspace <workspace-id>
spaces workspace restart --workspace <workspace-id>`}</code>
        </pre>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Keyboard Shortcut Issues</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <strong>Global toggle (<code>cmd+alt+=</code>) or another global shortcut does nothing</strong> &mdash; another app may own the combo. Rebind it in Settings.</li>
        </ul>
      </article>
    </DocsShell>
  );
}
