import type { Metadata } from "next";
import { ScreenshotFrame } from "../../components/screenshot-frame";
import { DocsShell } from "../components/docs-shell";

export const metadata: Metadata = {
  title: "Status Checks",
  description: "Health checks attached to workspace processes.",
};

export default function StatusChecksDocsPage() {
  return (
    <DocsShell
      title="Status Checks"
      description="Status checks run shell commands against running workspace processes and show green/red status indicators in the UI."
      pagePath="/docs/status-checks"
    >
      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">What Is a Status Check?</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          A status check is tied to a process and includes a command, check interval, timeout,
          and an action to take when the check fails (do nothing, restart the process, or notify).
        </p>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">How Checks Work</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Checks are defined at the project level and inherited by each workspace.</li>
          <li>• Each workspace can customize its own checks independently.</li>
          <li>• Edits to checks in a running workspace apply immediately.</li>
          <li>• Checks run in periodic background monitoring for running workspaces.</li>
          <li>• A process may have multiple checks.</li>
        </ul>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">GUI Configuration</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• In Workspace Settings, each status check row includes an <code>On Fail</code> selector.</li>
          <li>• <code>none</code>: store failed (red) status only.</li>
          <li>• <code>notify</code>: store failed status and send a desktop notification.</li>
          <li>• <code>restart</code>: store failed status and restart the linked process.</li>
        </ul>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Status Output</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Successful check: green status indicator.</li>
          <li>• Failed check or timeout: red status indicator.</li>
          <li>• Check output is available for inspection.</li>
          <li>• Process rows in the Run tab display check summaries.</li>
        </ul>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Related Process States</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Status checks are one layer of visibility. Process state provides additional context.
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <strong>Running</strong>: process is alive.</li>
          <li>• <strong>Exited</strong>: process has stopped.</li>
          <li>• <strong>Idle</strong>: agent process is alive but no output for the configured interval.</li>
        </ul>
      </article>

      <article className="grid gap-4 rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm md:grid-cols-2">
        <ScreenshotFrame
          title="Status Check Editor"
          caption="Workspace settings with process-linked status check definitions."
        />
        <ScreenshotFrame
          title="Run Tab Status Summary"
          caption="Running process rows with green/red check results."
        />
      </article>
    </DocsShell>
  );
}
