/* Hallmark · macrostructure: Workbench · genre: modern-minimal · tone: technical/precise · anchor hue: teal (brand) + amber (status/keys) */
import Link from "next/link";
import { SiteHeader } from "./components/site-header";
import { SiteFooter } from "./components/site-footer";
import { PrimaryButton } from "./components/primary-button";

const githubReleasesURL = "https://github.com/yogesh-dhande/spaces/releases/latest";

// Scope strip under the hero headline — the surfaces Spaces puts under one roof.
const heroScope = [
  "projects",
  "worktrees",
  "agents",
  "ports",
  "processes",
  "windows",
  "remote machines",
];

type Pillar = {
  title: string;
  description: string;
  icon: React.ReactNode;
  href?: string;
  hrefLabel?: string;
};

// The five things Spaces manages for you — the centerpiece of the page.
const pillars: Pillar[] = [
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
      "Every feature, branch, or experiment gets an isolated git worktree — or a separate clone — with its own directory, env, ports, and processes. Parallel work never collides.",
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
      "Spaces tracks every window a workspace opens and jumps you back with a keystroke. Cycle within a workspace, hide the rest, and keep your attention on one task at a time.",
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
      "Pair a remote Mac or a cloud Linux box and drive them all from one Mac — every device in its own sidebar section, projects and sessions in reach.",
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
];

type Feature = {
  title: string;
  description: React.ReactNode;
};

const keyFeatures: Feature[] = [
  {
    title: "Track agents across workspaces",
    description:
      "Every coding agent reports its state — working, waiting on you, or done — in one Alerts view. See at a glance which ones need input next, and jump to any of them with a keyboard shortcut.",
  },
  {
    title: "Manage Git worktrees or separate clones",
    description:
      "Spin up isolated workspaces for every branch using Git worktrees — so parallel feature work never collides. Not a worktrees person? Spaces works with separate clones just as well.",
  },
  {
    title: "Organize work into logical workspaces",
    description:
      "Every feature, branch, or experiment becomes a workspace with its own terminals, tabs, editors, and agents. Switch between them instantly.",
  },
  {
    title: "Stable per-workspace URLs",
    description:
      "Declare named services and reach each one at a stable, predictable URL like http://web.my-branch.localhost:7391, served by a bundled reverse proxy. Run three instances of your app side by side — isolated, no port conflicts, no `.env` edits.",
  },
  {
    title: "Run on remote machines",
    description:
      "Pair a remote Mac or a cloud Linux box over SSH with pinned TLS. Manage its projects, workspaces, terminals, and agents from the Mac in front of you — each device in its own sidebar section.",
  },
  {
    title: "Sessions that outlive your laptop",
    description:
      "Terminals and agents run on the daemon, not your SSH connection. Kick off a build on a remote box, close your laptop, and it keeps running — reattach later exactly where it left off.",
  },
  {
    title: "Jump to any workspace",
    description:
      "A global command palette pulls up any window instantly — choose a window and it snaps into focus right where you left it.",
  },
  {
    title: "Cycle windows within a workspace",
    description:
      "When you are working in a workspace, cycle through windows of only that workspace with keyboard shortcuts so your focus isn't interrupted by other workspaces.",
  },
  {
    title: "Workspace notes",
    description:
      "Coding agents can write context (what's pending, what broke, where they left off) into a per-workspace notes field, surfaced inline in the workspace detail pane.",
  },
  {
    title: "Take any session to your iPhone",
    description:
      "Pair the Spaces iOS app and your terminal sessions come with you. Pick up the same live session on your phone — watch a build, check a coding agent, or send a command — then step back to your Mac without losing your place.",
  },
  {
    title: "Launch and teardown on demand",
    description:
      "Close a workspace and Spaces shuts down its processes and closes its windows. Come back tomorrow, open it, and everything restarts exactly as it was.",
  },
  {
    title: "Native macOS app, not Electron",
    description:
      "Built with Swift and AppKit. The interface stays fast and stays out of your way — no web runtime, no sluggish UI, no fan spinning up just to show you a window list.",
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
        , the engine behind the Ghostty terminal — fast, GPU-accelerated
        rendering that keeps up with the heaviest output.
      </>
    ),
  },
];

type FaqItem = {
  question: string;
  answer: React.ReactNode;
};

const faqItems: FaqItem[] = [
  {
    question: "How much does it cost?",
    answer: <>Spaces is free!</>,
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
        Yes. Open a terminal inside any workspace with <Key>⌘⌥T</Key> and start
        your agent as normal. The terminal window is automatically
        attached to the workspace so you can jump back to it with keyboard
        shortcuts at any time. To let the agent set workspace notes and
        signal its status, add the{" "}
        <Link href="/docs/coding-agents" className="text-accent hover:underline">
          Spaces agent instructions
        </Link>{" "}
        to your project&apos;s AGENTS.md. See the{" "}
        <Link href="/docs/guides" className="text-accent hover:underline">
          cookbook guides
        </Link>{" "}
        for step-by-step setup.
      </>
    ),
  },
  {
    question: "Can I use it with a Mac Mini or cloud VM?",
    answer: (
      <>
        Yes. Pair another Mac or a Ubuntu box — including a cloud
        VM — over SSH with pinned TLS. Each machine runs its own
        daemon and shows up as its own section in the
        sidebar, so you manage its projects, workspaces, terminals, and agents
        from the Mac in front of you. Because sessions run on the daemon, a
        remote build or agent keeps running after you disconnect or close your
        laptop — reattach later from your Mac or your phone. See the{" "}
        <Link href="/docs/cli" className="text-accent hover:underline">
          CLI docs
        </Link>{" "}
        for pairing.
      </>
    ),
  },
  {
    question: "I only work on one project at a time. Will Spaces help me?",
    answer: (
      <>
        You will still benefit from the the ability to manage agents, processes, and windows, and to control
        them from your Mac or iPhone.
      </>
    ),
  },
  {
    question: "Is there a mobile app?",
    answer: (
      <>
        Coming soon! The Spaces iOS app pairs with your Mac by scanning a QR code. From
        your phone you can browse a workspace&apos;s live terminal sessions, watch
        a coding agent&apos;s output, or start new sessions even while
        you&apos;re away from your Mac. See the{" "}
        <Link href="/docs/ios" className="text-accent hover:underline">
          iOS companion
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
        or any third party. Pairing connects only to your own devices — your
        iPhone or another machine you control.
      </>
    ),
  },
  {
    question: "Where do I send bug reports?",
    answer: (
      <>
        Open a GitHub issue at{" "}
        <a href="https://github.com/yogesh-dhande/spaces/issues" className="text-accent hover:underline">
          https://github.com/yogesh-dhande/spaces/issues
        </a>
        .
      </>
    ),
  },
];

