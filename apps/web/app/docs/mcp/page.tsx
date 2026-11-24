import type { Metadata } from "next";
import { CodeBlock, Cmd, InlineCode } from "../components/code-block";
import { CopyablePrompt } from "../components/copyable-prompt";
import { DocsShell } from "../components/docs-shell";
import { DocLink } from "../components/doc-link";
import { Prose, Section } from "../components/section";
import { RefTable } from "../components/ref-table";

export const metadata: Metadata = {
  title: "MCP tools",
  description:
    "Connect Claude Code, Codex, opencode, GitHub Copilot CLI, pi, or Amp to Spaces, with a setup prompt your agent can run, and see the tools and workflows they get.",
};

const TOOL_ROWS: [string, string][] = [
  ["spaces_project_list", "List projects on this or a paired device."],
  [
    "spaces_project_create",
    "Add a project from a folder (an absolute or ~ path) or a Git URL, with an optional device. Imports any spaces.yaml and returns the project and its default workspace, not started.",
  ],
  ["spaces_workspace_list", "List workspaces, optionally filtered by project."],
  [
    "spaces_workspace_create",
    "Create a workspace: project and branch required, plus a base branch or existingBranch to reuse a branch, and an optional device. Not started automatically.",
  ],
  ["spaces_workspace_start", "Ensure a workspace is running."],
  ["spaces_workspace_restart", "Relaunch a workspace's configured processes."],
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
    "Start a supported agent (claude, codex, opencode, copilot, pi, or amp) in a workspace and wait until it is ready for input.",
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
  [
    "spaces_workflow",
    "Read the steps of a workflow: handoff, dispatch, standup, or unblock. See Workflows above.",
  ],
];

