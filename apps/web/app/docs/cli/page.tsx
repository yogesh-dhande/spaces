import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";

export const metadata: Metadata = {
  title: "CLI Reference",
  description:
    "Complete reference for the mx command-line interface. Intended for both human developers and AI agents creating and managing Muxy workspaces.",
};

function CodeBlock({ children }: { children: string }) {
  return (
    <pre className="mt-3 overflow-x-auto rounded-xl border border-line bg-[#0f1820] px-4 py-3 font-mono text-xs leading-6 text-[#98efc7]">
      <code>{children}</code>
    </pre>
  );
}

function Cmd({ children }: { children: React.ReactNode }) {
  return (
    <code className="rounded bg-surface px-1.5 py-0.5 font-mono text-xs text-accent">
      {children}
    </code>
  );
}

function Flag({ name, description }: { name: string; description: string }) {
  return (
    <li className="flex flex-col gap-0.5 sm:flex-row sm:gap-3">
      <span className="w-56 shrink-0 font-mono text-xs text-accent">{name}</span>
      <span className="text-sm leading-6 text-foreground-soft">{description}</span>
    </li>
  );
}

export default function CliReferencePage() {
  return (
    <DocsShell
      title="CLI Reference"
      description="The mx command-line interface is the primary way AI agents and human developers create, launch, and manage Muxy workspaces from scripts, terminals, and automated pipelines."
      pagePath="/docs/cli"
    >
      {/* Agent-oriented overview */}
      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Using mx from AI Agents</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          <Cmd>mx</Cmd> is designed to be called by AI coding agents. When working on multiple
          features or bug fixes in parallel, each task should run in its own Muxy workspace. This
          keeps terminal sessions, browser tabs, reserved ports, and editor windows fully isolated
          so the developer can switch context instantly without losing state.
        </p>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          A complete agent workflow — from a bare directory to a running workspace — looks like this:
        </p>
        <ol className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>1. Add the project (<Cmd>mx project add</Cmd>).</li>
          <li>2. Configure ports, processes, status checks, browser sessions, and scripts via <Cmd>mx project port|process|status-check|browser-session</Cmd> and <Cmd>mx project update</Cmd>.</li>
          <li>3. Create a workspace for the branch or task (<Cmd>mx workspace create</Cmd>).</li>
          <li>4. Launch the workspace — ports are reserved, processes start, browser sessions open (<Cmd>mx workspace launch</Cmd>).</li>
          <li>5. Do the work. Switch context, run more workspaces in parallel.</li>
          <li>6. Archive the workspace when the task is done (<Cmd>mx workspace archive</Cmd>).</li>
        </ol>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          All commands print machine-readable output (tab-separated fields, no ANSI colour) and exit
          with a non-zero code on failure, making them safe to use in scripts and pipelines.
        </p>
      </article>

      {/* Installation */}
      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Finding the CLI</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          The <Cmd>mx</Cmd> binary ships inside the Muxy.app bundle. Muxy symlinks it to{" "}
          <Cmd>/usr/local/bin/mx</Cmd> when you first launch the app so it is available on{" "}
          <Cmd>$PATH</Cmd> immediately.
        </p>
        <CodeBlock>{`# Verify installation
mx version
`}</CodeBlock>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          If the command is not found, open Muxy.app once — it will install the symlink.
        </p>
      </article>

      {/* Project commands */}
      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Project Commands</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Projects are codebases registered with Muxy. Register a project once, then create as many
          workspaces as you need from it.
        </p>

        <h3 className="mt-5 text-base font-semibold">List projects</h3>
        <CodeBlock>{`mx project list`}</CodeBlock>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Prints one project per line: <Cmd>name</Cmd>, <Cmd>dir</Cmd>, <Cmd>git=yes|no</Cmd>,{" "}
          <Cmd>default_branch=&lt;branch|-&gt;</Cmd>.
        </p>

        <h3 className="mt-5 text-base font-semibold">Add a project</h3>
        <CodeBlock>{`# Register an existing local directory
mx project add --dir /path/to/repo

# Clone a remote git repo into ~/muxy/projects/ and register it
mx project add --git-url https://github.com/owner/repo.git`}</CodeBlock>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Muxy detects whether the directory is a Git repo and creates a non-archivable default
          workspace. For Git repos, each workspace gets its own worktree directory so parallel
          branches never share a working tree.
        </p>

        <h3 className="mt-5 text-base font-semibold">Set setup and stop scripts</h3>
        <CodeBlock>{`mx project update --dir /path/to/repo \\
  --setup-script "cp /shared/.env .env && npm install" \\
  --stop-script "docker compose down --remove-orphans"`}</CodeBlock>
        <ul className="mt-2 space-y-1">
          <Flag name="--setup-script <cmd>" description="Runs once when a workspace is created or revived from archive. Named port env vars are available." />
          <Flag name="--stop-script <cmd>" description="Runs after processes terminate on stop, restart, or archive." />
        </ul>

        <h3 className="mt-5 text-base font-semibold">Remove a project</h3>
        <CodeBlock>{`mx project remove --dir /path/to/repo`}</CodeBlock>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Removes Muxy state, force-removes git worktrees, and deletes workspace directories under{" "}
          <Cmd>~/muxy/workspaces</Cmd>. If the project was cloned via{" "}
          <Cmd>--git-url</Cmd>, its clone under <Cmd>~/muxy/projects</Cmd> is also deleted.
        </p>
      </article>

      {/* Ports */}
      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Port Commands</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Named ports are environment variables backed by real port numbers. Muxy allocates a unique
          port number from the configured range for each workspace, so two workspaces running at the
          same time never collide on the same local port. The allocated port is reserved via an OS
          socket for the lifetime of the workspace and injected as an env var into setup scripts,
          stop scripts, process commands, and status check commands.
        </p>
        <CodeBlock>{`mx project port list   --dir /path/to/repo
mx project port add    --dir /path/to/repo --name FRONTEND_PORT
mx project port add    --dir /path/to/repo --name API_PORT
mx project port remove --dir /path/to/repo --name API_PORT`}</CodeBlock>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Port names become env vars: <Cmd>$FRONTEND_PORT</Cmd>, <Cmd>$API_PORT</Cmd>, etc. Names
          must be valid shell identifier strings (uppercase by convention).
        </p>
      </article>

      {/* Processes */}
      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Process Commands</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Processes are shell commands started in iTerm2 when a workspace launches. Named port env
          vars and <Cmd>MUXY_WORKSPACE_DIR</Cmd> / <Cmd>MUXY_PROJECT_DIR</Cmd> are injected
          automatically.
        </p>
        <CodeBlock>{`mx project process list   --dir /path/to/repo
mx project process add    --dir /path/to/repo --name frontend --command "PORT=$FRONTEND_PORT npm run dev"
mx project process add    --dir /path/to/repo --name api      --command "PORT=$API_PORT npm run api"
mx project process remove --dir /path/to/repo --name api`}</CodeBlock>
        <ul className="mt-3 space-y-1">
          <Flag name="--name <name>" description="Process identifier. Used to associate status checks and for display in the run tab." />
          <Flag name="--command <cmd>" description="Shell command to execute. Named port env vars are available." />
        </ul>
      </article>

      {/* Status checks */}
      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Status Check Commands</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Status checks run a shell command on a schedule while the workspace is running and surface
          green / red health in the Muxy run tab, nested under the associated process.
        </p>
        <CodeBlock>{`mx project status-check list   --dir /path/to/repo
mx project status-check add    --dir /path/to/repo \\
  --name web-health \\
  --process frontend \\
  --command "curl -fsS http://localhost:$FRONTEND_PORT/health" \\
  --interval 10 \\
  --timeout 2 \\
  --on-exit notify
mx project status-check remove --dir /path/to/repo --name web-health`}</CodeBlock>
        <ul className="mt-3 space-y-1">
          <Flag name="--name <name>" description="Check identifier. Required for remove." />
          <Flag name="--process <name>" description="Name of the process this check is associated with." />
          <Flag name="--command <cmd>" description="Shell command to run. Exit 0 = healthy, non-zero = unhealthy." />
          <Flag name="--interval <seconds>" description="Seconds between runs. Default: 60." />
          <Flag name="--timeout <seconds>" description="Seconds before the command is killed. Default: 5." />
          <Flag name="--on-exit <action>" description="Action when the process exits: none | restart | notify. Default: none." />
        </ul>
      </article>

      {/* Browser sessions */}
      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Browser Session Commands</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Browser sessions are URLs opened in Google Chrome when the workspace launches. Muxy tracks
          the tabs and reuses or reopens them on subsequent launches so the same pages come back
          without manual navigation. Named port env vars are resolved at launch time.
        </p>
        <CodeBlock>{`mx project browser-session list   --dir /path/to/repo
mx project browser-session add    --dir /path/to/repo --url "http://localhost:$FRONTEND_PORT"
mx project browser-session add    --dir /path/to/repo --url "http://localhost:$API_PORT/docs"
mx project browser-session remove --dir /path/to/repo --url "http://localhost:$API_PORT/docs"`}</CodeBlock>
      </article>

      {/* Workspace commands */}
      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Workspace Commands</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          A workspace is an isolated stream of work. For Git projects each workspace corresponds to
          a branch and a git worktree directory. Multiple workspaces can run at the same time.
        </p>

        <h3 className="mt-5 text-base font-semibold">List workspaces</h3>
        <CodeBlock>{`# List non-archived workspaces
mx workspace list --project-dir /path/to/repo

# Include archived workspaces
mx workspace list --project-dir /path/to/repo --all`}</CodeBlock>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Output columns: name, dir, flags (<Cmd>default</Cmd>, <Cmd>running</Cmd>,{" "}
          <Cmd>archived</Cmd>).
        </p>

        <h3 className="mt-5 text-base font-semibold">Create a workspace</h3>
        <CodeBlock>{`# Git project — create workspace on a new branch
mx workspace create \\
  --project-dir /path/to/repo \\
  --name "feat-auth" \\
  --branch feat/auth \\
  --target-branch main

# Git project — override worktree directory name
mx workspace create \\
  --project-dir /path/to/repo \\
  --name "fix-login-crash" \\
  --branch fix/login-crash \\
  --dirname fix_login_crash

# Non-git project
mx workspace create \\
  --project-dir /path/to/project \\
  --name "experiment-1"`}</CodeBlock>
        <ul className="mt-2 space-y-1">
          <Flag name="--name <name>" description="Workspace display name used in the UI and in other commands." />
          <Flag name="--branch <branch>" description="Git branch name. Created from --target-branch if it does not exist. Required for git projects." />
          <Flag name="--target-branch <branch>" description="Base branch for the new branch. Defaults to main or master." />
          <Flag name="--dirname <name>" description="Override the git worktree directory name. Letters, numbers, - and _ only." />
          <Flag name="--tooltip <text>" description="Optional context about what you're working on. Display with cmd+shift+i global hotkey." />
        </ul>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          On creation, the workspace snapshots port definitions, processes, status checks, and browser
          sessions from the project config. Port numbers are allocated and the{" "}
          <Cmd>setup_script</Cmd> runs with those port env vars already set.
        </p>

        <h3 className="mt-5 text-base font-semibold">Import existing worktree</h3>
        <CodeBlock>{`# Import workspace from current directory (infers name from branch)
mx workspace import

# Import workspace from specific worktree path
mx workspace import --dir /path/to/worktree

# Import workspace with custom name
mx workspace import --dir /path/to/worktree --name "my-workspace"`}</CodeBlock>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Registers an existing git worktree as a Muxy workspace. The project must already be
          registered. Muxy infers the workspace name from the branch name if not provided.
          Port numbers are allocated and the <Cmd>setup_script</Cmd> runs immediately.
        </p>

        <h3 className="mt-5 text-base font-semibold">Discover and auto-create workspaces</h3>
        <CodeBlock>{`# Discover all worktrees across all registered projects
mx workspace discover

# Discover worktrees for a specific project only
mx workspace discover --project-dir /path/to/repo`}</CodeBlock>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Automatically discovers all git worktrees for registered projects and creates Muxy
          workspaces for any that aren't already tracked. Useful for bulk-importing existing
          worktrees or syncing after manual git worktree operations.
        </p>

        <h3 className="mt-5 text-base font-semibold">Launch a workspace</h3>
        <CodeBlock>{`# Launch from current directory
mx workspace launch

# Launch from specific workspace directory
mx workspace launch --dir /path/to/workspace`}</CodeBlock>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Starts configured processes in iTerm2, opens browser sessions in Chrome, and opens the
          preferred editor. Only valid for stopped workspaces. When run without arguments, uses
          the current directory to identify the workspace.
        </p>

        <h3 className="mt-5 text-base font-semibold">Stop a workspace</h3>
        <CodeBlock>{`# Stop from current directory
mx workspace stop

# Stop specific workspace
mx workspace stop --dir /path/to/workspace`}</CodeBlock>

        <h3 className="mt-5 text-base font-semibold">Restart a workspace</h3>
        <CodeBlock>{`# Restart from current directory
mx workspace restart

# Restart specific workspace
mx workspace restart --dir /path/to/workspace`}</CodeBlock>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Stops then immediately launches. Useful after a dependency install or config change.
        </p>

        <h3 className="mt-5 text-base font-semibold">Archive a workspace</h3>
        <CodeBlock>{`# Archive from current directory
mx workspace archive

# Archive specific workspace
mx workspace archive --dir /path/to/workspace`}</CodeBlock>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Stops the workspace, releases reserved ports, and marks it archived. Use{" "}
          <Cmd>--all</Cmd> on <Cmd>workspace list</Cmd> to see archived workspaces.
        </p>

        <h3 className="mt-5 text-base font-semibold">Activate a workspace</h3>
        <CodeBlock>{`# Activate from current directory
mx workspace activate

# Activate specific workspace
mx workspace activate --dir /path/to/workspace`}</CodeBlock>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Brings the workspace windows to the front so the developer can immediately resume work.
        </p>

        <h3 className="mt-5 text-base font-semibold">Manage workspace tooltip</h3>
        <CodeBlock>{`# View current tooltip
mx workspace tooltip --dir /path/to/workspace

# Set or update tooltip
mx workspace tooltip --dir /path/to/workspace --tooltip "Working on OAuth integration"

# Clear tooltip
mx workspace tooltip --dir /path/to/workspace --clear`}</CodeBlock>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Tooltips provide context about what you're working on. Press <Cmd>cmd+shift+i</Cmd> when
          any workspace window is focused to display the tooltip as an overlay on the current screen.
          Press the hotkey again to hide it.
        </p>
      </article>

      {/* Settings commands */}
      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Settings Commands</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          GUI keyboard shortcuts can be read, overridden, or reset from the CLI. Hotkey specs use
          the format <Cmd>cmd+shift+x</Cmd>.
        </p>
        <CodeBlock>{`# Read
mx settings get --gui-hotkey
mx settings get --gui-next-shortcut
mx settings get --gui-prev-shortcut
mx settings get --gui-show-shortcut

# Set
mx settings set --gui-hotkey cmd+shift+m
mx settings set --gui-next-shortcut ctrl+tab
mx settings set --gui-prev-shortcut ctrl+shift+tab

# Reset to default
mx settings reset --gui-hotkey
mx settings reset --gui-next-shortcut`}</CodeBlock>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Additional keys: <Cmd>--gui-add-project-shortcut</Cmd>,{" "}
          <Cmd>--gui-add-workspace-shortcut</Cmd>, <Cmd>--gui-reload-shortcut</Cmd>,{" "}
          <Cmd>--gui-open-editor-shortcut</Cmd>, <Cmd>--gui-open-terminal-shortcut</Cmd>,{" "}
          <Cmd>--gui-open-finder-shortcut</Cmd>, <Cmd>--gui-open-settings-shortcut</Cmd>.
        </p>
      </article>

      {/* AI agent recipe */}
      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">AI Agent Recipe</h2>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          A complete example: register a project, configure it, create a workspace, and launch it.
        </p>
        <CodeBlock>{`#!/usr/bin/env bash
# Full project setup and workspace launch for an AI agent.
# Usage: ./start.sh /path/to/repo feat/my-feature
set -euo pipefail

REPO="$1"
BRANCH="$2"
NAME="\${BRANCH##*/}"

# 1. Register the project
mx project add --dir "$REPO"

# 2. Set lifecycle scripts
mx project update --dir "$REPO" \\
  --setup-script "npm install" \\
  --stop-script "pkill -f node || true"

# 3. Define named ports (allocated per workspace so parallel runs never collide)
mx project port add --dir "$REPO" --name FRONTEND_PORT
mx project port add --dir "$REPO" --name API_PORT

# 4. Add processes (started in iTerm2 on launch)
mx project process add --dir "$REPO" --name frontend --command "PORT=\$FRONTEND_PORT npm run dev"
mx project process add --dir "$REPO" --name api      --command "PORT=\$API_PORT npm run api"

# 5. Add status checks (health polling while workspace runs)
mx project status-check add --dir "$REPO" \\
  --name web-health --process frontend \\
  --command "curl -fsS http://localhost:\$FRONTEND_PORT/health" \\
  --interval 10 --timeout 2 --on-exit notify

# 6. Add browser sessions (opened in Chrome on launch)
mx project browser-session add --dir "$REPO" --url "http://localhost:\$FRONTEND_PORT"

# 7. Create the workspace (snapshots config, allocates ports, runs setup_script)
mx workspace create \\
  --project-dir "$REPO" \\
  --name "$NAME" \\
  --branch "$BRANCH" \\
  --target-branch main

# 8. Launch (starts processes, opens browser sessions)
# Navigate to workspace directory and launch
WORKSPACE_DIR="$HOME/muxy/workspaces/\${NAME}"
cd "$WORKSPACE_DIR"
mx workspace launch

echo "Workspace '$NAME' is running."
`}</CodeBlock>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Tear down when done:
        </p>
        <CodeBlock>{`cd "$WORKSPACE_DIR"
mx workspace archive`}</CodeBlock>
      </article>

      {/* Exit codes */}
      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Exit Codes</h2>
        <div className="mt-4 overflow-x-auto">
          <table className="w-full border-collapse text-sm">
            <thead>
              <tr className="border-b border-line">
                <th className="pb-2 pr-8 text-left font-mono text-xs uppercase tracking-[0.12em] text-foreground-soft">Code</th>
                <th className="pb-2 text-left font-mono text-xs uppercase tracking-[0.12em] text-foreground-soft">Meaning</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-line">
              {[
                ["0", "Command completed successfully."],
                ["1", "Command failed. A human-readable error message is printed to stderr."],
              ].map(([code, meaning]) => (
                <tr key={code}>
                  <td className="py-2 pr-8 font-mono text-xs text-accent">{code}</td>
                  <td className="py-2 text-sm leading-6 text-foreground-fossil">{meaning}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </article>
    </DocsShell>
  );
}
