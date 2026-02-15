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
      description="Status checks execute shell commands against running workspace processes and publish green/red status indicators in the UI."
      pagePath="/docs/status-checks"
    >
      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Definition</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          A status check is tied to a process and includes command, interval, timeout,
          and an `on_exit` preference.
        </p>
        <pre className="mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-xl border border-line bg-background-soft/80 p-3 text-xs leading-6 text-foreground">
          <code>{`status_checks:
  - name: web-health
    process: web
    command: curl -fsS http://localhost:$PORT0/health
    interval: 10
    timeout: 2
    on_exit: notify`}</code>
        </pre>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Where Checks Live</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Project templates in YAML provide initial check definitions.</li>
          <li>• Workspace copies in SQLite can be edited without mutating YAML.</li>
          <li>• Running workspace updates apply check edits immediately.</li>
          <li>• A process may have multiple checks.</li>
        </ul>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Status Output</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Successful check exit: green status.</li>
          <li>• Non-zero exit or timeout: red status.</li>
          <li>• Check message stores command output for inspection.</li>
          <li>• Process rows in the Run tab display check summaries.</li>
        </ul>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Related Runtime States</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Status checks are one layer of runtime visibility. Process state remains the primary source
          for running/exited, and coding-agent processes can report idle/busy.
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• `running`: process is alive.</li>
          <li>• `exited`: process has stopped.</li>
          <li>• `idle`: agent process is alive but no output has been emitted for the idle interval.</li>
        </ul>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Check Suite Example</h2>
        <pre className="mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-xl border border-line bg-background-soft/80 p-3 text-xs leading-6 text-foreground">
          <code>{`status_checks:
  - name: web
    process: web
    command: curl -fsS http://localhost:$PORT0/health
    interval: 10
    timeout: 2
    on_exit: notify
  - name: queue
    process: queue
    command: curl -fsS http://localhost:$PORT1/metrics
    interval: 15
    timeout: 3
    on_exit: restart`}</code>
        </pre>
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