// Written for the agent that receives it: plain steps, with the user's consent and the hook approval
// kept in the user's hands. Avoids backticks so it stays a simple template literal.
const SETUP_PROMPT = `Install Spaces (https://usespaces.dev), a Mac app that runs coding agents in their own workspaces, and connect it to you so you can use its tools. Work through these steps in order. If a step fails, stop and tell me what happened instead of working around it.

1. If ~/.spaces/bin/spaces already exists, Spaces is installed: skip to step 5. Otherwise ask me for permission before installing anything.
2. Download the DMG attached to the latest release at https://github.com/yogesh-dhande/spaces/releases/latest into a new temporary folder, and mount it read-only.
3. Verify the DMG before running anything from it. Copy Spaces.app and Install Spaces.app out of the mounted DMG into the temporary folder with ditto --noextattr --norsrc (Finder metadata in the DMG makes the strict check fail). For each copy, run codesign --verify --deep --strict and confirm codesign -dv reports TeamIdentifier=BEMDA62NB6. Also run spctl --assess --type execute on the Spaces.app copy, and spctl --assess --type open --context context:primary-signature on the DMG file itself; together these are the notarization check. If any check fails, stop.
4. Open Install Spaces.app from the mounted DMG. Do not copy Spaces.app to /Applications yourself: the installer does that and also sets up the command-line tools and the background service. Tell me to click Install, enter my Mac password, and click Open Spaces when it finishes. Wait until ~/.spaces/bin/spaces exists, then eject the DMG. If it does not appear, stop and tell me. Then ask me to finish the first-launch setup in the Spaces window, including the coding-agent hooks step. Never approve hooks or trust prompts for me. Wait until I say I am done.
5. Connect yourself. The spaces command is ~/.spaces/bin/spaces. Ask me before changing any configuration, then register Spaces for the agent you are running as:
   - Claude Code: claude mcp add spaces -s user -- ~/.spaces/bin/spaces mcp
   - Codex (including the ChatGPT desktop app): Spaces adds its own entry to ~/.codex/config.toml when it installs the Codex hooks. Run codex mcp list to confirm spaces is there, and add nothing yourself. If it is missing (for example, Codex was installed after Spaces), ask me to install the Codex hooks in Spaces under Settings, Coding Agents, then check again.
   - Any other agent: use the matching command at https://usespaces.dev/docs/mcp#setup, with ~/.spaces/bin/spaces as the path to spaces.
6. Tell me to start a new session in this agent so the Spaces tools load, then suggest I ask: What are my coding agents doing?`;

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
          such as Claude Code, Codex, opencode, GitHub Copilot CLI, pi, or Amp) launches it as a subprocess and calls its tools
          directly, over standard input and output. Every call runs against the same Spaces service on
          this machine that the app and the CLI use, so an agent sees the same projects, workspaces, and
          terminals you do.
        </Prose>
      </Section>

      <Section id="setup" title="Setup">
        <p className="text-sm font-semibold text-foreground">Let your agent set it up</p>
        <Prose>
          Paste this into Claude Code, Codex, the ChatGPT desktop app, or another coding agent on your
          Mac. It asks before installing Spaces and checks the download is signed and notarized. You
          then click through the installer in the DMG yourself, finish the first-launch setup in the
          app, and approve the agent hooks. Your agent registers the server for itself.
        </Prose>
        <CopyablePrompt label="The setup prompt" text={SETUP_PROMPT} />
        <p className="mt-6 text-sm font-semibold text-foreground">Or register it by hand</p>
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
          Installing Codex&apos;s hooks from Settings &rarr; Coding Agents adds this entry for you. To add
          it by hand, put an <InlineCode>mcp_servers</InlineCode> table in{" "}
          <InlineCode>~/.codex/config.toml</InlineCode>. Codex passes a server only the environment
          variables listed in <InlineCode>env_vars</InlineCode>, and these two are how the server knows
          which terminal is calling.
        </Prose>
        <CodeBlock>{`[mcp_servers.spaces]
command = "spaces"
args = ["mcp"]
env_vars = ["SPACES_TERMINAL_TRACKING_ID", "SPACES_AUTOMATION_RUN_ID"]`}</CodeBlock>
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
        <p className="mt-4 text-sm font-semibold text-foreground">GitHub Copilot CLI</p>
        <Prose>Run once in your terminal.</Prose>
        <CodeBlock>{`copilot mcp add spaces -- spaces mcp`}</CodeBlock>
        <p className="mt-4 text-sm font-semibold text-foreground">pi</p>
        <Prose>Run once in your terminal.</Prose>
        <CodeBlock>{`pi mcp add spaces -- spaces mcp`}</CodeBlock>
        <p className="mt-4 text-sm font-semibold text-foreground">Amp</p>
        <Prose>Run once in your terminal.</Prose>
        <CodeBlock>{`amp mcp add spaces -- spaces mcp`}</CodeBlock>
      </Section>

      <Section id="workflows" title="Workflows">
        <Prose>
          The server also carries four workflows, so a connected agent knows how to do them with nothing
          else installed. When it connects, the agent is told what each is for, and it reads the full
          steps with <InlineCode>spaces_workflow</InlineCode> before doing one. Ask for them in plain
          words.
        </Prose>
        <RefTable
          columns={["Workflow", "Ask for it when you want to"]}
          rows={[
            [<InlineCode key="handoff">handoff</InlineCode>, "Continue this conversation in a fresh agent session, such as “hand this off to Codex”."],
            [<InlineCode key="dispatch">dispatch</InlineCode>, "Run a new task in a separate agent, in its own workspace and branch, on this machine or a paired device."],
            [<InlineCode key="standup">standup</InlineCode>, "See what your agents are doing and which are working, blocked, or done. Read-only."],
            [<InlineCode key="unblock">unblock</InlineCode>, "Get blocked agents moving: routine prompts are answered, and real questions come back to you word for word."],
          ]}
        />
        <Prose>
          A workflow never approves agent hooks or other trust prompts for you, and it starts an agent
          once and confirms it picked up its work before reporting success.
        </Prose>
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
