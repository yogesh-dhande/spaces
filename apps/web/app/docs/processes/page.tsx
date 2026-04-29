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
          <li>• Muxy gives each process its own terminal window when the workspace launches.</li>
          <li>• Processes run inside tmux, so if you close the terminal the process keeps running and Muxy can reattach it to a new window.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Direct Invocation &amp; <code>bash -lc</code></h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Muxy treats each process command as a direct executable invocation, not a shell script. Tokens are parsed into an <code>argv</code> and leading <code>KEY=value</code> pairs are lifted into the command&apos;s environment. Shell operators (<code>&amp;&amp;</code>, <code>||</code>, <code>;</code>, pipes, redirects, subshells, command substitution) are rejected — Muxy surfaces a validation error telling you to wrap the command explicitly.
        </p>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          When you need shell composition, invoke a shell yourself with <code>bash -lc</code> so the whole composed command becomes a single argument:
        </p>
        <pre className="mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-lg border border-line/70 bg-background-soft/60 p-3 text-xs leading-6 text-foreground">
          <code>{`# direct invocation — works
PORT=$FRONTEND_PORT npm run dev

# shell composition — needs bash -lc
bash -lc "cd frontend && PORT=\$FRONTEND_PORT npm run dev"

# chained pipelines / conditionals — needs bash -lc
bash -lc "curl -fsS http://localhost:\$API_PORT/ready && npm run dev"`}</code>
        </pre>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Named ports and <code>MUXY_*</code> vars are substituted by Muxy before the command is parsed, so you can reference <code>$FRONTEND_PORT</code> inside the quoted <code>bash -lc</code> string the same way you would outside it. Keep the whole pipeline inside a single <code>bash -lc</code> call so the <code>on-exit</code> policy applies to the composed command, not just the last step.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">On Exit</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Pick what Muxy should do when a process exits:
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
MUXY_PROJECT_DIR                # project directory
MUXY_WORKSPACE_DIR              # this workspace's directory`}</code>
        </pre>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Reference them directly in your command, for example <code>PORT=$FRONTEND_PORT npm run dev</code>.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Editing While Running</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Add a process &mdash; it starts right away in a new terminal window.</li>
          <li>• Change a command &mdash; Muxy restarts that process in its existing window.</li>
          <li>• Remove a process &mdash; Muxy stops it and closes its terminal window.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Coding Agents</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Coding agents run as processes like any other, but they can also report their own lifecycle — started, waiting on you, done — through <code>muxy agent event</code>. The dashboard surfaces those states so you know which agent needs you next.
        </p>
      </article>
    </DocsShell>
  );
}
