// Content data for the homepage (app/page.tsx): copy strings, feature lists,
// and section data arrays. Kept separate from the page component so
// page.tsx holds rendering logic only, mirroring app/docs/content.ts.
import Link from "next/link";

export const githubReleasesURL = "https://github.com/yogesh-dhande/spaces/releases/latest";

// Sample devices in the hero visual, grouped like the Mac sidebar: machine, then
// workspace, then the agents running in it. They mirror the Mac screenshot beside them.
// waiting = needs the user (amber), working = teal, done = muted.
export type HeroAgent = {
  agent: string;
  status: "waiting" | "working" | "done";
  statusLabel: string;
  elapsed?: string;
};

export type HeroWorkspace = {
  name: string;
  agents: HeroAgent[];
};

export type HeroDevice = {
  name: string;
  kind: string;
  workspaces: HeroWorkspace[];
};

export const heroDevices: HeroDevice[] = [
  {
    name: "Local",
    kind: "Mac",
    workspaces: [
      {
        name: "harbor-web / checkout-copy",
        agents: [{ agent: "claude", status: "waiting", statusLabel: "waiting on you" }],
      },
    ],
  },
  {
    name: "build-server",
    kind: "Linux server",
    workspaces: [
      {
        name: "atlas-api / retry-backoff",
        agents: [{ agent: "codex", status: "working", statusLabel: "working" }],
      },
      {
        name: "atlas-api / rate-limit-tests",
        agents: [{ agent: "opencode", status: "done", statusLabel: "done" }],
      },
    ],
  },
];

export type Feature = {
  title: string;
  description: React.ReactNode;
};

export const keyFeatures: Feature[] = [
  {
    title: "A worktree per branch",
    description:
      "Every workspace in a Git project is a git worktree on its own branch, sharing the project's one clone, so parallel feature work never collides. Every device also has a home workspace, `~`, for terminals that belong to no project.",
  },
  {
    title: "Organize work into logical workspaces",
    description:
      "Every feature, branch, or experiment becomes a workspace with its own terminals, tabs, editors, and agents. Switch between them instantly.",
  },
  {
    title: "Stable per-workspace URLs",
    description:
      "Declare named services and reach each one at a stable, predictable URL like http://web.my-branch.localhost:7391, served by a bundled reverse proxy. Run three instances of your app side by side, isolated, no port conflicts, no `.env` edits.",
  },
  {
    title: "Jump to any workspace",
    description:
      "A global command palette pulls up any window instantly: choose a window and it snaps into focus right where you left it.",
  },
  {
    title: "Cycle through what matters",
    description:
      "Step through one workspace's windows, your alerts, every agent, or every open session with one pair of shortcuts, and switch what you cycle through with another.",
  },
  {
    title: "Agent briefs",
    description:
      "A coding agent can keep a short brief beside its terminal: what it is doing, questions for you, and its task list. Read it on your Mac or iPhone without scrolling back through the transcript.",
  },
  {
    title: "Launch and teardown on demand",
    description:
      "Stop a workspace and Spaces shuts down its processes and closes its terminals and browser tabs. Start it again and its configured processes come back; browser sessions reopen when you focus them.",
  },
  {
    title: "Native macOS app, not Electron",
    description:
      "Built with Swift and AppKit, not Electron, so the interface stays fast and out of your way.",
  },
  {
    title: "Terminals built on libghostty",
    description: (
      <>
        Terminal sessions are powered by{" "}
        <a
          href="https://github.com/ghostty-org/ghostty"
          className="text-accent hover:underline"
          target="_blank"
          rel="noreferrer"
        >
          libghostty
        </a>
        , the engine behind the Ghostty terminal: fast, GPU-accelerated
        rendering that keeps up with the heaviest output.
      </>
    ),
  },
];

export type FaqItem = {
  question: string;
  answer: React.ReactNode;
};

