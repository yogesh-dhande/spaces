import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";
import { CopyablePrompt } from "../components/copyable-prompt";

export const metadata: Metadata = {
  title: "Automations",
  description:
    "Run a shell command on your Mac or a paired Linux box, manually or on a schedule, even when Spaces is closed — with live output, replay, and cleanup handled for you.",
};

function Field({ name, description }: { name: string; description: string }) {
  return (
    <li className="flex flex-col gap-0.5 sm:flex-row sm:gap-3">
      <span className="w-40 shrink-0 font-mono text-xs text-accent">{name}</span>
      <span className="text-sm leading-6 text-foreground-soft">{description}</span>
    </li>
  );
}

function ExamplePattern({
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
    <div className="rounded-sm border border-line/70 p-5">
      <h3 className="text-lg font-semibold text-foreground">{title}</h3>
      <p className="mt-1.5 text-sm leading-6 text-foreground-soft">{useCase}</p>
      <CopyablePrompt label={`${title} command`} text={script} />
      <p className="mt-3 font-mono text-xs leading-6 text-foreground-soft">{fields}</p>
    </div>
  );
}

const NIGHTLY_AUDIT_SCRIPT = `git fetch --prune && ./scripts/audit.sh`;

const MORNING_REVIEW_SCRIPT = `SESSION_ID=$(spaces agent spawn --workspace <workspace-id> --command claude | cut -f1)
spaces terminal send text "$SESSION_ID" "Review project status and identify next actions" --submit`;

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
      description="An automation runs a shell command on your Mac or a connected Linux box, on demand or on a schedule, even when Spaces is closed. Watch it run live, replay it later, and let spawned coding agents keep working after it finishes."
      pagePath="/docs/automations"
    >
      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">What Is an Automation?</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          An automation is a named shell command tied to one device — your Mac or a paired Linux box — that runs either when you trigger it or on a cron schedule you set in your device&apos;s local time. It runs in the daemon, not the app, so a scheduled fire goes off whether Spaces is open or quit, and a remote automation keeps its own schedule even while your Mac is asleep. Each run gets its own terminal session, separate from any workspace: automations never show up in a workspace panel or in window cycling. The <strong>Automations</strong> row sits directly below Alerts in the sidebar and merges automations and runs across every paired device into one pane, with a device filter for when more than one is connected.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Setting Up an Automation</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Creating or editing an automation uses a labeled form — no cron syntax or shell quoting rules to memorize unless you want them. The command is plain multiline shell text that runs in the device&apos;s login shell from a working directory you type or, on the local device, pick with a folder browser.
        </p>
        <ul className="mt-4 space-y-2.5">
          <Field
            name="Trigger"
            description="Manual, or Cron. A cron trigger offers preset builders — every N minutes, hourly at a minute, daily at a time, weekly on chosen days at a time — plus an Advanced mode for a raw 5-field cron expression. Whichever you use, the form previews the next three run times and flags a parse error inline."
          />
          <Field
            name="Concurrency policy"
            description={
              "What happens when a fire lands while an earlier run of the same automation is still going. Allow always starts a new run alongside it — for independent runs that never share state. Skip records a skipped run instead of starting a new one — for a periodic check where two overlapping copies would waste resources or double up alerts. Queue holds at most one run to start right after the current one finishes — for a workflow where every tick should eventually happen; a fire that arrives while one is already queued is skipped rather than piling up further."
            }
          />
          <Field
            name="Missed-run policy"
            description="What a restarted daemon does with a cron fire that elapsed while it was down. Run once fires a single catch-up run regardless of how many occurrences were missed. Skip records one skipped run instead. Either way the next fire time is recomputed from now."
          />
          <Field name="Timeout" description="An optional wall-clock budget. A run over budget is asked to stop and, if it doesn't, force-stopped shortly after." />
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Runs</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          The Runs tab lists every run of every automation, newest first, with its status, trigger (manual, cron, or a missed-run catch-up), start time, duration, and exit code; a skipped run shows why it was skipped. Open a running run to watch its live terminal exactly as it executes, or an ended run to replay its output read-only. A run can end <strong>succeeded</strong>, <strong>failed</strong> with its exit code, <strong>timed out</strong>, or <strong>canceled</strong> — cancel is available on any run that is still going. A failed or timed-out run also raises a dismissible entry in Alerts, naming the automation, the failure, and the device, that opens straight to that run.
        </p>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Spaces keeps the newest 100 runs of each automation and prunes older ones together with their saved logs, so run history stays useful without growing unbounded.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Spawning Coding Agents From a Script</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          An automation&apos;s command is a normal shell script, so it can call <code>spaces agent spawn</code> to open a coding agent (Claude Code, Codex, or opencode) in its own Spaces terminal, exactly as if you&apos;d started it by hand. Because it&apos;s a real Spaces session, its permission prompts show up in that session&apos;s terminal, and once it reports its first event it shows up in <a className="text-accent hover:underline" href="/docs/coding-agents">Coding Agents</a> and Alerts like any other agent — you can watch it, subscribe to it, or drive it from another terminal.
        </p>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Every agent a run spawns is automatically attributed to that run — no extra flag needed — so the run&apos;s Runs-tab row shows a live-agents indicator while any of them are still going, and their transcripts are saved alongside the run&apos;s own log. Canceling or timing out a run captures the transcript of, and stops, any of its still-live spawned agents. An agent that outlives its own run — the point of the <em>Morning review</em> pattern below — is left running untouched; Spaces only captures its transcript and cleans up its row once it has ended on its own, and that cleanup happens when the automation&apos;s next run starts, not when it ends.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">On iPhone</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          The Automations tab on iOS shows the paired device&apos;s automations and lets you run one now or cancel one that&apos;s running — creating, editing, and deleting an automation stay Mac-only. Each row shows a status dot for its most recent run, its trigger, the next fire time, and whether it&apos;s disabled; tapping a row runs it, and the outcome (started, queued, or skipped) shows through the row once the list refreshes. A Runs screen lists every run the same way the Mac Runs tab does, with a Cancel action on a running one — iOS shows status only, with no terminal or replay view. The tab badges how many runs are currently in flight on the device.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Example Patterns</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Four complete patterns to copy and adapt. Each is a real automation command plus the trigger, concurrency, and missed-run settings that make it behave the way you&apos;d expect.
        </p>
        <div className="mt-4 grid gap-4 md:grid-cols-2">
          <ExamplePattern
            title="Scheduled check"
            useCase="When to use: a nightly maintenance task that should never overlap itself and isn't worth catching up on if it's missed."
            script={NIGHTLY_AUDIT_SCRIPT}
            fields="trigger: cron 0 2 * * *  •  concurrency: skip  •  missed-run: skip"
          />
          <ExamplePattern
            title="Morning review"
            useCase="When to use: start your day with an agent that has already read the project and is waiting with a summary — the automation itself finishes in seconds."
            script={MORNING_REVIEW_SCRIPT}
            fields="trigger: cron 30 6 * * 1-5  •  concurrency: allow  •  missed-run: skip"
          />
          <ExamplePattern
            title="Orchestrated batch"
            useCase="When to use: a headless orchestrator agent that fans work out to worker agents, watches them, and tears them all down before it exits."
            script={ORCHESTRATED_BATCH_SCRIPT}
            fields="trigger: manual or cron  •  concurrency: skip  •  timeout: bounds the whole workflow"
          />
          <ExamplePattern
            title="High-frequency poll"
            useCase="When to use: a check every few minutes that should reuse one long-lived agent instead of paying spawn cost on every tick."
            script={HIGH_FREQUENCY_POLL_SCRIPT}
            fields="trigger: cron */10 * * * *  •  concurrency: queue  •  missed-run: skip"
          />
        </div>
        <p className="mt-4 text-sm leading-7 text-foreground-soft">
          The <em>Orchestrated batch</em> pattern runs a coding agent non-interactively (<code>prompt.md</code> holds the orchestration instructions — see <a className="text-accent hover:underline" href="/docs/orchestration">Agent Orchestration</a> for a starting point), which means there&apos;s no one at the keyboard to approve its <code>spaces</code> CLI calls as it spawns and manages worker agents. Pre-approve those tool calls in the agent&apos;s own permission settings before scheduling it, and set a timeout so a batch that runs long or hangs doesn&apos;t run forever.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">See Also</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <a className="text-accent hover:underline" href="/docs/coding-agents">Coding Agents</a> — how agent state, hooks, and Alerts work for any agent, spawned or not.</li>
          <li>• <a className="text-accent hover:underline" href="/docs/orchestration">Agent Orchestration</a> — the copy-paste orchestrator prompt behind the orchestrated-batch pattern.</li>
          <li>• <a className="text-accent hover:underline" href="/docs/cli">CLI Reference</a> — full flags for <code>spaces agent spawn</code> and <code>spaces terminal send</code>.</li>
          <li>• <a className="text-accent hover:underline" href="/docs/ios">iOS App</a> — pairing a device so its Automations screen can view, trigger, and cancel runs.</li>
        </ul>
      </article>
    </DocsShell>
  );
}
