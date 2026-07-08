/* Hallmark · macrostructure: Workbench · genre: modern-minimal · tone: technical/precise · anchor hue: teal (brand) + amber (status/keys) */
import Link from "next/link";
import { SiteHeader } from "./components/site-header";
import { SiteFooter } from "./components/site-footer";
import { PrimaryButton } from "./components/primary-button";

const githubReleasesURL = "https://github.com/yogesh-dhande/spaces/releases/latest";

// Scope strip under the hero headline — the surfaces Spaces puts under one roof.
const heroScope = [
  "agents",
  "worktrees",
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
        <rect x="3" y="3.5" width="14" height="5" rx="1.2" stroke="currentColor" strokeWidth="1.5" />
        <rect x="3" y="11.5" width="14" height="5" rx="1.2" stroke="currentColor" strokeWidth="1.5" />
        <path d="M6 6h.01M6 14h.01" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
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
        <circle cx="10" cy="4" r="2" stroke="currentColor" strokeWidth="1.5" />
        <circle cx="4" cy="16" r="2" stroke="currentColor" strokeWidth="1.5" />
        <circle cx="16" cy="16" r="2" stroke="currentColor" strokeWidth="1.5" />
        <path
          d="M10 6v3m0 0-4.5 5m4.5-5 4.5 5"
          stroke="currentColor"
          strokeWidth="1.5"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
      </svg>
    ),
  },
];

type Feature = {
  title: string;
  description: string;
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
];

type Shortcut = {
  keys: string;
  label: string;
};

// Accurate shortcuts mirror /docs/shortcuts. Leader (⌘⌥) is configurable.
const navigateShortcuts: Shortcut[] = [
  { keys: "⌘⌥-", label: "Open the command palette" },
  { keys: "⌘1–0", label: "Open or focus a workspace target by number" },
  { keys: "⌘⌥]", label: "Next already-open workspace window" },
  { keys: "⌘⌥[", label: "Previous window" },
  { keys: "⌘⌥=", label: "Show or hide Spaces" },
];