type WorkflowStepData = {
  n: string;
  label: string;
  body: string;
};

const workflow: WorkflowStepData[] = [
  {
    n: "01",
    label: "Project",
    body: "Point Spaces at a repo on your mac or a remote machine. Define your setup script, named services, browser URLs, and the processes you run. Do this once.",
  },
  {
    n: "02",
    label: "Workspace",
    body: "Create a workspace for each feature, branch, or experiment. Each one gets its own directory, services, stable per-workspace URLs, env, and processes — isolated from the rest. Create as many as you need.",
  },
  {
    n: "03",
    label: "Runtime",
    body: "With one click, start every process and open the browser URLs for a workspace. Spaces manages the windows and monitors coding agents. Jump to any window — or cycle through the current workspace — with keyboard shortcuts.",
  },
];

type RemoteNode = {
  name: string;
};

const remoteNodes: RemoteNode[] = [
  { name: "Local Mac" },
  { name: "Remote Mac" },
  { name: "Cloud Linux" },
];

// A row in the Alerts panel mock. Only blocked and done states raise Alerts,
// so every sample row is one of those two.
type AgentAlert = {
  workspace: string;
  agent: string;
  status: "blocked" | "done";
};

const agentAlerts: AgentAlert[] = [
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

type ComparisonItem = {
  title: string;
  body: string;
};

// Left column: what plain localhost does when you run several checkouts of
// the same app at once. Right column: how named services + the bundled
// Caddy proxy remove both problems.
const localhostPains: ComparisonItem[] = [
  {
    title: "Port conflicts",
    body: "Every checkout of the same app wants port 3000. You end up hand-assigning ports per branch, editing .env files, and restarting servers just to run two at once.",
  },
  {
    title: "Shared cookie sessions",
    body: "Cookies aren't scoped by port, so localhost:3000 and localhost:3001 can share cookie-based sessions. Log in on one, and the other can pick up the same session.",
  },
];

const spacesFixes: ComparisonItem[] = [
  {
    title: "One hostname per workspace",
    body: "Declare a named service once and every workspace reaches it at a stable URL like web.my-branch.localhost:7391, routed by a bundled Caddy proxy — no manual port assignment, ever.",
  },
  {
    title: "Isolated sessions by design",
    body: "Different hostnames mean different cookie jars and local storage. Stay logged into three branches at once, side by side, with no incognito tabs.",
  },
];

export default function HomePage() {
  return (
    <div className="lp relative min-h-screen overflow-x-clip">
      <SiteHeader />

      {/* ── Hero ── */}
      <section className="relative">
        <div className="mx-auto grid w-full max-w-7xl items-center gap-12 px-6 pt-14 md:pt-20 lg:grid-cols-[minmax(0,0.9fr)_minmax(0,1.1fr)] lg:gap-10">
          {/* Left: copy */}
          <div className="min-w-0">
            <h1 className="mt-5 text-[clamp(2rem,4vw,3.5rem)] font-semibold leading-[1.04] tracking-[-0.01em]">
              Manage <span className="text-accent">parallel coding sessions</span>
            </h1>
            <h2 className="mt-4 flex items-center gap-2 font-mono text-[clamp(1rem,1.6vw,1.2rem)] text-accent-2">
              <span className="font-bold text-accent" aria-hidden>
                ❯
              </span>
              from anywhere, on any machine
              <span className="hero-caret" aria-hidden />
            </h2>

            {/* Scope marquee — infinite left scroll between two hairlines, edges faded. */}
            <div className="marquee relative mt-6 overflow-hidden border-y border-line/70 py-3">
              <span className="sr-only">
                Manage agents, worktrees, ports, processes, windows, and remote machines.
              </span>
              <div
                className="marquee-track flex w-max items-center font-mono text-sm text-foreground-soft md:text-base"
                aria-hidden
              >
                {[0, 1].map((copy) => (
                  <div key={copy} className="flex shrink-0 items-center">
                    {heroScope.map((item) => (
                      <span key={item} className="flex items-center whitespace-nowrap">
                        {item}
                        <span className="mx-4 text-accent">·</span>
                      </span>
                    ))}
                  </div>
                ))}
              </div>
            </div>

            <p className="mt-7 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              Parallel branches actually run in isolation. No port juggling, no .env copying, no shared-login bleed
            </p>
            <div className="mt-8 flex flex-wrap items-center gap-3">
              <PrimaryButton
                href={githubReleasesURL}
                target="_blank"
                rel="noopener noreferrer"
              >
                Download
              </PrimaryButton>
              <Link
                href="/docs"
                className="inline-flex items-center gap-1.5 rounded-sm border border-line px-5 py-3 text-sm font-semibold transition-colors hover:border-accent hover:text-accent"
              >
                Read Docs
                <span aria-hidden>→</span>
              </Link>
            </div>

            <dl className="mt-8 grid grid-cols-3 gap-6 border-t border-line/70 pt-7">
              <SpecItem label="Client" value="macOS + iOS" />
              <SpecItem label="Daemon" value="macOS + Linux" />
              <SpecItem label="Price" value="Free" />
            </dl>
          </div>

          {/* Right: screenshot */}
          <figure className="relative overflow-hidden rounded-sm border border-line/80 bg-surface/70 shadow-[0_40px_100px_-60px_color-mix(in_oklab,var(--ink)_55%,transparent)]">
            <img
              src="/media/hero.png"
              alt="The Spaces app showing workspaces, terminals, editors, and live agent status side by side"
              className="h-auto w-full"
              fetchPriority="high"
            />
          </figure>
        </div>
      </section>

      {/* ── What you manage (pillars) ── */}
      <section id="manage" className="mt-24 border-t border-line/70">
        <div className="mx-auto w-full max-w-7xl px-6 py-20 md:py-24">
          <div className="max-w-3xl">
            <h2 className="text-[clamp(1.5rem,3.5vw,2.3rem)] font-semibold leading-[1.15] tracking-[-0.01em]">
              Your workflow, <span className="text-accent">minus the friction</span>
            </h2>
            <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              Run a few coding sessions at once and the moving parts multiply —
              worktrees, agents, processes, ports, windows. Spaces makes each of
              those a thing you manage, not a thing you chase.
            </p>
          </div>

          <ul className="mt-14 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            {pillars.map((pillar) => (
              <PillarCard key={pillar.title} pillar={pillar} />
            ))}
          </ul>
        </div>
      </section>

      {/* ── Workspace model ── */}
      <section className="border-t border-line/70 bg-background-soft/40">
        <div className="mx-auto w-full max-w-7xl px-6 py-24">
          <div className="max-w-3xl">
            <h2 className="text-[clamp(1.5rem,3.5vw,2.3rem)] font-semibold leading-[1.15] tracking-[-0.01em]">
              One workspace per task.{" "}
              <span className="text-accent whitespace-nowrap">Open, switch, and close as a unit.</span>
            </h2>
            <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              A workspace is one feature, branch, or experiment with its own
              directory, named services on stable URLs, processes, browser
              sessions, and coding-agent terminals. Launching it starts every
              process and tracks every window. Stopping it shuts everything
              down. Reopening restores the state.
            </p>
          </div>

          <div className="mt-14 grid gap-12 lg:grid-cols-[1fr_0.82fr] lg:items-start">
            <ol className="max-w-2xl">
            {workflow.map((step, i) => (
              <li
                key={step.n}
                className="grid grid-cols-[auto_1fr] gap-x-6 gap-y-2"
              >
                <div className="flex flex-col items-center">
                  <span className="font-mono text-2xl font-semibold leading-none text-accent-2 tabular-nums md:text-3xl">
                    {step.n}
                  </span>
                  {i < workflow.length - 1 ? (
                    <span aria-hidden className="mt-2 w-px flex-1 bg-line/70" />
                  ) : null}
                </div>
                <div className={i < workflow.length - 1 ? "pb-10" : ""}>
                  <h3 className="text-xl font-semibold tracking-tight md:text-2xl">
                    {step.label}
                  </h3>
                  <p className="mt-2 max-w-2xl text-xs leading-6 text-foreground-soft md:text-sm md:leading-7">
                    {step.body}
                  </p>
                </div>
              </li>
            ))}
            </ol>

            <WorkspaceSidebarMock />
          </div>
        </div>
      </section>

      {/* ── Agent alerts ── */}
      <section id="agents" className="border-t border-line/70">
        <div className="mx-auto w-full max-w-7xl px-6 py-20 md:py-24">
          <div className="max-w-3xl">
            <h2 className="mt-5 text-[clamp(1.5rem,3.5vw,2.3rem)] font-semibold leading-[1.15] tracking-[-0.01em]">
              Know which agent needs you,{" "}
              <span className="text-accent whitespace-nowrap">
                and jump straight to it
              </span>
            </h2>
            <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              Run Claude Code, Codex, and opencode across a dozen workspaces and
              it&apos;s easy to lose track of who&apos;s waiting. Each agent
              reports working, blocked, or done — Alerts gathers the ones that
              need you into a single list, so you see what&apos;s stuck or
              finished at a glance and jump to its terminal or workspace with a
              keystroke.
            </p>
          </div>

          <div className="mt-14 grid gap-10 lg:grid-cols-[1.1fr_0.9fr] lg:items-center">
            <AlertsPanel />

            <div className="rounded-sm border border-accent-2/45 bg-[color:color-mix(in_oklab,var(--accent-2)_8%,var(--surface))] p-6 md:p-8">
              <p className="inline-flex items-center gap-2 font-mono text-[0.7rem] uppercase tracking-[0.18em] text-accent-2">
                <span className="h-1.5 w-1.5 rounded-full bg-accent-2" />
                One list, every agent
              </p>
              <p className="mt-4 text-lg font-semibold leading-snug tracking-tight text-foreground md:text-xl">
                Open Alerts, jump to whoever needs you.
              </p>
              <p className="mt-3 text-sm leading-6 text-foreground-soft md:text-base md:leading-7">
                Press <Key>⌘⌥A</Key> from anywhere to open Alerts. Blocked
                agents clear the moment they move again; finished agents stay
                until you review them — so the list is always exactly what needs
                your attention. Select one to focus its terminal, or jump to its
                workspace to see everything around it.
              </p>
              <div className="mt-6 flex flex-wrap items-center gap-2">
                <span className="font-mono text-[0.62rem] uppercase tracking-[0.16em] text-foreground-soft">
                  Works with
                </span>
                {["Claude Code", "Codex", "opencode"].map((name) => (
                  <span
                    key={name}
                    className="rounded-full border border-line/80 bg-surface/60 px-2.5 py-1 text-xs text-foreground"
                  >
                    {name}
                  </span>
                ))}
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* ── Remote machines ── */}
      <section id="remote" className="border-t border-line/70">
        <div className="mx-auto w-full max-w-7xl px-6 py-20 md:py-24">
          <div className="max-w-3xl">
            <h2 className="mt-5 text-[clamp(1.5rem,3.5vw,2.3rem)] font-semibold leading-[1.15] tracking-[-0.01em]">
              Connect to all machines <span className="text-accent whitespace-nowrap">from one Mac</span>
            </h2>
            <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              Pair another Mac or a cloud Linux box over SSH with pinned TLS.
              Each machine runs its own <code>spacesd</code> and appears as its
              own section in the sidebar — projects, workspaces, terminals, and
              agents, all reachable from the Mac in front of you.
            </p>
          </div>

          <div className="mt-14 grid gap-10 lg:grid-cols-[1.1fr_0.9fr] lg:items-center">
            <RemoteDiagram />

            <div className="rounded-sm border border-accent-2/45 bg-[color:color-mix(in_oklab,var(--accent-2)_8%,var(--surface))] p-6 md:p-8">
              <p className="inline-flex items-center gap-2 font-mono text-[0.7rem] uppercase tracking-[0.18em] text-accent-2">
                <span className="h-1.5 w-1.5 rounded-full bg-accent-2" />
                Sessions outlive your laptop
              </p>
              <p className="mt-4 text-lg font-semibold leading-snug tracking-tight text-foreground md:text-xl">
                Like tmux, for everything a session runs.
              </p>
              <p className="mt-3 text-sm leading-6 text-foreground-soft md:text-base md:leading-7">
                Terminals and coding agents run on the daemon, not on your SSH
                connection. Kick off a build or an agent on a remote box, close
                your laptop, and it keeps running — then reattach later from
                your Mac or your phone, right where it left off.
              </p>
            </div>
          </div>
        </div>
      </section>

      {/* ── Agent orchestration ── */}
      <section id="orchestrate" className="border-t border-line/70 bg-background-soft/40">
        <div className="mx-auto w-full max-w-7xl px-6 py-20 md:py-24">
          <div className="max-w-3xl">
            <h2 className="mt-5 text-[clamp(1.5rem,3.5vw,2.3rem)] font-semibold leading-[1.15] tracking-[-0.01em]">
              Talk to one agent{" "}
              <span className="text-accent whitespace-nowrap">to get all your work done</span>
            </h2>
            <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              Put a single agent in front of everything you have going — a fix
              in this repo, a feature on that branch, an experiment on the Linux
              box. Tell it what you want; it breaks the work into pieces, spins
              up an isolated worktree for each, and puts a child agent on every
              one — across all your projects, features, and machines.
            </p>
            <p className="mt-4 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              The lead sends each child its work, is told the moment one needs
              input or finishes, checks any child&apos;s terminal, and answers
              its prompts — pulling the whole fleet to a finish while you watch
              every agent work live.
            </p>
          </div>

          <div className="mt-14 grid gap-10 lg:grid-cols-[1.1fr_0.9fr] lg:items-center">
            <OrchestrationDiagram />

            <div className="rounded-sm border border-accent-2/45 bg-[color:color-mix(in_oklab,var(--accent-2)_8%,var(--surface))] p-6 md:p-8">
              <p className="inline-flex items-center gap-2 font-mono text-[0.7rem] uppercase tracking-[0.18em] text-accent-2">
                <span className="h-1.5 w-1.5 rounded-full bg-accent-2" />
                Cross-harness · cross-model · cross-device
              </p>
              <p className="mt-4 text-lg font-semibold leading-snug tracking-tight text-foreground md:text-xl">
                The right agent for every piece of work.
              </p>
              <ul className="mt-4 space-y-3 text-sm leading-6 text-foreground-soft md:text-base md:leading-7">
                <li>
                  <strong className="font-semibold text-foreground">Mix harnesses.</strong>{" "}
                  Claude Code, Codex, and opencode — any of them can lead, any can
                  be a child.
                </li>
                <li>
                  <strong className="font-semibold text-foreground">Mix models.</strong>{" "}
                  Each agent runs whatever model its harness supports, so you pick
                  the right brain for each job.
                </li>
                <li>
                  <strong className="font-semibold text-foreground">Mix machines.</strong>{" "}
                  Children run wherever you have them — a cloud Linux box does the
                  heavy lifting while you drive from your Mac.
                </li>
              </ul>
              <p className="mt-5 text-sm leading-6 text-foreground-soft md:text-base md:leading-7">
                Every child is a real terminal in the app. Alerts surface whoever
                needs you, and one shortcut jumps you to any agent&apos;s pane.
              </p>
              <Link
                href="/docs/orchestration"
                className="mt-6 inline-flex items-center gap-1.5 text-sm font-semibold text-accent transition-colors hover:underline"
              >
                Read the orchestration guide
                <span aria-hidden>→</span>
              </Link>
            </div>
          </div>
        </div>
      </section>

      {/* ── Take it with you (mobile) ── */}
      <section id="mobile" className="border-t border-line/70 bg-background-soft/60">
        <div className="mx-auto w-full max-w-7xl px-6 py-20 md:py-24">
          <div className="grid gap-10 lg:grid-cols-2 lg:items-center">
            <div className="max-w-xl">
              <p className="inline-flex items-center gap-2 font-mono text-[0.7rem] uppercase tracking-[0.18em] text-foreground-soft">
                <span className="rounded-full border border-accent-2/50 px-2 py-0.5 text-[0.62rem] text-accent-2">
                  Coming soon
                </span>
              </p>
              <h2 className="mt-5 text-[clamp(1.5rem,3.5vw,2.3rem)] font-semibold leading-[1.15] tracking-[-0.01em]">
                Remote control <span className="text-accent whitespace-nowrap">from your iPhone</span>
              </h2>
              <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
                Pair the Spaces iOS app with a QR code. Browse live terminal
                sessions across your workspaces, watch an agent that&apos;s
                working or waiting, type into the same shell, and run or restart
                processes — from your phone.
              </p>
              <p className="mt-4 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
                Sessions run in the Spaces daemon, so they keep running even if
                the Mac app quits — and your phone works whether or not the app
                is open.
              </p>
              <Link
                href="/docs/ios"
                className="mt-6 inline-flex items-center gap-1.5 text-sm font-semibold text-accent transition-colors hover:underline"
              >
                Read the iOS docs
                <span aria-hidden>→</span>
              </Link>
            </div>

            <MediaPlaceholder
              label="iOS app — live session list & terminal"
              aspect="aspect-[4/3]"
            >
              <PhoneGlyph />
            </MediaPlaceholder>
          </div>
        </div>
      </section>

      {/* ── Sessions that keep running (tmux-style persistence) ── */}
      <section id="proxy" className="border-t border-line/70">
        <div className="mx-auto w-full max-w-7xl px-6 py-20 md:py-24">
          <div className="max-w-3xl">
            <h2 className="mt-5 text-[clamp(1.5rem,3.5vw,2.3rem)] font-semibold leading-[1.15] tracking-[-0.01em]">
              One localhost, one cookie jar, <span className="text-accent">endless conflicts. Solved.</span>
            </h2>
            <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              Three worktrees, one <code>localhost</code>: the ports collide, and since browsers scope
              cookies to hostname (not port), logging into one logs you into all three. Spaces routes each
              workspace through its own hostname, so every branch gets its own port and its own cookie jar.
            </p>
          </div>

          <div className="mt-14 grid gap-6 lg:grid-cols-2">
            <ComparisonColumn tone="negative" label="Plain localhost" items={localhostPains} />
            <ComparisonColumn tone="accent" label="Spaces with Caddy Reverse Proxy" items={spacesFixes} />
          </div>
        </div>
      </section>

      {/* ── Built for the keyboard ── */}
      <section className="border-t border-line/70">
        <div className="mx-auto w-full max-w-7xl px-6 py-24">
          <div className="max-w-3xl">
            <h2 className="text-[clamp(1.5rem,3.5vw,2.3rem)] font-semibold leading-[1.15] tracking-[-0.01em]">
              Built for <span className="text-accent">the keyboard</span>
            </h2>
            <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              Context switching is a keystroke, not a window hunt. Focus any
              session (browser or terminal) in the active workspace, cycle
              through just that workspace&apos;s sessions to stay in flow, or
              pull any window across every workspace from the command palette,
              all without lifting your hands off the keyboard. <Link href="/docs/shortcuts" className="text-accent hover:underline">
                Every shortcut is configurable.
              </Link>
            </p>
            <p className="mt-6 flex flex-wrap items-center gap-x-2.5 gap-y-2 text-sm text-foreground-soft">
              <Key>⌘1–0</Key>
              <span>focus</span>
              <Key>⌘⌥]</Key>
              <span>cycle</span>
              <Key>⌘⌥-</Key>
              <span>command palette</span>
            </p>
          </div>

          <figure className="mt-12 overflow-hidden rounded-sm border border-line/80 bg-surface/70 p-2 md:p-3">
            <video
              src="/media/demo_nav_palette.mp4"
              autoPlay
              loop
              muted
              playsInline
              className="h-auto w-full rounded-sm"
            />
          </figure>
        </div>
      </section>

      {/* ── FAQ ── */}
      <section id="features" className="border-t border-line/70">
        <div className="mx-auto w-full max-w-7xl px-6 py-20 md:py-24">
          <div className="flex flex-col gap-2 md:flex-row md:items-end md:justify-between">
            <h2 className="text-[clamp(1.5rem,3.5vw,2.3rem)] font-semibold leading-[1.15] tracking-[-0.01em]">
              Features
            </h2>
          </div>

          <ol className="mt-12 grid border-t border-line/70 md:grid-cols-2">
            {keyFeatures.map((feature, i) => (
              <FeatureRow key={feature.title} n={i + 1} feature={feature} index={i} />
            ))}
          </ol>
        </div>
      </section>

      {/* ── Ports & proxy ── */}
      <section id="faq" className="border-t border-line/70 bg-background-soft/40">
        <div className="mx-auto w-full max-w-7xl px-6 py-20 md:py-24">
          <div className="max-w-3xl">
            <h2 className="text-[clamp(1.5rem,3.5vw,2.3rem)] font-semibold leading-[1.15] tracking-[-0.01em]">
              FAQ
            </h2>
            <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              Common questions about setup, tools, and the app. Still stuck?{" "}
              <a
                href="mailto:support@spaces.dev"
                className="text-accent hover:underline"
              >
                Email us.
              </a>
            </p>
          </div>

          <div className="mt-12 max-w-3xl">
            <dl className="divide-y divide-line/70 border-y border-line/70">
              {faqItems.map((item) => (
                <details key={item.question} className="group py-2">
                  <summary className="flex cursor-pointer select-none list-none items-center justify-between py-3 text-base font-semibold text-foreground md:text-lg">
                    {item.question}
                    <span
                      aria-hidden
                      className="ml-4 shrink-0 font-mono text-xs text-accent-2 transition-transform duration-200 group-open:rotate-45"
                    >
                      +
                    </span>
                  </summary>
                  <div className="pb-4 pr-8 text-sm leading-7 text-foreground-soft md:text-base">
                    {item.answer}
                  </div>
                </details>
              ))}
            </dl>
          </div>
        </div>
      </section>

      {/* ── CTA ── */}
      <section className="border-t border-line/70">
        <div className="mx-auto w-full max-w-7xl px-6 py-24 md:py-28">
          <h2 className="max-w-2xl text-[clamp(1.5rem,3.5vw,2.3rem)] font-semibold leading-[1.15] tracking-[-0.01em]">
            Run it on your Mac
          </h2>
          <p className="mt-4 max-w-2xl text-base leading-7 text-foreground-soft md:text-lg">
            Native macOS, signed DMG, in-app updates via Sparkle. Free and
            open source.
          </p>
          <div className="mt-8 flex flex-wrap gap-3">
            <PrimaryButton
              href={githubReleasesURL}
              target="_blank"
              rel="noopener noreferrer"
            >
              Download
            </PrimaryButton>
            <Link
              href="/docs"
              className="inline-flex items-center gap-1.5 rounded-sm border border-line px-5 py-3 text-sm font-semibold transition-colors hover:border-accent hover:text-accent"
            >
              Read Docs
              <span aria-hidden>→</span>
            </Link>
          </div>
        </div>
      </section>

      <SiteFooter />
    </div>
  );
}

