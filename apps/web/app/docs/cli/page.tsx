import type { Metadata } from "next";
import { CodeBlock, Cmd, InlineCode } from "../components/code-block";
import { DocsShell } from "../components/docs-shell";
import { DocLink } from "../components/doc-link";
import { Prose, Section } from "../components/section";
import { RefTable } from "../components/ref-table";

export const metadata: Metadata = {
  title: "CLI",
  description: "Every `spaces` command and flag.",
};

export default function CliReferencePage() {
  return (
    <DocsShell
      title="CLI"
      description="The spaces command-line tool for scripts, coding agents, and terminal workflows. This page lists every command and flag; see Orchestrate agents for what the agent commands actually do."
      pagePath="/docs/cli"
    >
      <Section title="Basics">
        <CodeBlock>{`spaces --version`}</CodeBlock>
        <Prose>
          Most commands act on the workspace containing the current directory when run inside one;
          pass <InlineCode>--workspace</InlineCode> to target another. Inside a Spaces terminal,
          commands that would otherwise need <InlineCode>--workspace</InlineCode> or{" "}
          <InlineCode>--session</InlineCode> read them from the terminal&apos;s{" "}
          <DocLink href="/docs/environment-variables">environment variables</DocLink> instead.{" "}
          <InlineCode>--device</InlineCode> runs the command against a paired device instead of
          this machine. <InlineCode>--json</InlineCode> is available on{" "}
          <InlineCode>agent list</InlineCode>, <InlineCode>agent status</InlineCode>,{" "}
          <InlineCode>agent spawn</InlineCode>, and <InlineCode>device pair</InlineCode> (without{" "}
          <InlineCode>--ssh</InlineCode> or <InlineCode>--link</InlineCode>) for machine-readable
          output.
        </Prose>
      </Section>

      <Section id="projects" title="Projects">
        <CodeBlock>{`spaces project list [--device <name-or-id>]`}</CodeBlock>
        <Prose>
          Lists the projects on this machine, or on a paired device with{" "}
          <InlineCode>--device</InlineCode>. See{" "}
          <DocLink href="/docs/projects">Projects</DocLink>.
        </Prose>
      </Section>

      <Section id="workspaces" title="Workspaces">
        <CodeBlock>{`spaces workspace list [--project <id>] [--device <name-or-id>]
spaces workspace create --project <id> --branch <branch> [--base-branch <branch>] [--existing-branch] [--device <name-or-id>]
spaces workspace start [--workspace <id>] [--device <name-or-id>]
spaces workspace stop [--workspace <id>] [--device <name-or-id>]
spaces workspace restart [--workspace <id>] [--device <name-or-id>]`}</CodeBlock>
        <Prose>
          Lists, creates, starts, stops, and restarts workspaces on this machine or a paired
          device. See{" "}
          <DocLink href="/docs/workspaces#start-stop-and-restart">
            Start, stop, and restart
          </DocLink>{" "}
          for what each action does.
        </Prose>
        <RefTable
          columns={["Flag", "Description"]}
          rows={[
            [<InlineCode key="project">--project &lt;id&gt;</InlineCode>, "Project filter for list; project id for creation."],
            [<InlineCode key="branch">--branch &lt;branch&gt;</InlineCode>, "Workspace branch for creation."],
            [
              <InlineCode key="base-branch">--base-branch &lt;branch&gt;</InlineCode>,
              "Base branch. Defaults to the project's default branch, then main or master.",
            ],
            [<InlineCode key="existing-branch">--existing-branch</InlineCode>, "Uses an existing branch instead of creating one."],
            [
              <InlineCode key="workspace">--workspace &lt;id&gt;</InlineCode>,
              "Workspace id for start, stop, and restart. Defaults to the workspace containing the current directory; required with --device.",
            ],
            [<InlineCode key="device">--device &lt;name-or-id&gt;</InlineCode>, "Paired device selector. Defaults to this machine."],
          ]}
        />
      </Section>

      <Section id="terminals" title="Terminals">
        <CodeBlock>{`spaces terminal list [--device <name-or-id>]
spaces terminal create [--workspace <id>] [--command <cmd>] [--title <title>]
spaces terminal send text <session-id> <text> [--submit] [--device <name-or-id>]
spaces terminal send bytes <session-id> <byte> [<byte>...] [--device <name-or-id>]
spaces terminal tail <session-id> [--lines <count>] [--device <name-or-id>]
spaces terminal show <session-id>
spaces terminal stop <session-id>`}</CodeBlock>
        <Prose>
          A terminal session survives quitting Spaces, so a session started here stays
          discoverable with <InlineCode>spaces terminal list</InlineCode>. Tail reconstructs
          rendered terminal output.
        </Prose>
        <RefTable
          columns={["Flag", "Description"]}
          rows={[
            [<InlineCode key="device">--device &lt;name-or-id&gt;</InlineCode>, "Paired device selector for list, send, and tail. Defaults to this machine's local sessions."],
            [<InlineCode key="workspace">--workspace &lt;id&gt;</InlineCode>, "Workspace id for terminal create; omit inside a workspace."],
            [<InlineCode key="command">--command &lt;cmd&gt;</InlineCode>, "Shell command. Defaults to a login shell."],
            [
              <InlineCode key="title">--title &lt;title&gt;</InlineCode>,
              <>
                Session title. Defaults to <InlineCode>shell-1</InlineCode>,{" "}
                <InlineCode>shell-2</InlineCode>, and so on, the first not already in use.
              </>,
            ],
            [
              <InlineCode key="submit">--submit</InlineCode>,
              "Sends the text as a paste followed by a separate Enter keystroke, so Claude Code, Codex, and opencode submit the line instead of leaving it unsubmitted.",
            ],
            [<InlineCode key="byte">&lt;byte&gt;</InlineCode>, "Decimal byte value from 0 through 255."],
            [<InlineCode key="lines">--lines &lt;count&gt;</InlineCode>, "Number of lines to print. Defaults to 20."],
            [<InlineCode key="show">show &lt;session&gt;</InlineCode>, "Opens a native Spaces window for the session on macOS."],
            [
              <InlineCode key="stop">stop &lt;session&gt;</InlineCode>,
              "Ends the session on this machine the way stopping its runtime target in the app does: its row disappears and its pane closes. A session that has already ended is refused.",
            ],
          ]}
        />
      </Section>

      <Section id="agents" title="Agents">
        <CodeBlock>{`spaces agent list [--workspace <id>] [--json] [--device <name-or-id>]
spaces agent status [--session <id>] [--json] [--device <name-or-id>]
spaces agent brief write "<markdown>" [--session <id>] [--device <name-or-id>]
spaces agent brief write < brief.md
spaces agent brief read [--session <id>] [--device <name-or-id>]
spaces agent brief clear [--session <id>] [--device <name-or-id>]
spaces agent spawn --command <cmd> [--workspace <id>] [--title <title>] [--timeout <seconds>] [--json] [--device <name-or-id>]
spaces agent kill <session> [--device <name-or-id>]
spaces agent subscribe <child-session> [--subscriber <id>] [--device <name>]
spaces agent unsubscribe <child-session> [--subscriber <id>] [--device <name>]
spaces agent signal <event> [--workspace <id>] [--session <id>] [--agent-session <id>]`}</CodeBlock>
        <Prose>
          <Cmd>spaces agent brief write</Cmd> reads the markdown from the argument or from
          standard input (put <Cmd>--</Cmd> before markdown that starts with{" "}
          <InlineCode>-</InlineCode>); an empty document clears the brief. Every agent command
          except <Cmd>signal</Cmd> accepts <InlineCode>--device</InlineCode> to target a paired
          device. See{" "}
          <DocLink href="/docs/orchestration">Orchestrate agents</DocLink> for what each command
          does, and <DocLink href="/docs/orchestration#brief">Briefs</DocLink> for the brief
          commands specifically.
        </Prose>
        <RefTable
          columns={["Flag", "Description"]}
          rows={[
            [
              <InlineCode key="command">--command &lt;cmd&gt;</InlineCode>,
              "Command that launches a supported coding agent (claude, codex, or opencode).",
            ],
            [
              <InlineCode key="workspace">--workspace &lt;id&gt;</InlineCode>,
              "Workspace id for spawn. Defaults to the workspace containing the current directory; required with --device.",
            ],
            [<InlineCode key="title">--title &lt;title&gt;</InlineCode>, "Window or session title for spawn. Defaults to the agent's name."],
            [<InlineCode key="timeout">--timeout &lt;seconds&gt;</InlineCode>, "Seconds spawn waits for the agent to be ready for input. Defaults to 90."],
            [
              <InlineCode key="session">--session &lt;id&gt;</InlineCode>,
              "Spaces terminal session id for status, brief, and signal. Defaults to SPACES_TERMINAL_TRACKING_ID.",
            ],
            [
              <InlineCode key="subscriber">--subscriber &lt;id&gt;</InlineCode>,
              "The watching terminal's session id, for subscribe and unsubscribe (the child being watched is the positional argument). Defaults to SPACES_TERMINAL_TRACKING_ID.",
            ],
            [
              <InlineCode key="agent-session">--agent-session &lt;id&gt;</InlineCode>,
              "The agent's own conversation id, for signal, when its hooks pass one as an argument. Defaults to the id in the hook payload.",
            ],
            [<InlineCode key="device">--device &lt;name-or-id&gt;</InlineCode>, "Paired device selector. Defaults to this machine's local sessions."],
            [<InlineCode key="json">--json</InlineCode>, "Emits machine-readable output where offered."],
          ]}
        />
      </Section>

      <Section id="devices" title="Devices">
        <CodeBlock>{`spaces device list
spaces device pair [--json]
spaces device pair --ssh user@host [--ssh-port <port>]
spaces device pair --link <spaces-pair-link>
spaces device remove <name-or-id>`}</CodeBlock>
        <Prose>
          Lists, pairs, and removes paired devices. See{" "}
          <DocLink href="/docs/remote-access#pairing">Pairing</DocLink> for how each form of{" "}
          <Cmd>spaces device pair</Cmd> works.
        </Prose>
      </Section>

      <Section id="mcp" title="MCP">
        <CodeBlock>{`spaces mcp`}</CodeBlock>
        <Prose>
          Runs the Spaces MCP server over standard input and output, so an MCP client such as
          Claude Code, Codex, or opencode can connect. See{" "}
          <DocLink href="/docs/mcp">MCP tools</DocLink> for setup and the tool list.
        </Prose>
      </Section>

      <Section id="service-updates" title="Service updates">
        <CodeBlock>{`spaces daemon apply-update`}</CodeBlock>
        <Prose>
          Applies a downloaded update to the Spaces service on this machine in place, without
          ending its sessions. See{" "}
          <DocLink href="/docs/installation#updates">Updates</DocLink>.
        </Prose>
      </Section>
    </DocsShell>
  );
}
