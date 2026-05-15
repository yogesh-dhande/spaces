import type { Metadata } from "next";
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
      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">What Is a Process?</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          A process is a command you want running whenever the workspace is running — a dev server, a worker, a test watcher, a coding agent. You configure processes on the project; each workspace gets its own copy it can tweak without affecting the project.
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Spaces gives each process its own terminal window when the workspace launches.</li>
          <li>• Process terminals are backed by the built-in Spaces terminal runtime, so if you close the window the process keeps running and Spaces can reopen the session view without restarting the work.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Execution Modes</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Every process row has an <strong>Execution mode</strong>:
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <strong>Direct</strong> &mdash; Spaces launches the executable and arguments exactly as entered. This is the recommended path for most dev servers, workers, watchers, and agent commands.</li>
          <li>• <strong>Shell</strong> &mdash; Spaces hands the full command string to the shell selected in Spaces Settings. Use this when the command depends on shell syntax instead of a single executable plus arguments.</li>
        </ul>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Use Direct mode for commands like <code>npm run dev</code>, <code>python manage.py runserver</code>, or <code>scripts/swiftpm.sh build</code>. Use Shell mode when you need shell composition such as <code>cd</code>, <code>&amp;&amp;</code>, pipes, redirects, or general shell expansion.
        </p>
        <pre className="mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-lg border border-line/70 bg-background-soft/60 p-3 text-xs leading-6 text-foreground">
          <code>{`# Direct mode
PORT=$FRONTEND_PORT npm run dev

# Direct mode with braces
PORT=\${FRONTEND_PORT} npm run dev

# Shell mode
cd frontend && PORT=$FRONTEND_PORT npm run dev

# Shell mode with pipelines
npm run dev | tee .logs/frontend.log`}</code>
        </pre>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Direct mode rejects shell-only syntax such as <code>&amp;&amp;</code>, pipes, redirects, command substitution, backticks, and unsupported shell expansion. In Direct mode, Spaces only expands its own variables using <code>$NAME</code> or <code>${"{NAME}"}</code>. Forms like <code>${"{NAME:-fallback}"}</code>, <code>$$</code>, and <code>$?</code> require Shell mode. Shell mode only requires a non-empty command and leaves parsing to the configured shell.
        </p>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Shell mode uses the global shell selected in Spaces Settings. The default is <code>zsh</code>, and you can switch it globally if your team standardizes on a different shell.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">On Exit</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Pick what Spaces should do when a process exits:
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <strong>none</strong> &mdash; mark it exited and move on.</li>
          <li>• <strong>notify</strong> &mdash; show a macOS notification so you know it died.</li>
          <li>• <strong>restart</strong> &mdash; start it back up automatically.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Environment Variables</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Every process runs with the workspace&apos;s named ports and directory variables in its environment:
        </p>
        <pre className="mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-lg border border-line/70 bg-background-soft/60 p-3 text-xs leading-6 text-foreground">
          <code>{`FRONTEND_PORT, API_PORT, ...   # your named ports
SPACES_PROJECT_DIR                # project directory
SPACES_WORKSPACE_DIR              # this workspace's directory`}</code>
        </pre>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Reference them directly in your command, for example <code>PORT=$FRONTEND_PORT npm run dev</code>. Direct mode accepts only Spaces-provided variables and keeps the original command text in validation errors when a variable name or expansion form is unsupported.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Editing While Running</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Add a process &mdash; it appears immediately. You can launch it directly if the workspace is already running.</li>
          <li>• Change a command or execution mode &mdash; Spaces asks for restart confirmation because the launch semantics changed.</li>
          <li>• Change only the name or on-exit policy &mdash; Spaces applies the edit immediately when it can.</li>
          <li>• Remove a process &mdash; Spaces stops it and closes its terminal window.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Coding Agents</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Coding agents run as processes like any other, but they can also report their own lifecycle — started, waiting on you, done — through <code>spaces signal</code>. Alerts surfaces those states so you know which agent needs you next.
        </p>
      </article>
    </DocsShell>
  );
}