const actShortcuts: Shortcut[] = [
  { keys: "⌘N", label: "New workspace for the selected project" },
  { keys: "⌘⌥T", label: "Open a terminal for the selected workspace" },
  { keys: "⌘⌥E", label: "Open the workspace in your editor" },
  { keys: "⌘⌥A", label: "Open Alerts" },
  { keys: "⌘⌥F", label: "Reveal the workspace in Finder" },
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
    question: "Can I use it with CLI coding agents like Claude Code or Codex CLI?",
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
    question: "Who is Spaces not for?",
    answer: (
      <>
        <p className="mb-3">
          Spaces makes opinionated tradeoffs to prioritize speed and
          flexibility. They may not suit everyone.
        </p>
        <ul className="ml-4 list-disc space-y-2">
          <li>
            <span className="font-semibold text-foreground">
              If you keep your window count low.
            </span>{" "}
            Spaces gives each browser session, terminal, and editor instance
            a tracked focus target so you can lay them out across your screens
            and recall them on demand. The upside is speed and flexibility —
            focusing a window takes 20–30 ms, versus 200 ms to a full second
            to reconcile and focus a specific tab in Chrome as you add or
            move them. It also lets you view any two windows side by side
            (even from different workspaces) with your favorite tiling window
            manager. If a sparse desktop matters more to you than instant
            recall, Spaces will feel like clutter.
          </li>
          <li>
            <span className="font-semibold text-foreground">
              If you must use macOS full-screen mode.
            </span>{" "}
            macOS puts each full-screen window in its own desktop space, so
            focusing another window forces the OS to transition between
            desktops. Spaces still works, but it shines when you stay in
            windowed mode.
          </li>
        </ul>
      </>
    ),
  },
  {
    question: "Is there a mobile app?",
    answer: (
      <>
        Yes. The Spaces iOS app pairs with your Mac by scanning a QR code. From
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
  detail: string;
};

const remoteNodes: RemoteNode[] = [
  { name: "Local Mac", detail: "this machine" },
  { name: "Remote Mac", detail: "SSH · pinned TLS" },
  { name: "Cloud Linux", detail: "spacesd on Ubuntu" },
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
            <p className="inline-flex items-center gap-2 font-mono text-[0.7rem] uppercase tracking-[0.18em] text-foreground-soft">
              <span className="h-1.5 w-1.5 rounded-full bg-accent" />
              macOS + iOS · open source
            </p>
            <h1 className="mt-5 text-[clamp(2rem,4vw,3.5rem)] font-semibold leading-[1.04] tracking-[-0.01em]">
              Manage <span className="text-accent">parallel coding sessions</span>
            </h1>

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
              Group coding agents, processes, ports, browser tabs, and code editor into
              isolated per-branch workspaces — run them on your Mac or a
              remote Linux box, and pick any session up on your iPhone.
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
                className="inline-flex items-center gap-1.5 rounded-full border border-line px-5 py-3 text-sm font-semibold transition-colors hover:border-accent hover:text-accent"
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
          <figure className="relative overflow-hidden rounded-xl border border-line/80 bg-surface/70 shadow-[0_40px_100px_-60px_color-mix(in_oklab,var(--ink)_55%,transparent)]">
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
              <span className="text-accent">Open, switch, and close as a unit.</span>
            </h2>
            <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              A workspace is one feature, branch, or experiment with its own
              directory, named services on stable URLs, processes, browser
              sessions, and coding-agent terminals. Launching it starts every
              process and tracks every window. Stopping it shuts everything
              down. Reopening restores the state.
            </p>
          </div>

          <ol className="mt-14 max-w-3xl">
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
                  <p className="mt-2 max-w-2xl text-sm leading-6 text-foreground-soft md:text-base md:leading-7">
                    {step.body}
                  </p>
                </div>
              </li>
            ))}
          </ol>
        </div>
      </section>

      {/* ── Remote machines ── */}
      <section id="remote" className="border-t border-line/70">
        <div className="mx-auto w-full max-w-7xl px-6 py-20 md:py-24">
          <div className="max-w-3xl">
            <p className="inline-flex items-center gap-2 font-mono text-[0.7rem] uppercase tracking-[0.18em] text-foreground-soft">
              <span className="h-1.5 w-1.5 rounded-full bg-accent" />
              Remote machines
            </p>
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

            <div className="rounded-xl border border-accent-2/45 bg-[color:color-mix(in_oklab,var(--accent-2)_8%,var(--surface))] p-6 md:p-8">
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

      {/* ── Take it with you (mobile) ── */}
      <section id="mobile" className="border-t border-line/70 bg-background-soft/60">
        <div className="mx-auto w-full max-w-7xl px-6 py-20 md:py-24">
          <div className="grid gap-10 lg:grid-cols-2 lg:items-center">
            <div className="max-w-xl">
              <p className="inline-flex items-center gap-2 font-mono text-[0.7rem] uppercase tracking-[0.18em] text-foreground-soft">
                <span className="h-1.5 w-1.5 rounded-full bg-accent" />
                <span>iOS companion</span>
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
                Sessions keep running even if the Mac app quits; acting from your
                phone brings it back automatically.
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

      {/* ── Built for the keyboard ── */}
      <section className="border-t border-line/70">
        <div className="mx-auto w-full max-w-7xl px-6 py-24">
          <div className="max-w-3xl">
            <h2 className="text-[clamp(1.5rem,3.5vw,2.3rem)] font-semibold leading-[1.15] tracking-[-0.01em]">
              Built for <span className="text-accent">the keyboard</span>
            </h2>
            <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              Context switching is a keystroke, not a hunt. Navigate and act
              without lifting your hands off the keyboard — the leader is{" "}
              <Key>⌘⌥</Key> by default, and{" "}
              <Link href="/docs/shortcuts" className="text-accent hover:underline">
                every shortcut is configurable
              </Link>
              .
            </p>
          </div>

          <div className="mt-12 grid gap-x-12 gap-y-10 md:grid-cols-2">
            <ShortcutGroup title="Navigate" shortcuts={navigateShortcuts} />
            <ShortcutGroup title="Act" shortcuts={actShortcuts} />
          </div>
        </div>
      </section>

      {/* ── In Action ── */}
      <section className="border-t border-line/70 bg-background-soft/40">
        <div className="mx-auto w-full max-w-7xl px-6 py-24">
          <div className="max-w-3xl">
            <h2 className="text-[clamp(1.5rem,3.5vw,2.3rem)] font-semibold leading-[1.15] tracking-[-0.01em]">
              Get to any window{" "}
              <span className="text-accent whitespace-nowrap">with a few keystrokes</span>
            </h2>
            <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              Numbered shortcuts focus any window in the active workspace.
              Cycle through windows of the same workspace, or use the
              global command palette to pull any window across any workspace.
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

          <figure className="mt-12 overflow-hidden rounded-xl border border-line/80 bg-surface/70 p-2 md:p-3">
            <video
              src="/media/demo_nav_palette.mp4"
              autoPlay
              loop
              muted
              playsInline
              className="h-auto w-full rounded-lg"
            />
          </figure>
        </div>
      </section>

      {/* ── Capabilities index ── */}
      <section id="features" className="border-t border-line/70">
        <div className="mx-auto w-full max-w-7xl px-6 py-20 md:py-24">
          <div className="flex flex-col gap-2 md:flex-row md:items-end md:justify-between">
            <h2 className="text-[clamp(1.5rem,3.5vw,2.3rem)] font-semibold leading-[1.15] tracking-[-0.01em]">
              Capabilities
            </h2>
            <p className="font-mono text-xs tracking-[0.16em] tabular-nums">
              <span className="text-accent">{String(keyFeatures.length).padStart(2, "0")}</span>
              <span className="text-foreground-soft"> features</span>
            </p>
          </div>

          <ol className="mt-12 grid border-t border-line/70 md:grid-cols-2">
            {keyFeatures.map((feature, i) => (
              <FeatureRow key={feature.title} n={i + 1} feature={feature} index={i} />
            ))}
          </ol>
        </div>
      </section>

      {/* ── FAQ ── */}
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
              className="inline-flex items-center gap-1.5 rounded-full border border-line px-5 py-3 text-sm font-semibold transition-colors hover:border-accent hover:text-accent"
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
    <kbd className="inline-flex items-center rounded-md border border-accent-2/55 bg-accent-2/20 px-2 py-1 font-mono text-xs font-semibold leading-none text-accent-2">
      {children}
    </kbd>
  );
}

