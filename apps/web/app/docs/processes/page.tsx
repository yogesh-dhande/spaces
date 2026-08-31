import type { Metadata } from "next";
import Link from "next/link";
import { DocsShell } from "../components/docs-shell";
import { Prose, Section } from "../components/section";

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
      <Section title="What Is a Process?">
        <Prose>
          A process is a command you want running whenever the workspace is running — a dev server, a worker, a test watcher, a coding agent. You configure processes on the project; each workspace gets its own copy it can tweak without affecting the project.
        </Prose>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Spaces gives each process its own terminal window when the workspace launches.</li>
          <li>• Each process runs in a Spaces terminal, so if you close the window the process keeps running and Spaces can reopen the session view without restarting the work.</li>
        </ul>
      </Section>

      <Section title="Shell Commands">
        <Prose>
          Every process command is shell input, like typing into a terminal. Spaces runs the command through your resolved login shell with the workspace environment already exported.
        </Prose>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Plain commands such as <code>npm run dev</code> and <code>python manage.py runserver</code> run naturally.</li>
          <li>• Composite commands can use <code>cd</code>, <code>&amp;&amp;</code>, pipes, redirects, and normal shell expansion.</li>
        </ul>
        <pre className="mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-sm border border-line/70 bg-background-soft/60 p-3 text-xs leading-6 text-foreground">
          <code>{`# Env assignment
PORT=$SPACES_WEB_PORT npm run dev

# Braced expansion
PORT=\${SPACES_WEB_PORT:-3000} npm run dev

# Directory changes
cd frontend && PORT=$SPACES_WEB_PORT npm run dev

# Pipelines
npm run dev | tee .logs/frontend.log`}</code>
        </pre>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Spaces validates that the command is non-empty and leaves parsing to your shell.
        </p>
      </Section>

      <Section title="On Exit">
        <Prose>
          Pick what Spaces should do when a process exits:
        </Prose>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <strong>none</strong> &mdash; mark it exited and move on.</li>
          <li>• <strong>notify</strong> &mdash; show a macOS notification so you know it died.</li>
          <li>• <strong>restart</strong> &mdash; start it back up automatically.</li>
        </ul>
      </Section>

      <Section title="Environment Variables">
        <Prose>
          Every process runs with the workspace&apos;s per-service variables and directory variables in its environment:
        </Prose>
        <pre className="mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-sm border border-line/70 bg-background-soft/60 p-3 text-xs leading-6 text-foreground">
          <code>{`SPACES_WEB_PORT, SPACES_API_PORT, ...   # assigned port per service
SPACES_WEB_URL, SPACES_API_URL, ...     # Caddy URL per service
SPACES_WEB_HOST, SPACES_API_HOST, ...   # Caddy hostname per service (no scheme or port)
SPACES_PROJECT_DIR                      # project directory
SPACES_WORKSPACE_DIR                    # this workspace's directory`}</code>
        </pre>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Reference them directly in your command, for example <code>PORT=$SPACES_WEB_PORT npm run dev</code>. The shell expands those variables when the process starts. See{" "}
          <Link href="/docs/services" className="text-accent hover:underline">
            Services
          </Link>{" "}
          for how these ports and URLs are assigned and routed.
        </p>
      </Section>

      <Section title="Editing While Running">
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Add a process &mdash; it appears immediately. You can launch it directly if the workspace is already running.</li>
          <li>• Change a command &mdash; Spaces asks for restart confirmation because the running process must be relaunched.</li>
          <li>• Change only the name or on-exit policy &mdash; Spaces applies the edit immediately when it can.</li>
          <li>• Remove a process &mdash; Spaces stops it and closes its terminal window.</li>
        </ul>
      </Section>

      <Section title="Coding Agents">
        <Prose>
          Coding agents run as processes like any other, but they can also report their own lifecycle — started, waiting on you, done — through <code>spaces agent signal</code>. Alerts surfaces those states so you know which agent needs you next.
        </Prose>
      </Section>
    </DocsShell>
  );
}
