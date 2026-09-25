// Content data for the homepage (app/page.tsx): copy strings, feature lists,
// and section data arrays. Kept separate from the page component so
// page.tsx holds rendering logic only, mirroring app/docs/content.ts.
import Link from "next/link";
import { Key } from "./components/key";

export const githubReleasesURL = "https://github.com/yogesh-dhande/spaces/releases/latest";

// Scope strip under the hero headline: the surfaces Spaces puts under one roof.
export const heroScope = [
  "projects",
  "worktrees",
  "agents",
  "ports",
  "processes",
  "windows",
  "remote machines",
];

export type Pillar = {
  title: string;
  description: string;
  icon: React.ReactNode;
  href?: string;
  hrefLabel?: string;
};

// The six things Spaces manages for you, the centerpiece of the page.
export const pillars: Pillar[] = [
  {
    title: "Agents",
    description:
      "Claude Code, Codex, and opencode each report working, blocked, or done. Alerts shows which one needs you next; jump to its terminal with a shortcut.",
    icon: (
      <svg viewBox="0 0 20 20" fill="none" aria-hidden className="h-5 w-5">
        <path
          d="M2 10h3.5l2-5.5L11 15l2-5h3"
          stroke="currentColor"
          strokeWidth="1.5"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </svg>
    ),
  },
  {
    title: "Worktrees",
    description:
      "Every feature, branch, or experiment gets its own git worktree on its own branch, with its own directory, env, ports, and processes. Parallel work never collides.",
    icon: (
      <svg viewBox="0 0 20 20" fill="none" aria-hidden className="h-5 w-5">
        <circle cx="5" cy="4.5" r="2" stroke="currentColor" strokeWidth="1.5" />
        <circle cx="5" cy="15.5" r="2" stroke="currentColor" strokeWidth="1.5" />
        <circle cx="15" cy="7.5" r="2" stroke="currentColor" strokeWidth="1.5" />
        <path
          d="M5 6.5v7M5 11h5a3 3 0 0 0 3-3V9.5"
          stroke="currentColor"
          strokeWidth="1.5"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </svg>
    ),
  },
  {
    title: "Ports & processes",
    description:
      "Name your services and each workspace gets its own port and a stable URL like web.my-branch.localhost:7391. Dev servers and workers run as tracked processes that restart on demand.",
    icon: (
      <svg viewBox="0 0 20 20" fill="none" aria-hidden className="h-5 w-5">
        <rect x="5" y="5" width="10" height="10" rx="1.5" stroke="currentColor" strokeWidth="1.5" />
        <rect x="8" y="8" width="4" height="4" rx="0.5" stroke="currentColor" strokeWidth="1.5" />
        <path
          d="M8.5 2.5V5M11.5 2.5V5M8.5 15v2.5M11.5 15v2.5M2.5 8.5H5M2.5 11.5H5M15 8.5h2.5M15 11.5h2.5"
          stroke="currentColor"
          strokeWidth="1.5"
          strokeLinecap="round"
        />
      </svg>
    ),
  },
  {
    title: "Windows & focus",
    description:
      "Spaces tracks every window a workspace opens and jumps you back with a keystroke. Cycle through one workspace, your alerts, or your agents, and keep your attention on one task at a time.",
    icon: (
      <svg viewBox="0 0 20 20" fill="none" aria-hidden className="h-5 w-5">
        <rect x="2.5" y="4" width="10" height="8" rx="1.2" stroke="currentColor" strokeWidth="1.5" />
        <rect x="7.5" y="8" width="10" height="8" rx="1.2" stroke="currentColor" strokeWidth="1.5" />
      </svg>
    ),
  },
  {
    title: "Remote machines",
    description:
      "Pair a remote Mac or a cloud Linux box and drive them all from one Mac. Each device gets its own sidebar section, with its projects and sessions in reach.",
    href: "#remote",
    hrefLabel: "See how it works",
    icon: (
      <svg viewBox="0 0 20 20" fill="none" aria-hidden className="h-5 w-5">
        <rect x="3" y="3.5" width="14" height="5" rx="1.2" stroke="currentColor" strokeWidth="1.5" />
        <rect x="3" y="11.5" width="14" height="5" rx="1.2" stroke="currentColor" strokeWidth="1.5" />
        <path d="M6 6h.01M6 14h.01" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
      </svg>
    ),
  },
  {
    title: "Mac & iPhone",
    description:
      "Two full clients, not an app and an accessory. Each one pairs straight to the machines it drives: your iPhone talks directly to a Mac or a cloud Linux box, with nothing in the middle to leave running.",
    href: "#mobile",
    hrefLabel: "See both clients",
    icon: (
      <svg viewBox="0 0 20 20" fill="none" aria-hidden className="h-5 w-5">
        <rect x="1.5" y="4" width="11" height="8" rx="1.2" stroke="currentColor" strokeWidth="1.5" />
        <path d="M4.5 15h5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
        <path d="M7 12v3" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
        <rect x="13.5" y="8" width="5" height="9.5" rx="1.2" stroke="currentColor" strokeWidth="1.5" />
        <path d="M15.6 15.6h1.3" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
      </svg>
    ),
  },
];

