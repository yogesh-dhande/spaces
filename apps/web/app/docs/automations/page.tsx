import type { Metadata } from "next";
import type { ReactNode } from "react";
import { DocsShell } from "../components/docs-shell";
import { CopyablePrompt } from "../components/copyable-prompt";
import { Section } from "../components/section";

export const metadata: Metadata = {
  title: "Automations",
  description:
    "Schedule a coding agent with a prompt, or run any shell script, on your Mac or a paired Linux box — on demand or on a schedule, even when Spaces is closed.",
};

function Field({ name, description }: { name: string; description: string }) {
  return (
    <li className="flex flex-col gap-0.5 sm:flex-row sm:gap-3">
      <span className="w-40 shrink-0 font-mono text-xs text-accent">{name}</span>
      <span className="text-sm leading-6 text-foreground-soft">{description}</span>
    </li>
  );
}

function PatternCard({
  title,
  useCase,
  fields,
  children,
}: {
  title: string;
  useCase: string;
  fields: string;
  children: ReactNode;
}) {
  return (
    <div className="rounded-sm border border-line/70 p-5">
      <h3 className="text-lg font-semibold text-foreground">{title}</h3>
      <p className="mt-1.5 text-sm leading-6 text-foreground-soft">{useCase}</p>
      {children}
      <p className="mt-3 font-mono text-xs leading-6 text-foreground-soft">{fields}</p>
    </div>
  );
}

function ScriptPattern({
  title,
  useCase,
  script,
  fields,
}: {
  title: string;
  useCase: string;
  script: string;
  fields: string;
}) {
  return (
    <PatternCard title={title} useCase={useCase} fields={fields}>
      <CopyablePrompt label={`${title} command`} text={script} />
    </PatternCard>
  );
}

function AgentPattern({
  title,
  useCase,
  workspace,
  agentCommand,
  prompt,
  fields,
}: {
  title: string;
  useCase: string;
  workspace: string;
  agentCommand: string;
  prompt: string;
  fields: string;
}) {
  return (
    <PatternCard title={title} useCase={useCase} fields={fields}>
      <ul className="mt-3 space-y-1.5">
        <Field name="Workspace" description={workspace} />
        <Field name="Agent command" description={agentCommand} />
      </ul>
      <CopyablePrompt label="Prompt" text={prompt} />
    </PatternCard>
  );
}

const NIGHTLY_AUDIT_SCRIPT = `git fetch --prune && ./scripts/audit.sh`;

const ORCHESTRATED_BATCH_SCRIPT = `claude -p "$(cat prompt.md)"`;

const HIGH_FREQUENCY_POLL_SCRIPT = `STATE_FILE="$HOME/.spaces/poll-session-id"
WORKSPACE_ID="<workspace-id>"

if [ -f "$STATE_FILE" ] && spaces agent status --session "$(cat "$STATE_FILE")" >/dev/null 2>&1; then
  SESSION_ID=$(cat "$STATE_FILE")
else
  SESSION_ID=$(spaces agent spawn --workspace "$WORKSPACE_ID" --command "claude --resume" --title poll-session | cut -f1)
  echo "$SESSION_ID" > "$STATE_FILE"
fi

spaces terminal send text "$SESSION_ID" "Check the queue and process the next item." --submit`;

