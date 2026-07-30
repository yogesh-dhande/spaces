import type { Metadata } from "next";
import { CodeBlock, Cmd } from "../components/code-block";
import { DocsShell } from "../components/docs-shell";

export const metadata: Metadata = {
  title: "Model Context Protocol",
  description:
    "Connect an MCP client such as Claude Code, Codex, or opencode to the spaces mcp server to list and drive projects, workspaces, and Spaces terminals.",
};

function Tool({ name, description }: { name: string; description: string }) {
  return (
    <li className="flex flex-col gap-0.5 sm:flex-row sm:gap-3">
      <span className="w-64 shrink-0 font-mono text-xs text-accent">{name}</span>
      <span className="text-sm leading-6 text-foreground-soft">{description}</span>
    </li>
  );
}

export default function McpReferencePage() {
  return (
    <DocsShell
      title="Model Context Protocol"
      description="Spaces ships an MCP server so a coding-agent client can inspect and drive your projects, workspaces, and terminals as tools."
      pagePath="/docs/mcp"
    >
      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Overview</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          <Cmd>spaces mcp</Cmd> runs a Model Context Protocol server over <strong>stdio</strong>: the MCP client launches it as a subprocess and exchanges JSON-RPC over standard input and output. Each tool call is forwarded to the running <Cmd>spacesd</Cmd> daemon, so the server uses the same orchestration path as the GUI and CLI.
        </p>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          The app shows ready-to-paste configuration under <strong>Settings → MCP</strong>, including the resolved path to the <Cmd>spaces</Cmd> binary. The examples below use <Cmd>spaces</Cmd> on your <Cmd>PATH</Cmd>; substitute the absolute path from Settings if the CLI is not on your <Cmd>PATH</Cmd>. Any MCP client that launches a stdio server works; the same <Cmd>command</Cmd> and <Cmd>args</Cmd> apply.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Claude Code</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Register the server once at user scope so the tools are available in every directory. Claude Code then spawns <Cmd>spaces mcp</Cmd> when it needs the tools.
        </p>
        <CodeBlock>{`claude mcp add spaces -s user -- spaces mcp`}</CodeBlock>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Codex CLI</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Add an <Cmd>mcp_servers</Cmd> table to <Cmd>~/.codex/config.toml</Cmd>.
        </p>
        <CodeBlock>{`[mcp_servers.spaces]
command = "spaces"
args = ["mcp"]`}</CodeBlock>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">opencode</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Add a <Cmd>spaces</Cmd> entry to the <Cmd>mcp</Cmd> block in <Cmd>~/.config/opencode/opencode.json</Cmd>.
        </p>
        <CodeBlock>{`{
  "mcp": {
    "spaces": {
      "type": "local",
      "command": ["spaces", "mcp"],
      "enabled": true
    }
  }
}`}</CodeBlock>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Tools</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          The server exposes project, workspace, and terminal tools.
        </p>
        <ul className="mt-3 space-y-1">
          <Tool name="spaces_project_list" description="List Spaces projects." />
          <Tool name="spaces_workspace_list" description="List workspaces, optionally filtered by project and including archived workspaces." />
          <Tool name="spaces_workspace_create" description="Create a workspace on this device. Requires a project and branch; accepts a title, base branch, and existing-branch reuse." />
          <Tool name="spaces_workspace_start" description="Ensure a workspace is running." />
          <Tool name="spaces_workspace_restart" description="Force a full stop and relaunch for a workspace." />
          <Tool name="spaces_terminal_list" description="List available Spaces terminal sessions." />
          <Tool name="spaces_terminal_tail" description="Read recent rendered output, omitting inline suggestions only in identified coding-agent sessions. Defaults to the last 20 lines." />
          <Tool name="spaces_terminal_send" description="Send UTF-8 text or explicit raw byte values to a terminal session, optionally submitting text as a paste followed by a separate Enter keystroke that every supported agent TUI (Claude Code, Codex, OpenCode) reads as a distinct submit rather than an unsubmitted paste." />
        </ul>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Agent lifecycle signals are intentionally not MCP tools. Coding agents report state through the CLI hook <Cmd>spaces agent signal</Cmd> so those hooks stay out of the agent-callable tool surface.
        </p>
      </article>
    </DocsShell>
  );
}