export const faqItems: FaqItem[] = [
  {
    question: "How much does it cost?",
    answer: (
      <>
        Spaces is free on Mac and Linux. The iPhone app is in an invite-only
        TestFlight beta.
      </>
    ),
  },
  {
    question: "What are the system requirements?",
    answer: (
      <ul className="ml-4 list-disc space-y-1">
        <li>macOS 14 Sonoma or later</li>
        <li>Google Chrome, used for browser sessions</li>
        <li>Ubuntu 24.04 for a Linux server</li>
        <li>iOS 17 or later for the iPhone beta</li>
      </ul>
    ),
  },
  {
    question: "How does Spaces know what each agent is doing?",
    answer: (
      <>
        Spaces installs status hooks for Claude Code, Codex, and opencode, so
        the sidebar shows whether each agent is working, waiting on you, or
        done. An agent you start in a Spaces terminal is also recognized
        without hooks. Each agent can also keep a brief, a short status page
        shown beside its terminal. See{" "}
        <Link href="/docs/coding-agents" className="text-accent hover:underline">
          Agent status
        </Link>{" "}
        and the{" "}
        <Link href="/docs/guides" className="text-accent hover:underline">
          recipes
        </Link>
        .
      </>
    ),
  },
  {
    question: "Can I run agents on another Mac or a Linux server?",
    answer: (
      <>
        Yes. Pair another Mac or a Linux server (Ubuntu 24.04) over SSH. Each machine runs the Spaces service and shows up as
        its own section in the sidebar, so you manage its projects,
        workspaces, terminals, and agents from the Mac in front of you.
        Sessions run on that service, so a remote build or agent keeps
        running after you disconnect or close your laptop. Reattach later
        from your Mac or your phone. See{" "}
        <Link href="/docs/remote-access#pairing" className="text-accent hover:underline">
          Remote machines
        </Link>{" "}
        for pairing.
      </>
    ),
  },
  {
    question: "I only work on one project at a time. Will Spaces help me?",
    answer: (
      <>
        Yes. Alerts, automations, remote machines, and the iPhone app all work
        with one workspace; extra workspaces only matter once you run a second
        branch.
      </>
    ),
  },
  {
    question: "Is there a mobile app?",
    answer: (
      <>
        Yes, in an invite-only TestFlight beta.{" "}
        <a
          href="https://github.com/yogesh-dhande/spaces/issues"
          className="text-accent hover:underline"
        >
          Ask for an invite on GitHub
        </a>
        . It pairs with your Mac or a Linux server from a QR code and talks to
        that machine directly. See the{" "}
        <Link href="/docs/ios" className="text-accent hover:underline">
          iOS app docs
        </Link>
        .
      </>
    ),
  },
  {
    question: "Do you collect any data?",
    answer: (
      <>
        No. Spaces runs entirely on your devices and does not send your data to Spaces
        or any third party. Pairing connects only to your own devices: your
        iPhone or another machine you control.
      </>
    ),
  },
  {
    question: "Where do I send bug reports?",
    answer: (
      <>
        Open an issue at{" "}
        <a
          href="https://github.com/yogesh-dhande/spaces/issues"
          className="text-accent hover:underline"
        >
          github.com/yogesh-dhande/spaces/issues
        </a>
        .
      </>
    ),
  },
];

export type WorkflowStepData = {
  n: string;
  label: string;
  body: string;
};

export const workflow: WorkflowStepData[] = [
  {
    n: "01",
    label: "Project",
    body: "Point Spaces at a repo on your Mac or a remote machine. Define your setup script, named services, browser URLs, and the processes you run. Do this once.",
  },
  {
    n: "02",
    label: "Workspace",
    body: "Create a workspace for each feature, branch, or experiment. Each one gets its own directory, services, stable per-workspace URLs, env, and processes, isolated from the rest. Create as many as you need.",
  },
  {
    n: "03",
    label: "Run",
    body: "Start the workspace and every configured process comes up. Browser sessions open when you focus them. Stop it and everything shuts down together.",
  },
];

