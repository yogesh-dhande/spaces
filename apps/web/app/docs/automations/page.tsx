import type { Metadata } from "next";
import type { ReactNode } from "react";
import { DocsShell } from "../components/docs-shell";
import { CopyablePrompt } from "../components/copyable-prompt";
import { DocLink } from "../components/doc-link";
import { Cmd, InlineCode } from "../components/code-block";
import { Prose, Section } from "../components/section";

export const metadata: Metadata = {
  title: "Automations",
  description:
    "Run a script or an agent on any device, by hand or on a schedule, and review each run.",
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

const HIGH_FREQUENCY_POLL_SCRIPT = `claude -p "Check the queue and process the next item."`;

export default function AutomationsDocsPage() {
  return (
    <DocsShell
      title="Automations"
      description="Run a script or spawn an agent with a prompt on your Mac or a paired device, by hand or on a schedule, and review every run afterward."
      pagePath="/docs/automations"
    >
      <Section title="What an automation is">
        <Prose>
          An automation is a named task tied to one workspace on one device (your Mac or a paired
          device), which runs either when you trigger it or on a cron schedule in that device&apos;s
          local time. It runs in the Spaces service, so it keeps its schedule whether Spaces is open or closed.
          A device that sleeps pauses everything on it, including a due schedule; when it wakes, the
          Spaces service resumes and fires that schedule late, regardless of its missed-run policy. The
          missed-run policy only decides what happens to a fire that elapsed while the Spaces service
          itself was stopped, not one delayed by sleep. There are two
          kinds: an <strong>agent</strong> automation spawns a
          coding agent into a workspace and hands it a prompt; a <strong>script</strong> automation runs
          a shell command. Automations are not available on the{" "}
          <DocLink href="/docs/projects#home-workspace">home workspace</DocLink>.
        </Prose>
        <Prose>
          The sidebar&apos;s Automations row sits directly below Alerts and merges automations and runs
          across every paired device into one pane, with a device filter for when more than one is
          connected. Its badge counts runs currently in flight.
        </Prose>
      </Section>

      <Section id="creating" title="Creating an automation">
        <Prose>
          Give it a name, a device (fixed at creation, since the automation lives there), and a{" "}
          <DocLink href="/docs/workspaces">workspace</DocLink>. A freshly created automation defaults to
          the Agent type.
        </Prose>
        <ul className="mt-4 space-y-2.5">
          <Field
            name="Agent"
            description="An agent command (defaults to claude, and may carry flags such as --model; also works with codex and opencode) and a multiline prompt sent once the agent is ready for it."
          />
          <Field
            name="Script"
            description="A multiline script that runs in the device's login shell at the workspace's directory."
          />
          <Field name="Timeout" description="An optional wall-clock budget. A run over budget is asked to stop and, if it doesn't, force-stopped shortly after." />
          <Field
            name="Concurrency"
            description="What happens when a fire lands while an earlier run is still going. Skip (the default for a freshly created automation) records a skipped run instead of starting another. Queue holds at most one run to start right after the current one finishes. Allow always starts another run alongside it."
          />
        </ul>
        <Prose>
          When an agent automation fires, the agent spawns into that workspace exactly as if you had
          started it yourself: its permission prompts show up in its own terminal, and it appears in{" "}
          <DocLink href="/docs/coding-agents">Agent status</DocLink> and{" "}
          <DocLink href="/docs/alerts">Alerts</DocLink> like any agent you launched by hand. Once it
          reports it is done, the run finishes as succeeded, and its terminal is left open so you can
          read what it did; Spaces never closes a finished agent&apos;s session for you. Because that
          session outlives the run, a Skip or Queue automation keeps treating it as still going, and
          keeps recording skipped runs or holding the next one queued, until the session ends on its
          own or you use &quot;End agents&quot; on the run; closing its pane only detaches it and leaves
          the automation blocked.
        </Prose>
      </Section>

      <Section id="triggers" title="Triggers">
        <ul className="mt-3 space-y-2.5">
          <Field
            name="Manual"
            description="Runs only when you ask, from the automation's row or its iPhone screen."
          />
          <Field
            name="Cron"
            description="Preset builders (every N minutes, hourly at a minute, daily at a time, weekly on chosen days) plus an Advanced mode for a raw 5-field cron expression. The form previews the next three run times and flags a parse error inline."
          />
          <Field
            name="Next run at"
            description="A one-time override for the next occurrence only; the automation's own schedule resumes once it fires."
          />
          <Field
            name="Missed-run policy"
            description={`What happens to a cron fire that elapsed while the device's Spaces service was down. "Run once" fires a single catch-up run; "Skip" records one skipped run instead.`}
          />
        </ul>
        <Prose>
          A run&apos;s trigger shows in the Runs tab as manual, cron, scheduled (from a one-time
          override), missed catch-up, or restored (an agent automation&apos;s session brought back after
          a restart; see <DocLink href="/docs/restarts#restore">bringing agents back</DocLink>).
        </Prose>
      </Section>

      <Section id="runs" title="Runs">
        <Prose>
          The Runs tab lists every run, newest first, with its status, trigger, start time, duration,
          and exit code; a skipped run shows why. Open a running run to watch its live terminal, or an
          ended run to replay its output read-only. A run ends succeeded, failed with its exit code,
          timed out, or canceled (available on any run still going). A failed or timed-out run also
          raises a dismissible <DocLink href="/docs/alerts">alert</DocLink>, naming the automation, the
          failure, and the device, that opens straight to that run.
        </Prose>
        <Prose>
          Any coding agents a run is responsible for show as chips with a live status dot; clicking one
          opens that agent&apos;s terminal. A run that has finished but still has a live agent lingering
          offers &quot;End agents&quot; to stop it, without changing the run&apos;s own status. Spaces
          keeps the newest 100 runs of each automation and prunes older ones with their saved logs; a
          run whose coding agent is still running is kept until that agent ends.
        </Prose>
      </Section>

      <Section id="on-iphone" title="On iPhone">
        <Prose>
          The Automations tab shows the paired device&apos;s automations. Creating, editing, and deleting
          an automation stay Mac-only. Each row shows a status dot for its most recent run, its trigger,
          the next fire time, and whether it is disabled; tapping a row opens that automation&apos;s
          detail screen, with its schedule, command, and run history. Run Now, and setting a one-time next
          run, live in a sheet opened from the detail screen&apos;s &quot;Next run&quot; row. A Runs screen
          (from the detail screen or the toolbar&apos;s Recent Runs) lists every run the same way the
          Mac&apos;s Runs tab does, with Cancel on a running one and End agents on a finished one with a
          lingering agent; tapping a run row opens its live terminal while it runs or its read-only
          transcript once it has ended.
        </Prose>
      </Section>

      <Section id="examples" title="Example patterns">
        <Prose>
          Four patterns to copy and adapt. One is an agent automation you set up entirely in the form;
          the other three are script automations for cases that need more than one prompt.
        </Prose>
        <div className="mt-4 grid gap-4 md:grid-cols-2">
          <ScriptPattern
            title="Scheduled check"
            useCase="A nightly maintenance script that should never overlap itself and isn't worth catching up on if it's missed."
            script={NIGHTLY_AUDIT_SCRIPT}
            fields="trigger: cron 0 2 * * *  •  concurrency: skip  •  missed-run: skip"
          />
          <AgentPattern
            title="Morning review"
            useCase="Start your day with an agent that has already read the project and is waiting with a summary."
            workspace="the project's main workspace"
            agentCommand="claude (default)"
            prompt="Review project status and identify next actions"
            fields="trigger: cron 30 6 * * 1-5  •  concurrency: allow  •  missed-run: skip"
          />
          <ScriptPattern
            title="Orchestrated batch"
            useCase="A headless orchestrator agent that fans work out to worker agents, watches them, and tears them all down before it exits."
            script={ORCHESTRATED_BATCH_SCRIPT}
            fields="trigger: manual or cron  •  concurrency: skip  •  timeout: bounds the whole workflow"
          />
          <ScriptPattern
            title="High-frequency poll"
            useCase="A check every few minutes, each a fresh one-shot agent rather than a session left open between ticks."
            script={HIGH_FREQUENCY_POLL_SCRIPT}
            fields="trigger: cron */10 * * * *  •  concurrency: skip  •  missed-run: skip"
          />
        </div>
        <Prose>
          The <strong>Orchestrated batch</strong> pattern runs a coding agent non-interactively (
          <InlineCode>prompt.md</InlineCode> holds the orchestration instructions; see{" "}
          <DocLink href="/docs/orchestration">Orchestrate agents</DocLink> for a starting point), so
          there is no one at the keyboard to approve its <Cmd>spaces</Cmd> CLI calls as it spawns and
          manages worker agents. Pre-approve those tool calls in the agent&apos;s own permission settings
          before scheduling it, and set a timeout so a run that hangs does not run forever.
        </Prose>
      </Section>

      <Section title="See also">
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>
            • <DocLink href="/docs/coding-agents">Agent status</DocLink>, for how agent state, hooks, and
            Alerts work for any agent, spawned or not.
          </li>
          <li>
            • <DocLink href="/docs/orchestration">Orchestrate agents</DocLink>, for the orchestrator
            prompt behind the orchestrated-batch pattern.
          </li>
          <li>
            • <DocLink href="/docs/cli#agents">CLI</DocLink>, for the full flags for{" "}
            <Cmd>spaces agent spawn</Cmd> and <Cmd>spaces terminal send</Cmd>.
          </li>
          <li>
            • <DocLink href="/docs/ios">iPhone app</DocLink>, for pairing a device so its Automations
            screen can view, trigger, and cancel runs.
          </li>
        </ul>
      </Section>
    </DocsShell>
  );
}