export type Feature = {
  title: string;
  description: React.ReactNode;
};

export const keyFeatures: Feature[] = [
  {
    title: "Track agents across workspaces",
    description:
      "Every coding agent reports its state (working, waiting on you, or done) in one Alerts view. See at a glance which ones need input next, and jump to any of them with a keyboard shortcut.",
  },
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
    title: "Run on remote machines",
    description:
      "Pair a remote Mac or a cloud Linux box over SSH. Manage its projects, workspaces, terminals, and agents from the Mac in front of you, each device in its own sidebar section.",
  },
  {
    title: "Sessions that outlive your laptop",
    description:
      "Terminals and agents run on the Spaces service on that machine, not your SSH connection. Kick off a build on a remote box, close your laptop, and it keeps running. Reattach later exactly where it left off.",
  },
  {
    title: "Automations",
    description:
      "Run a shell command on your Mac or a paired device manually or on a schedule, even while Spaces is closed. Watch a run live, replay it later, or have it spawn a coding agent that keeps working after the run finishes.",
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
    title: "Take any session to your iPhone",
    description:
      "The iOS app is a full client, not a remote for your Mac. It pairs directly with any device running Spaces (your Mac, or a cloud Linux box with no Mac involved), so you can pick up the same live session, watch a build, check a coding agent, or send a command, then step back to your desk without losing your place.",
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
      </ul>
    ),
  },
  {
    question: "Can I use it with CLI coding agents like Claude Code, Codex, or opencode?",
    answer: (
      <>
        Yes. Open a terminal in any workspace with <Key>⌘⌥T</Key> and start
        your agent as usual. It opens as a pane in that workspace, so you can
        jump back to it with a keystroke. Spaces installs status hooks for
        Claude Code, Codex, and opencode, so the sidebar shows whether each
        agent is working, waiting for you, or done. Each agent can also keep
        a brief, a short status page shown beside its terminal. See{" "}
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
    question: "Can I use it with a Mac Mini or cloud VM?",
    answer: (
      <>
        Yes. Pair another Mac or an Ubuntu box, including a cloud
        VM, over SSH. Each machine runs the Spaces service and shows up as
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
        You will still benefit from the ability to manage agents, processes, and windows, and to control
        them from your Mac or iPhone.
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
        . The Spaces iOS app is a full client in its own right, not a
        remote for the desktop app. Your Mac&apos;s Devices settings shows a
        pairing QR code for any machine it&apos;s connected to (itself, or a
        Linux box) and scanning one pairs your phone with that machine
        directly. From then on the phone talks to it on its own: browse its live
        terminal sessions, watch a coding agent&apos;s output, or start new
        sessions, with no Mac in the path. See the{" "}
        <Link href="/docs/ios" className="text-accent hover:underline">
          iOS app
        </Link>{" "}
        docs.
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
    label: "Runtime",
    body: "With one click, start every process for a workspace; its browser sessions open when you focus them. Spaces manages the windows and monitors coding agents. Jump to any window, or cycle through a workspace, your alerts, or your agents, with keyboard shortcuts.",
  },
];

export type RemoteNode = {
  name: string;
};

export const remoteNodes: RemoteNode[] = [
  { name: "Local Mac" },
  { name: "Remote Mac" },
  { name: "Cloud Linux" },
];

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
    agent: "claude-fable",
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
    agent: "claude-sonnet",
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