export const remoteNodes: string[] = ["This Mac", "Another Mac", "Linux server"];

// A row in the Alerts panel mock. Only blocked and done states raise Alerts,
// so every sample row is one of those two.
export type AgentAlert = {
  workspace: string;
  agent: string;
  status: "blocked" | "done";
};

export const agentAlerts: AgentAlert[] = [
  {
    workspace: "auth-refactor",
    agent: "claude",
    status: "blocked",
  },
  {
    workspace: "billing-webhooks",
    agent: "codex",
    status: "done",
  },
  {
    workspace: "search-reindex",
    agent: "opencode",
    status: "blocked",
  },
  {
    workspace: "landing-copy",
    agent: "codex",
    status: "done",
  },
];

export type ComparisonItem = {
  title: string;
  body: string;
};

// Left column: what plain localhost does when you run several checkouts of
// the same app at once. Right column: how named services and the bundled
// reverse proxy remove both problems.
export const localhostPains: ComparisonItem[] = [
  {
    title: "Port conflicts",
    body: "Every checkout of the same app wants port 3000. You end up hand-assigning ports per branch, editing .env files, and restarting servers just to run two at once.",
  },
  {
    title: "Shared cookie sessions",
    body: "Cookies aren't scoped by port, so localhost:3000 and localhost:3001 can share cookie-based sessions. Log in on one, and the other can pick up the same session.",
  },
];

export const spacesFixes: ComparisonItem[] = [
  {
    title: "One hostname per workspace",
    body: "Declare a named service once and every workspace reaches it at a stable URL like web.my-branch.localhost:7391, routed by a bundled reverse proxy, no manual port assignment, ever.",
  },
  {
    title: "Isolated sessions by design",
    body: "Different hostnames mean different cookie jars and local storage. Stay logged into three branches at once, side by side, with no incognito tabs.",
  },
];

export type AutomationPoint = {
  title: string;
  description: string;
};

export const automationPoints: AutomationPoint[] = [
  {
    title: "Agents or scripts",
    description: "Give an agent a standing task, like a nightly dependency check, or run a shell script at the workspace root.",
  },
  {
    title: "Runs you can replay",
    description: "Watch a run live, or replay its terminal later. A finished agent's session stays open for you to review.",
  },
  {
    title: "Overlaps and missed runs",
    description:
      "Decide whether a run that fires while the last one is still going is skipped, queued, or started anyway, and whether runs missed while the machine was off catch up.",
  },
  {
    title: "From your iPhone",
    description: "Run one now, cancel a run, open its terminal, or pick the time of its next run from the iPhone app.",
  },
];

// A row in the Automations list mock. running = teal, done = muted, skipped = amber.
export type AutomationRow = {
  name: string;
  kind: string;
  device: string;
  schedule: string;
  status: "running" | "done" | "skipped";
  statusLabel: string;
  elapsed?: string;
  note?: string;
};

export const automationRows: AutomationRow[] = [
  {
    name: "Nightly dependency check",
    kind: "claude",
    device: "Local",
    schedule: "daily at 03:00",
    status: "done",
    statusLabel: "done",
    elapsed: "6h ago",
  },
  {
    name: "Triage new issues",
    kind: "codex",
    device: "Remote VM",
    schedule: "every hour",
    status: "running",
    statusLabel: "running",
  },
  {
    name: "Rebuild docs site",
    kind: "script",
    device: "Remote VM",
    schedule: "on demand",
    status: "done",
    statusLabel: "done",
    elapsed: "2d ago",
  },
  {
    name: "Weekly cleanup",
    kind: "opencode",
    device: "Local",
    schedule: "Mondays at 09:00",
    status: "skipped",
    statusLabel: "skipped",
    note: "previous run still open",
  },
];
