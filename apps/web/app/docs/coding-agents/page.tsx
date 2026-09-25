import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";
import { DocLink } from "../components/doc-link";
import { Cmd, InlineCode } from "../components/code-block";
import { Prose, Section } from "../components/section";

export const metadata: Metadata = {
  title: "Agent status",
  description:
    "How Spaces knows whether Claude Code, Codex, or opencode is working, waiting for you, or done.",
};

export default function CodingAgentsDocsPage() {
  return (
    <DocsShell
      title="Agent status"
      description="Spaces tracks a coding agent's state in your sidebar, so you always know which one needs you next."
      pagePath="/docs/coding-agents"
    >
      <Section id="supported-agents" title="Supported agents">
        <Prose>
          Spaces tracks Claude Code, Codex, and opencode. Start any of them in a Spaces terminal and it
          shows up as its own row, listed under Coding Agents in that terminal&apos;s workspace.
        </Prose>
      </Section>

      <Section id="hooks" title="Status hooks">
        <Prose>
          Spaces reports agent state through a small hook it installs into each agent&apos;s own
          configuration. Spaces offers to install these the first time it detects an agent, in the
          skippable coding-agents step at first launch, and any time after that from{" "}
          <strong>Settings &rarr; Coding Agents</strong>. It touches{" "}
          <InlineCode>~/.claude/settings.json</InlineCode> for Claude Code,{" "}
          <InlineCode>~/.codex/hooks.json</InlineCode> for Codex (which also turns on Codex&apos;s hooks
          feature), and a plugin file under{" "}
          <InlineCode>~/.config/opencode/plugin/</InlineCode> for opencode.
        </Prose>
        <Prose>
          Settings &rarr; Coding Agents shows, per agent, one of five states: not installed, out of
          date, switched off in the agent, awaiting Codex trust review (Codex asks you to approve a hook
          before it will run it), or installed. A detected agent gets an Install, Update, or Reinstall
          action to match.
        </Prose>
      </Section>

      <Section id="states" title="States">
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <strong>Working</strong> (green): the agent is running a turn.</li>
          <li>
            • <strong>Blocked</strong> (amber): the agent is waiting on a permission prompt or your
            answer. Counts toward Alerts and the Dock badge until it clears on its own.
          </li>
          <li>
            • <strong>Done</strong> (blue): the agent finished a turn. Stays in Alerts and the Dock
            badge until you dismiss it.
          </li>
          <li>
            • <strong>Idle</strong> (gray): not doing anything at the moment, whether it is sitting at
            its prompt or has not started a turn yet.
          </li>
        </ul>
        <Prose>
          When the agent&apos;s process exits, its row reads &quot;Exited&quot; while the terminal stays
          open, and disappears once its terminal session ends; closing its pane only detaches the
          terminal and leaves the exited row in place. An agent that asks a question in plain
          text, without going through a permission prompt, shows as done rather than blocked, since
          Spaces has no hook for a plain-text question.
        </Prose>
        <Prose>
          Status shows on the sidebar row, in <DocLink href="/docs/alerts">Alerts</DocLink>, in the
          command palette, in the All agents cycling mode, and on the iPhone Agents tab.
        </Prose>
      </Section>

      <Section id="briefs" title="Agent briefs">
        <Prose>
          A coding agent can keep one short brief: a status page it writes about itself, covering what
          it is doing, when a long step should finish, questions for you, and its task list. Spaces
          shows it read-only beside the agent&apos;s terminal, and it is the agent&apos;s own writing,
          never something Spaces adds for it. Any terminal where Spaces has detected a supported coding
          agent can keep one.
        </Prose>
        <Prose>
          On the Mac it renders as a column at the trailing edge of the agent&apos;s pane. Show or hide
          it with <InlineCode>⌥⌘B</InlineCode>, the footer&apos;s brief glyph, the pane&apos;s
          &quot;&#8943;&quot; menu (&quot;Hide Brief&quot; or &quot;Show Brief&quot;), or a global panel
          window&apos;s title strip. On iPhone and iPad, a brief button in the terminal&apos;s top bar
          opens a sheet, which also opens on its own for an agent whose brief you have not dismissed.
          The sidebar and the iPhone agent rows show a small glyph when the agent has a brief.
        </Prose>
        <Prose>
          A brief&apos;s first line is its one-line summary, shown wherever there is no room for the
          whole document: <Cmd>spaces agent list</Cmd>, <Cmd>spaces agent status</Cmd>, and subscribe
          notifications. For the commands that read and write a brief, see{" "}
          <DocLink href="/docs/orchestration#brief">briefs</DocLink>. For your own notes on a workspace,
          see <DocLink href="/docs/workspaces#notes">workspace notes</DocLink>.
        </Prose>
      </Section>

      <Section id="stopping" title="Stopping an agent">
        <Prose>
          End an agent and its terminal from its sidebar row, from the iPhone Agents tab, or with{" "}
          <Cmd>spaces agent kill</Cmd>.
        </Prose>
      </Section>

      <Section title="Driving several agents">
        <Prose>
          Once agents report their state, one agent, or you from a single terminal, can watch and drive
          the others across your workspaces and devices. See{" "}
          <DocLink href="/docs/orchestration">Orchestrate agents</DocLink>.
        </Prose>
      </Section>

      <Section title="See also">
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>
            • <DocLink href="/docs/orchestration">Orchestrate agents</DocLink>, for spawning, watching,
            and stopping agents from another agent.
          </li>
          <li>
            • <DocLink href="/docs/automations">Automations</DocLink>, for running an agent on a
            schedule.
          </li>
          <li>
            • <DocLink href="/docs/cli#agents">CLI</DocLink>, for every <Cmd>spaces agent</Cmd> command.
          </li>
        </ul>
      </Section>
    </DocsShell>
  );
}