function PillarCard({ pillar }: { pillar: Pillar }) {
  return (
    <li className="flex h-full flex-col gap-4 rounded-xl border border-line/80 bg-surface/50 p-6 transition-colors hover:border-accent/50">
      <span className="inline-flex h-10 w-10 items-center justify-center rounded-lg border border-accent/30 bg-accent/10 text-accent">
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
    <figure className="rounded-xl border border-line/80 bg-surface/50 p-6 md:p-10">
      <div className="mx-auto flex max-w-md flex-col items-center">
        {/* Hub: your Mac */}
        <div className="w-full max-w-[15rem] rounded-lg border border-accent/45 bg-accent/10 px-5 py-4 text-center">
          <p className="font-mono text-[0.62rem] uppercase tracking-[0.16em] text-accent">
            Your Mac
          </p>
          <p className="mt-1 text-sm font-semibold tracking-tight text-foreground">
            One command surface
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
                <div className="w-full rounded-lg border border-line/80 bg-background/60 px-4 py-3 text-center">
                  <p className="text-sm font-semibold tracking-tight text-foreground">
                    {node.name}
                  </p>
                  <p className="mt-1 font-mono text-[0.62rem] uppercase tracking-[0.14em] text-foreground-soft">
                    {node.detail}
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
      className={`relative flex ${aspect} w-full items-center justify-center overflow-hidden rounded-xl border border-dashed border-line bg-surface/40`}
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

function ShortcutGroup({
  title,
  shortcuts,
}: {
  title: string;
  shortcuts: Shortcut[];
}) {
  return (
    <div>
      <h3 className="font-mono text-[0.7rem] uppercase tracking-[0.18em] text-foreground-soft">
        {title}
      </h3>
      <dl className="mt-4 divide-y divide-line/70 border-y border-line/70">
        {shortcuts.map((s) => (
          <div key={s.keys} className="flex items-center gap-4 py-3">
            <dt className="shrink-0">
              <Key>{s.keys}</Key>
            </dt>
            <dd className="text-sm leading-6 text-foreground-soft">{s.label}</dd>
          </div>
        ))}
      </dl>
    </div>
  );
}

function SpecItem({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <dt className="font-mono text-[0.62rem] uppercase tracking-[0.14em] text-foreground-soft">
        {label}
      </dt>
      <dd className="mt-1.5 whitespace-nowrap text-lg font-semibold tracking-tight tabular-nums md:text-xl">
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