export default function AutomationsDocsPage() {
  return (
    <DocsShell
      title="Automations"
      description="Schedule a coding agent with a prompt in two minutes, or run any shell script — on your Mac or a connected Linux box, on demand or on a schedule, even when Spaces is closed."
      pagePath="/docs/automations"
    >
      <Section title="What Is an Automation?">
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          An automation is a named task tied to one device — your Mac or a paired Linux box — that runs either when you trigger it or on a cron
          schedule you set in that device&apos;s local time. It keeps running whether Spaces is open or quit, and a remote automation keeps its own
          schedule even while your Mac is asleep. There are two kinds: an <strong>Agent</strong> automation spawns a coding agent into a workspace
          and hands it a prompt; a <strong>Script</strong> automation runs any shell command. The <strong>Automations</strong> row sits directly
          below Alerts in the sidebar and merges automations and runs across every paired device into one pane, with a device filter for when more
          than one is connected.
        </p>
      </Section>

      <Section title="Schedule an Agent">
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          The fastest way to use Automations: give it a name, pick a <a className="text-accent hover:underline" href="/docs/workspaces">workspace</a>,
          write a prompt, and set a schedule (or leave it Manual and run it whenever you like). No shell script, no cron syntax to memorize unless
          you want it.
        </p>
        <ul className="mt-4 space-y-2.5">
          <Field name="Workspace" description="Where the agent spawns — the same working directory you'd pick for any other session in that project." />
          <Field
            name="Agent command"
            description="Defaults to claude, and may carry flags (e.g. --model). Also works with codex and opencode."
          />
          <Field name="Prompt" description="Plain multiline text, sent to the agent verbatim once it's up and ready to work." />
        </ul>
        <p className="mt-4 text-sm leading-7 text-foreground-soft">
          When an automation fires, the agent spawns into that workspace exactly as if you&apos;d started it yourself — its permission prompts
          show up in its own terminal, and it appears in <a className="text-accent hover:underline" href="/docs/coding-agents">Coding Agents</a>{" "}
          and Alerts like any agent you launched by hand. You can even find its terminal the normal way, right inside that workspace, in addition
          to the Automations pane. Once it reports it&apos;s done, the run finishes as <strong>succeeded</strong> — its terminal is left open on
          purpose so you can read what it did; Spaces never closes a finished agent&apos;s session for you. If it ends up blocked waiting on your
          approval instead, that surfaces as a normal agent alert, same as any other agent.
        </p>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Because the agent&apos;s session outlives the run, a schedule set to Skip or Queue treats that lingering session as still going: it keeps
          recording skipped runs, or holding the next one queued, until the session ends on its own — or you close it, or use{" "}
          <strong>End agents</strong> on the run to reap it yourself. Nothing ever kills a live agent automatically.
        </p>
      </Section>

      <Section title="Script Automations">
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          For anything a single prompt doesn&apos;t cover — a maintenance job, a health check, an orchestrator that fans work out to several
          agents itself — a Script automation runs plain multiline shell text in the device&apos;s login shell, from a working directory you type
          or, on the local device, pick with a folder browser. Point it at a script file you already have with <code>zsh ./file.sh</code> instead
          of pasting the whole thing inline.
        </p>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Switching an Agent automation to Script prefills the editor with the equivalent CLI — spawning the agent, then sending the prompt — a
          starting point for a script that needs to do more than deliver one prompt (see <em>Orchestrated batch</em> below).
        </p>
      </Section>

      <Section title="Trigger, Concurrency, and Timeout">
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          These fields work the same way for either kind.
        </p>
        <ul className="mt-4 space-y-2.5">
          <Field
            name="Trigger"
            description="Manual, or Cron. A cron trigger offers preset builders — every N minutes, hourly at a minute, daily at a time, weekly on chosen days at a time — plus an Advanced mode for a raw 5-field cron expression. Whichever you use, the form previews the next three run times and flags a parse error inline."
          />
          <Field
            name="Concurrency policy"
            description="What happens when a fire lands while an earlier run of the same automation is still going (for an agent automation, that includes its spawned agent's session still being open). Allow always starts a new run alongside it — for independent runs that never share state. Skip records a skipped run instead of starting a new one — for a periodic check where two overlapping copies would waste resources or double up alerts. Queue holds at most one run to start right after the current one finishes — for a workflow where every tick should eventually happen; a fire that arrives while one is already queued is skipped rather than piling up further."
          />
          <Field
            name="Missed-run policy"
            description="What a restarted daemon does with a cron fire that elapsed while it was down. Run once fires a single catch-up run regardless of how many occurrences were missed. Skip records one skipped run instead. Either way the next fire time is recomputed from now."
          />
          <Field name="Timeout" description="An optional wall-clock budget. A run over budget is asked to stop and, if it doesn't, force-stopped shortly after." />
        </ul>
      </Section>

      <Section title="Runs">
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          The Runs tab lists every run of every automation, newest first, with its status, trigger (manual, cron, or a missed-run catch-up), start
          time, duration, and exit code; a skipped run shows why it was skipped. Open a running run to watch its live terminal exactly as it
          executes, or an ended run to replay its output read-only. A run can end <strong>succeeded</strong>, <strong>failed</strong> with its exit
          code, <strong>timed out</strong>, or <strong>canceled</strong> — cancel is available on any run that is still going. A failed or
          timed-out run also raises a dismissible entry in Alerts, naming the automation, the failure, and the device, that opens straight to that
          run.
        </p>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Any coding agents a run is responsible for — an agent automation&apos;s own agent, or one a script automation spawned itself — show up
          as chips on the run with a live status dot; clicking one opens that agent&apos;s terminal. A run that has finished but still has a live
          agent lingering offers <strong>End agents</strong> to stop it and finalize things, without touching the run&apos;s own status.
        </p>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Spaces keeps the newest 100 runs of each automation and prunes older ones together with their saved logs, so run history stays useful
          without growing unbounded.
        </p>
      </Section>

      <Section title="On iPhone">
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          The Automations tab on iOS shows the paired device&apos;s automations and lets you run one now or cancel one that&apos;s running —
          creating, editing, and deleting an automation stay Mac-only. Each row shows a status dot for its most recent run, its trigger, the next
          fire time, and whether it&apos;s disabled; tapping a row runs it, and the outcome (started, queued, or skipped) shows through the row
          once the list refreshes. A Runs screen lists every run the same way the Mac Runs tab does, with a Cancel action on a running one and an
          End agents action on a finished one with a lingering agent — iOS shows status only, with no terminal or replay view. The tab badges how
          many runs are currently in flight on the device.
        </p>
      </Section>

      <Section title="Example Patterns">
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Four patterns to copy and adapt. Two are Agent automations you set up entirely in the form; the other two are Script automations for
          cases that need more than one prompt.
        </p>
        <div className="mt-4 grid gap-4 md:grid-cols-2">
          <ScriptPattern
            title="Scheduled check"
            useCase="When to use: a nightly maintenance script that should never overlap itself and isn't worth catching up on if it's missed."
            script={NIGHTLY_AUDIT_SCRIPT}
            fields="trigger: cron 0 2 * * *  •  concurrency: skip  •  missed-run: skip"
          />
          <AgentPattern
            title="Morning review"
            useCase="When to use: start your day with an agent that has already read the project and is waiting with a summary — you never touch a shell."
            workspace="<the project's main workspace>"
            agentCommand="claude (default)"
            prompt="Review project status and identify next actions"
            fields="trigger: cron 30 6 * * 1-5  •  concurrency: allow  •  missed-run: skip"
          />
          <ScriptPattern
            title="Orchestrated batch"
            useCase="When to use: a headless orchestrator agent that fans work out to worker agents, watches them, and tears them all down before it exits."
            script={ORCHESTRATED_BATCH_SCRIPT}
            fields="trigger: manual or cron  •  concurrency: skip  •  timeout: bounds the whole workflow"
          />
          <ScriptPattern
            title="High-frequency poll"
            useCase="When to use: a check every few minutes that should reuse one long-lived agent instead of paying spawn cost on every tick."
            script={HIGH_FREQUENCY_POLL_SCRIPT}
            fields="trigger: cron */10 * * * *  •  concurrency: queue  •  missed-run: skip"
          />
        </div>
        <p className="mt-4 text-sm leading-7 text-foreground-soft">
          The <em>Orchestrated batch</em> pattern runs a coding agent non-interactively (<code>prompt.md</code> holds the orchestration
          instructions — see <a className="text-accent hover:underline" href="/docs/orchestration">Agent Orchestration</a> for a starting point),
          which means there&apos;s no one at the keyboard to approve its <code>spaces</code> CLI calls as it spawns and manages worker agents.
          Pre-approve those tool calls in the agent&apos;s own permission settings before scheduling it, and set a timeout so a batch that runs
          long or hangs doesn&apos;t run forever.
        </p>
      </Section>

      <Section title="See Also">
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <a className="text-accent hover:underline" href="/docs/coding-agents">Coding Agents</a> — how agent state, hooks, and Alerts work for any agent, spawned or not.</li>
          <li>• <a className="text-accent hover:underline" href="/docs/orchestration">Agent Orchestration</a> — the copy-paste orchestrator prompt behind the orchestrated-batch pattern.</li>
          <li>• <a className="text-accent hover:underline" href="/docs/cli">CLI Reference</a> — full flags for <code>spaces agent spawn</code> and <code>spaces terminal send</code>.</li>
          <li>• <a className="text-accent hover:underline" href="/docs/ios">iOS App</a> — pairing a device so its Automations screen can view, trigger, and cancel runs.</li>
        </ul>
      </Section>
    </DocsShell>
  );
}
