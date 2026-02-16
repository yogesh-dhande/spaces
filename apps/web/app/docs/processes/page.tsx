import type { Metadata } from "next";
import { ScreenshotFrame } from "../../components/screenshot-frame";
import { DocsShell } from "../components/docs-shell";

export const metadata: Metadata = {
  title: "Processes",
  description: "Process templates and runtime behavior per workspace.",
};

export default function ProcessesDocsPage() {
  return (
    <DocsShell
      title="Processes"
      description="Processes are defined as project templates, copied into workspace settings, and launched in dedicated terminal windows for each running workspace."
      pagePath="/docs/processes"
    >
      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Process Model</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Processes are defined at the project level and inherited by each workspace.</li>
          <li>• Each workspace can customize its own process commands independently.</li>
          <li>• Each process has a command and optional name.</li>
          <li>• Typical use cases: web servers, workers, test watchers, coding agents.</li>
        </ul>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Environment Variables</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Every workspace process receives reserved ports and workspace path variables.
        </p>
        <pre className="mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-xl border border-line bg-background-soft/80 p-3 text-xs leading-6 text-foreground">
          <code>{`FRONTEND_PORT, API_PORT, ...   # named port definitions
MUXY_PROJECT_DIR
MUXY_WORKSPACE_DIR`}</code>
        </pre>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Use these values directly in commands, for example `PORT=$FRONTEND_PORT npm run dev`.
        </p>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Launch and Runtime</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• On launch, each process starts in its own iTerm2 window.</li>
          <li>• Running processes are tracked per workspace and visible in the Run tab.</li>
          <li>• If workspace settings are edited while running, added processes start immediately.</li>
        </ul>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Stop and Restart Behavior</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Stop gracefully interrupts processes first, then escalates if needed.</li>
          <li>• The stop script runs after process termination (if configured).</li>
          <li>• Command changes in a running workspace restart the affected process in the same terminal window.</li>
        </ul>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Coding Agent Detection</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Muxy can classify agent-like process commands (for example `codex` or `claude`) and
          expose idle/busy semantics in status reporting.
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Busy: process is running and producing output.</li>
          <li>• Idle: process is running with no output for a configured interval.</li>
          <li>• Exited: process has stopped.</li>
        </ul>
      </article>

      <article className="grid gap-4 rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm md:grid-cols-2">
        <ScreenshotFrame
          title="Workspace Run Processes"
          caption="Process list with live status state and check summaries in the Run tab."
        />
        <ScreenshotFrame
          title="Workspace Settings Processes"
          caption="Per-workspace process editor used to override template commands."
        />
      </article>
    </DocsShell>
  );
}