function Key({ children }: { children: React.ReactNode }) {
  return (
    <kbd className="inline-flex items-center rounded-sm border border-accent-2/55 bg-accent-2/20 px-2 py-1 font-mono text-xs font-semibold leading-none text-accent-2">
      {children}
    </kbd>
  );
}

function PillarCard({ pillar }: { pillar: Pillar }) {
  return (
    <li className="flex h-full flex-col gap-4 rounded-sm border border-line/80 bg-surface/50 p-6 transition-colors hover:border-accent/50">
      <span className="inline-flex h-10 w-10 items-center justify-center rounded-sm border border-accent/30 bg-accent/10 text-accent">
        {pillar.icon}
      </span>
      <div className="min-w-0">
        <h3 className="text-lg font-semibold tracking-tight">{pillar.title}</h3>
        <p className="mt-2 text-sm leading-6 text-foreground-soft">
          {pillar.description}
        </p>
      </div>
      {pillar.href ? (
        <Link
          href={pillar.href}
          className="mt-auto inline-flex items-center gap-1.5 pt-1 text-sm font-semibold text-accent transition-colors hover:underline"
        >
          {pillar.hrefLabel}
          <span aria-hidden>→</span>
        </Link>
      ) : null}
    </li>
  );
}

function RemoteDiagram() {
  return (
    <figure className="rounded-sm border border-line/80 bg-surface/50 p-6 md:p-10">
      <div className="mx-auto flex max-w-md flex-col items-center">
        {/* Hub: your Mac */}
        <div className="w-full max-w-[15rem] rounded-sm border border-accent/45 bg-accent/10 px-5 py-4 text-center">
          <p className="font-mono text-[0.62rem] uppercase tracking-[0.16em] text-accent">
            Spaces Client (Mac)
          </p>
        </div>

        {/* Vertical spine from the hub */}
        <span aria-hidden className="h-8 w-px bg-line/80" />

        {/* Horizontal bus + drop ticks (sm+) */}
        <div className="relative w-full">
          <span
            aria-hidden
            className="absolute left-[16.666%] right-[16.666%] top-0 hidden h-px bg-line/80 sm:block"
          />
          <div className="grid gap-4 sm:grid-cols-3">
            {remoteNodes.map((node) => (
              <div key={node.name} className="flex flex-col items-center">
                <span
                  aria-hidden
                  className="hidden h-6 w-px bg-line/80 sm:block"
                />
                <div className="w-full rounded-sm border border-line/80 bg-background/60 px-4 py-3 text-center">
                  <p className="text-sm font-semibold tracking-tight text-foreground">
                    {node.name}
                  </p>
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>
      <figcaption className="mt-8 text-center font-mono text-[0.7rem] uppercase tracking-[0.16em] text-foreground-soft">
        One sidebar · every machine
      </figcaption>
    </figure>
  );
}

// Diagram for the orchestration section: one lead agent driving a fleet of
// child agents, each in its own isolated worktree, some on other machines.
function OrchestrationDiagram() {
  const children: { harness: string; where: string }[] = [
    { harness: "claude", where: "worktree · Mac" },
    { harness: "codex", where: "worktree · Linux" },
    { harness: "opencode", where: "worktree · Mac" },
  ];
  return (
    <figure className="rounded-sm border border-line/80 bg-surface/50 p-6 md:p-10">
      <div className="mx-auto flex max-w-md flex-col items-center">
        {/* Hub: the lead agent */}
        <div className="w-full max-w-[15rem] rounded-sm border border-accent/45 bg-accent/10 px-5 py-4 text-center">
          <p className="font-mono text-[0.62rem] uppercase tracking-[0.16em] text-accent">
            Lead agent
          </p>
        </div>

        {/* Vertical spine from the hub */}
        <span aria-hidden className="h-8 w-px bg-line/80" />

        {/* Horizontal bus + drop ticks (sm+) */}
        <div className="relative w-full">
          <span
            aria-hidden
            className="absolute left-[16.666%] right-[16.666%] top-0 hidden h-px bg-line/80 sm:block"
          />
          <div className="grid gap-4 sm:grid-cols-3">
            {children.map((child) => (
              <div key={child.harness} className="flex flex-col items-center">
                <span aria-hidden className="hidden h-6 w-px bg-line/80 sm:block" />
                <div className="w-full rounded-sm border border-line/80 bg-background/60 px-4 py-3 text-center">
                  <p className="text-sm font-semibold tracking-tight text-foreground">
                    {child.harness}
                  </p>
                  <p className="mt-1 font-mono text-[0.6rem] uppercase tracking-[0.12em] text-foreground-soft">
                    {child.where}
                  </p>
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>
      <figcaption className="mt-8 text-center font-mono text-[0.7rem] uppercase tracking-[0.16em] text-foreground-soft">
        One lead · a fleet of worktrees
      </figcaption>
    </figure>
  );
}

// Diagram for the persistence section: the Spaces app detaches, but the
// device daemon keeps every terminal and agent session alive for reattach.

// A muted keycap used inside the app mocks, distinct from the amber marketing
// <Key>. Mirrors the subtle shortcut chips in the real sidebar.
function NumKey({ children }: { children: React.ReactNode }) {
  return (
    <kbd className="inline-flex min-w-[1.35rem] items-center justify-center rounded border border-line bg-foreground/[0.06] px-1.5 py-0.5 font-mono text-[0.62rem] leading-none text-foreground-soft">
      {children}
    </kbd>
  );
}

// Three dimmed traffic-light dots — the window-chrome cue that reads these
// panels as the native app, not a web widget.
function WindowChrome({ children }: { children?: React.ReactNode }) {
  return (
    <div className="flex items-center gap-1.5 border-b border-line/70 px-4 py-3">
      <span className="h-2.5 w-2.5 rounded-full bg-negative/60" />
      <span className="h-2.5 w-2.5 rounded-full bg-accent-2/60" />
      <span className="h-2.5 w-2.5 rounded-full bg-accent/60" />
      {children ? <div className="ml-2 min-w-0">{children}</div> : null}
    </div>
  );
}

function BellIcon({ className = "h-4 w-4" }: { className?: string }) {
  return (
    <svg viewBox="0 0 20 20" fill="none" aria-hidden className={className}>
      <path
        d="M6 8a4 4 0 1 1 8 0c0 3 1 4 1.5 4.5H4.5C5 12 6 11 6 8Z"
        stroke="currentColor"
        strokeWidth="1.4"
        strokeLinejoin="round"
      />
      <path d="M8.5 15a1.5 1.5 0 0 0 3 0" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
    </svg>
  );
}

function ProjectIcon({ className = "h-4 w-4" }: { className?: string }) {
  return (
    <svg viewBox="0 0 20 20" fill="none" aria-hidden className={className}>
      <circle cx="5" cy="5" r="1.8" stroke="currentColor" strokeWidth="1.4" />
      <circle cx="5" cy="15" r="1.8" stroke="currentColor" strokeWidth="1.4" />
      <circle cx="15" cy="10" r="1.8" stroke="currentColor" strokeWidth="1.4" />
      <path d="M6.8 5H11a2 2 0 0 1 2 2v1M6.8 15H11a2 2 0 0 0 2-2v-1" stroke="currentColor" strokeWidth="1.4" />
    </svg>
  );
}

function GlobeIcon({ className = "h-4 w-4" }: { className?: string }) {
  return (
    <svg viewBox="0 0 20 20" fill="none" aria-hidden className={className}>
      <circle cx="10" cy="10" r="7" stroke="currentColor" strokeWidth="1.4" />
      <path d="M3 10h14M10 3c2 2.2 2 11.8 0 14M10 3c-2 2.2-2 11.8 0 14" stroke="currentColor" strokeWidth="1.4" />
    </svg>
  );
}

function TerminalIcon({ className = "h-4 w-4" }: { className?: string }) {
  return (
    <svg viewBox="0 0 20 20" fill="none" aria-hidden className={className}>
      <rect x="3" y="4" width="14" height="12" rx="1.6" stroke="currentColor" strokeWidth="1.4" />
      <path d="M6 8.5 8.5 11 6 13.5M10.5 13.5H14" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function SparkleIcon({ className = "h-4 w-4" }: { className?: string }) {
  return (
    <svg viewBox="0 0 20 20" fill="none" aria-hidden className={className}>
      <path
        d="M10 3.2c.5 3 1.8 4.3 4.8 4.8-3 .5-4.3 1.8-4.8 4.8-.5-3-1.8-4.3-4.8-4.8 3-.5 4.3-1.8 4.8-4.8Z"
        stroke="currentColor"
        strokeWidth="1.3"
        strokeLinejoin="round"
      />
      <path d="M15 12.5c.2 1.2.7 1.7 1.9 1.9-1.2.2-1.7.7-1.9 1.9-.2-1.2-.7-1.7-1.9-1.9 1.2-.2 1.7-.7 1.9-1.9Z" stroke="currentColor" strokeWidth="1.2" strokeLinejoin="round" />
    </svg>
  );
}

// Sidebar mock for the "One workspace per task" section. Mirrors the real app:
// Alerts entry, a Projects header, and a selected workspace expanded into its
// numbered targets (browser, process, agent), with sibling workspaces below.
function WorkspaceSidebarMock() {
  return (
    <figure className="overflow-hidden rounded-sm border border-line/80 bg-surface/70 shadow-[0_40px_100px_-60px_color-mix(in_oklab,var(--ink)_55%,transparent)]">
      <WindowChrome />
      <div className="p-2.5">
        <p className="px-2.5 pb-1 pt-3 font-mono text-[0.62rem] uppercase tracking-[0.16em] text-foreground-soft">
          Projects
        </p>

        <div className="flex items-center gap-2 px-2.5 py-1.5 text-sm font-semibold text-foreground">
          <ProjectIcon />
          <span>spaces</span>
        </div>

        {/* Selected, active workspace — expanded into its targets. */}
        <div className="mt-0.5 rounded-sm border border-accent/40 bg-accent/[0.06]">
          <div className="flex items-center gap-2 px-2.5 py-2 text-sm font-semibold text-foreground">
            <span className="h-2 w-2 rounded-full bg-accent" />
            <span>main</span>
          </div>
          <ul className="space-y-0.5 pb-1.5 pl-2 pr-2.5">
            <TargetRow shortcut="⌘1" icon={<GlobeIcon className="h-3.5 w-3.5" />} label="web" />
            <TargetRow shortcut="⌘2" icon={<TerminalIcon className="h-3.5 w-3.5" />} label="npm:dev" />
            <TargetRow shortcut="⌘3" icon={<SparkleIcon className="h-3.5 w-3.5" />} label="codex" />
          </ul>
        </div>

        <WorkspaceRow name="schema-cleanup" active />
        <WorkspaceRow name="website-updates" />
      </div>
    </figure>
  );
}

function TargetRow({
  shortcut,
  icon,
  label,
}: {
  shortcut: string;
  icon: React.ReactNode;
  label: string;
}) {
  return (
    <li className="flex items-center gap-2.5 rounded-sm px-2 py-1.5">
      <NumKey>{shortcut}</NumKey>
      <span className="text-foreground-soft">{icon}</span>
      <span className="text-sm text-foreground">{label}</span>
    </li>
  );
}

function WorkspaceRow({ name, active }: { name: string; active?: boolean }) {
  return (
    <div className="flex items-center gap-2 px-2.5 py-2 text-sm text-foreground">
      <span
        className={
          active
            ? "h-2 w-2 rounded-full bg-accent"
            : "h-2 w-2 rounded-full border border-foreground-soft/50"
        }
      />
      <span>{name}</span>
    </div>
  );
}

// Alerts panel mock for the agents section. Each row is one agent that raised
// an alert — blocked (amber) or done (teal) — with its workspace, agent name,
// and a jump affordance.
function AlertsPanel() {
  return (
    <figure className="overflow-hidden rounded-sm border border-line/80 bg-surface/70 shadow-[0_40px_100px_-60px_color-mix(in_oklab,var(--ink)_55%,transparent)]">
      <div className="flex items-center border-b border-line/70 px-4 py-3.5">
        <span className="inline-flex items-center gap-2 text-sm font-semibold tracking-tight text-foreground">
          <BellIcon />
          Alerts
        </span>
      </div>
      <ul className="divide-y divide-line/60">
        {agentAlerts.map((alert, index) => (
          <AlertRow key={alert.workspace} alert={alert} shortcut={`⌘${index + 1}`} />
        ))}
      </ul>
    </figure>
  );
}

function AlertRow({ alert, shortcut }: { alert: AgentAlert; shortcut: string }) {
  const blocked = alert.status === "blocked";
  const tone = blocked
    ? {
        dot: "bg-accent-2",
        pill: "border-accent-2/45 bg-accent-2/10 text-accent-2",
        label: "Blocked",
      }
    : {
        dot: "bg-accent",
        pill: "border-accent/45 bg-accent/10 text-accent",
        label: "Done",
      };
  return (
    <li className="flex items-center gap-3 px-4 py-3 sm:px-5">
      <NumKey>{shortcut}</NumKey>
      <span className={`h-2 w-2 shrink-0 rounded-full ${tone.dot}`} aria-hidden />
      <div className="min-w-0 flex-1">
        <p className="flex items-center gap-2 truncate text-sm">
          <span className="font-mono text-foreground">{alert.workspace}</span>
          <span className="text-foreground-soft">{alert.agent}</span>
        </p>
      </div>
    </li>
  );
}

function ComparisonColumn({
  tone,
  label,
  items,
}: {
  tone: "negative" | "accent";
  label: string;
  items: ComparisonItem[];
}) {
  const toneClasses =
    tone === "negative"
      ? {
          border: "border-negative/35",
          bg: "bg-[color:color-mix(in_oklab,var(--negative)_6%,var(--surface))]",
          text: "text-negative",
          dot: "bg-negative",
        }
      : {
          border: "border-accent/35",
          bg: "bg-[color:color-mix(in_oklab,var(--accent)_6%,var(--surface))]",
          text: "text-accent",
          dot: "bg-accent",
        };

  return (
    <div className={`rounded-sm border ${toneClasses.border} ${toneClasses.bg} p-6 md:p-8`}>
      <p
        className={`inline-flex items-center gap-2 font-mono text-[0.7rem] uppercase tracking-[0.18em] ${toneClasses.text}`}
      >
        <span className={`h-1.5 w-1.5 rounded-full ${toneClasses.dot}`} />
        {label}
      </p>
      <ul className="mt-6 space-y-6">
        {items.map((item) => (
          <li key={item.title}>
            <h3 className="text-base font-semibold tracking-tight text-foreground">
              {item.title}
            </h3>
            <p className="mt-1.5 text-sm leading-6 text-foreground-soft">{item.body}</p>
          </li>
        ))}
      </ul>
    </div>
  );
}

function MediaPlaceholder({
  label,
  aspect,
  children,
}: {
  label: string;
  aspect: string;
  children?: React.ReactNode;
}) {
  return (
    <figure
      className={`relative flex ${aspect} w-full items-center justify-center overflow-hidden rounded-sm border border-dashed border-line bg-surface/40`}
    >
      <div className="flex flex-col items-center gap-4 px-6 text-center text-foreground-soft">
        {children}
        <figcaption className="font-mono text-[0.7rem] uppercase tracking-[0.16em]">
          {label}
        </figcaption>
      </div>
    </figure>
  );
}

function PhoneGlyph() {
  return (
    <svg viewBox="0 0 48 48" fill="none" aria-hidden className="h-12 w-12 text-line">
      <rect
        x="15"
        y="6"
        width="18"
        height="36"
        rx="3.5"
        stroke="currentColor"
        strokeWidth="1.75"
      />
      <path
        d="M21 10h6"
        stroke="currentColor"
        strokeWidth="1.75"
        strokeLinecap="round"
      />
      <path
        d="M20 20h8M20 25h8M20 30h5"
        stroke="color-mix(in oklab, var(--accent) 70%, transparent)"
        strokeWidth="1.75"
        strokeLinecap="round"
      />
    </svg>
  );
}

function SpecItem({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <dt className="font-mono text-[0.62rem] uppercase tracking-[0.14em] text-foreground-soft">
        {label}
      </dt>
      <dd className="mt-1.5 text-lg font-semibold leading-tight tracking-tight tabular-nums md:text-xl">
        {value}
      </dd>
    </div>
  );
}

type FeatureRowProps = {
  n: number;
  feature: Feature;
  index: number;
};

function FeatureRow({ n, feature, index }: FeatureRowProps) {
  return (
    <li
      className={`flex gap-5 border-b border-line/70 py-7 md:py-8 ${
        index % 2 === 0 ? "md:border-r md:border-line/70 md:pr-10" : "md:pl-10"
      }`}
    >
      <span className="shrink-0 pt-0.5 font-mono text-xs text-accent tabular-nums">
        {String(n).padStart(2, "0")}
      </span>
      <div className="min-w-0">
        <h3 className="text-base font-semibold tracking-tight">
          {feature.title}
        </h3>
        <p className="mt-2 text-sm leading-6 text-foreground-soft">
          {feature.description}
        </p>
      </div>
    </li>
  );
}
