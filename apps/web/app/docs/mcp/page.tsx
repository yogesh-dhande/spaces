import type { Metadata } from "next";
import { CodeBlock, Cmd, InlineCode } from "../components/code-block";
import { DocsShell } from "../components/docs-shell";
import { DocLink } from "../components/doc-link";
import { Prose, Section } from "../components/section";
import { RefTable } from "../components/ref-table";

export const metadata: Metadata = {
  title: "MCP tools",
  description:
    "Connect Claude Code, Codex, or opencode to Spaces and see the tools they get.",
};

const TOOL_ROWS: [string, string][] = [
  ["spaces_project_list", "List projects on this or a paired device."],
  ["spaces_workspace_list", "List workspaces, optionally filtered by project."],
  [
    "spaces_workspace_create",
    "Create a workspace: project and branch required, plus a base branch or existingBranch to reuse a branch, and an optional device. Not started automatically.",
  ],
  ["spaces_workspace_start", "Ensure a workspace is running."],
  ["spaces_workspace_restart", "Force a full stop and relaunch for a workspace."],
  ["spaces_terminal_list", "List available terminal sessions."],
  ["spaces_terminal_tail", "Read a session's recent output, defaulting to the last 20 lines."],
  [
    "spaces_terminal_send",
    "Send text or raw bytes to a terminal session, optionally submitting it as a paste plus a separate Enter keystroke.",
  ],
  ["spaces_agent_list", "List coding-agent sessions, optionally filtered by workspace."],
  ["spaces_agent_status", "Read one agent session's status, brief summary, and context."],
  [
    "spaces_agent_spawn",
    "Start a supported agent (claude, codex, or opencode) in a workspace and wait until it is ready for input.",
  ],
  ["spaces_agent_kill", "End a coding-agent session and its terminal."],
  ["spaces_agent_subscribe", "Watch an agent from this terminal; get told when it goes blocked, done, or exits."],
  ["spaces_agent_unsubscribe", "Stop watching an agent."],
  [
    "spaces_agent_brief_write",
    "Replace an agent's brief, the short status page Spaces shows beside its terminal. An empty string clears it.",
  ],
  ["spaces_agent_brief_read", "Read an agent's brief in full, with when it was last updated."],
  ["spaces_agent_brief_clear", "Remove an agent's brief."],
  ["spaces_device_list", "List the paired devices this machine can reach."],
];

export default function McpReferencePage() {
  return (
    <DocsShell
      title="MCP tools"
      description="Spaces ships an MCP server so a coding agent can inspect and drive your projects, workspaces, and terminals as tools."
      pagePath="/docs/mcp"
    >
      <Section title="What it is">
        <Prose>
          <Cmd>spaces mcp</Cmd> starts a Model Context Protocol server: an MCP client (a coding agent
          such as Claude Code, Codex, or opencode) launches it as a subprocess and calls its tools
          directly, over standard input and output. Every call runs against the same Spaces service on
          this machine that the app and the CLI use, so an agent sees the same projects, workspaces, and
          terminals you do.
        </Prose>
      </Section>

      <Section id="setup" title="Setup">
        <Prose>
          <strong>Settings &rarr; MCP &rarr; &quot;MCP Client Setup&quot;</strong> shows a ready-to-paste
          snippet per agent, including the resolved path to the <Cmd>spaces</Cmd> binary. The examples
          below use <InlineCode>spaces</InlineCode> on your <InlineCode>PATH</InlineCode>; substitute the
          absolute path from Settings if the CLI is not on it.
        </Prose>
        <p className="mt-4 text-sm font-semibold text-foreground">Claude Code</p>
        <Prose>Register the server once at user scope, and Claude Code spawns it when it needs the tools.</Prose>
        <CodeBlock>{`claude mcp add spaces -s user -- spaces mcp`}</CodeBlock>
        <p className="mt-4 text-sm font-semibold text-foreground">Codex CLI</p>
        <Prose>
          Add an <InlineCode>mcp_servers</InlineCode> table to <InlineCode>~/.codex/config.toml</InlineCode>.
        </Prose>
        <CodeBlock>{`[mcp_servers.spaces]
command = "spaces"
args = ["mcp"]`}</CodeBlock>
        <p className="mt-4 text-sm font-semibold text-foreground">opencode</p>
        <Prose>
          Add a <InlineCode>spaces</InlineCode> entry to the <InlineCode>mcp</InlineCode> block in{" "}
          <InlineCode>~/.config/opencode/opencode.json</InlineCode>.
        </Prose>
        <CodeBlock>{`{
  "mcp": {
    "spaces": {
      "type": "local",
      "command": ["spaces", "mcp"],
      "enabled": true
    }
  }
}`}</CodeBlock>
      </Section>

      <Section id="tools" title="Tools">
        <Prose>
          The server exposes project, workspace, terminal, paired-device, and coding-agent tools. There
          is no stop tool for a workspace and no signal tool: an agent reports its own lifecycle only
          through the CLI hook <Cmd>spaces agent signal</Cmd>, which is intentionally left off the tool
          surface, so an agent can read another agent&apos;s status but never forge it.
        </Prose>
        <RefTable
          columns={["Tool", "What it does"]}
          rows={TOOL_ROWS.map(([name, description]) => [<InlineCode key={name}>{name}</InlineCode>, description])}
        />
        <Prose>
          The brief tools act on the calling terminal&apos;s own agent unless given a session, so an
          agent connected to this server keeps its own brief with no extra setup. See{" "}
          <DocLink href="/docs/coding-agents#briefs">agent briefs</DocLink> for what a brief is and where
          it shows, and <DocLink href="/docs/orchestration#brief">briefs</DocLink> for the matching CLI
          commands. The rest of the agent tools are covered in full at{" "}
          <DocLink href="/docs/orchestration">Orchestrate agents</DocLink>.
        </Prose>
      </Section>
    </DocsShell>
  );
}
