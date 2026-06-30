/* Hallmark · macrostructure: Workbench · genre: modern-minimal · tone: technical/precise · anchor hue: teal (brand) + amber (status/keys) */
import Link from "next/link";
import { SiteHeader } from "./components/site-header";
import { SiteFooter } from "./components/site-footer";

const githubReleasesURL = "https://github.com/yogesh-dhande/spaces/releases/latest";

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
    title: "Reserved ports per workspace",
    description:
      "Each workspace owns its ports, exposed as named environment variables like $FRONTEND_PORT and $BACKEND_PORT. Run three instances of your app side by side — no conflicts, no `.env` edits.",
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
    title: "Move between Mac and iPhone",
    description:
      "Pair the Spaces iOS app and your terminal sessions come with you. Pick up the same live session on your phone — watch a build, check a coding agent, or send a command — then step back to your Mac without losing your place.",
  },
  {
    title: "Launch and teardown on demand",
    description:
      "Close a workspace and Spaces shuts down its processes and closes its windows. Come back tomorrow, open it, and everything restarts exactly as it was.",
  },
  {
    title: "Native MacOS app under 10 MB",
    description:
      "Built with Swift and AppKit — not Electron. No 200 MB runtime, no sluggish UI, no fan spinning up just to show you a window list.",
  },
];

type Shortcut = {
  keys: string;
  label: string;
};

// Accurate shortcuts mirror /docs/shortcuts. Leader (⌘⌥) is configurable.
const navigateShortcuts: Shortcut[] = [
  { keys: "⌘⌥-", label: "Open the command palette" },
  { keys: "⌘1–9", label: "Focus a workspace window by number" },
  { keys: "⌘⌥]", label: "Next window — cycles workspaces when Spaces is frontmost" },
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
        <li>Spaces ships its own terminal, so workspaces do not depend on external terminal apps.</li>
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
    question: "I only work on one project at a time. Will Spaces help me?",
    answer: (
      <ul className="ml-4 list-disc space-y-1">
        <li>
          Yes. A workspace starts every process on its reserved ports in one
          action, so spinning a project up or down takes no manual server
          juggling or <code>.env</code> edits.
        </li>
        <li>
          Tear a workspace down when you&apos;re done and reopen it later exactly
          as you left it — windows, processes, and all.
        </li>
        <li>
          When you do branch off for a fix or experiment, it gets its own
          isolated workspace without disturbing your main work.
        </li>
      </ul>
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
            Spaces opens a dedicated window for every tab, terminal, and
            editor instance so you can lay them out across your screens and
            recall them on demand. The upside is speed and flexibility —
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
        a coding agent&apos;s output, and relaunch the Mac app if it quits while
        you&apos;re away. See the{" "}
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
        No. Spaces runs entirely on your Mac and does not send your data to Spaces
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

type ProblemItem = {
  n: string;
  title: string;
  body: string;
};

const problems: ProblemItem[] = [
  {
    n: "01",
    title: "Context scattered across surfaces",
    body: "A single feature lives across four terminal tabs, two editor windows, and a browser session — with nothing connecting them. Coming back after lunch means reconstructing where you were from clues.",
  },
  {
    n: "02",
    title: "Every switch is a scavenger hunt",
    body: "You’re hunting for the checkout tab across 80 open tabs in two browser windows. The dev server is running somewhere — you just can't remember which terminal. Port 3000 is taken and you don’t know by what.",
  },
  {
    n: "03",
    title: "Worktrees make it worse",
    body: "You spin up a worktree so a PR review doesn’t kill your dev server — now you have two sets of windows to track and both want port 3000. Multiply by three projects and the desktop becomes the problem.",
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
    body: "Point Spaces at a repo. Define your setup script, named ports, browser URLs, and the processes you run. Do this once.",
  },
  {
    n: "02",
    label: "Workspace",
    body: "Create a workspace for each feature, branch, or experiment. Each one gets its own directory, ports, env, and processes — isolated from the rest. Create as many as you need.",
  },
  {
    n: "03",
    label: "Runtime",
    body: "With one click, start every process and open the browser URLs for a workspace. Spaces manages the windows and monitors coding agents. Jump to any window — or cycle through the current workspace — with keyboard shortcuts.",
  },
];

type ComparisonStep = {
  n: string;
  title: string;
  body: string;
};

const withoutSpaces: ComparisonStep[] = [
  {
    n: "1",
    title: "Find the tab",
    body: "Dig through 80 open tabs across two browser windows for the checkout page.",
  },
  {
    n: "2",
    title: "Find the editor",
    body: "Alt-tab through four VS Code windows to find the one on the right branch.",
  },
  {
    n: "3",
    title: "Find the agent",
    body: "Click through three terminals to figure out which one has the agent waiting on you.",
  },
  {
    n: "4",
    title: "Fix the port",
    body: "Realize :3000 is taken by last week's project. Kill something. Update the env file. Restart.",
  },
];

const withSpaces: ComparisonStep[] = [
  {
    n: "1",
    title: "Open the workspace",
    body: "One shortcut brings up every window for this task — tabs, terminals, editor, agent — exactly where you left them.",
  },
  {
    n: "2",
    title: "Jump between windows",
    body: "Numbered shortcuts focus any window in the workspace instantly. No hunting, no alt-tab.",
  },
  {
    n: "3",
    title: "Switch projects without cleanup",
    body: "Each workspace owns its own ports and env. Spin up a worktree alongside your main branch — both run, neither breaks.",
  },
  {
    n: "4",
    title: "See what needs you",
    body: "Exited processes and agents waiting on a human all surface in one Alerts view.",
  },
];

export default function HomePage() {
  return (
    <div className="lp relative min-h-screen overflow-x-clip">
      <SiteHeader />

      {/* ── Hero ── */}
      <section className="relative">
        <div className="mx-auto w-full max-w-7xl px-6 pt-14 md:pt-20">
          <div className="max-w-3xl">
            <p className="inline-flex items-center gap-2 font-mono text-[0.7rem] uppercase tracking-[0.18em] text-foreground-soft">
              <span className="h-1.5 w-1.5 rounded-full bg-accent" />
              macOS · open source
            </p>
            <h1 className="mt-5 text-5xl font-semibold leading-[1.02] tracking-tight md:text-6xl lg:text-[4.5rem]">
              Multiplex work
              <br />
              <span className="text-accent">Not just the terminal</span>
            </h1>
            <p className="mt-6 max-w-xl text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              Native macOS app and CLI for orchestrating parallel coding
              sessions across worktrees, branches, and projects. Each
              workspace gets isolated ports, environment, and a tracked
              window set.
            </p>
            <div className="mt-8 flex flex-wrap items-center gap-3">
              <Link
                href={githubReleasesURL}
                className="btn-primary inline-flex items-center gap-2 rounded-full px-6 py-3 text-sm font-semibold"
                target="_blank"
                rel="noopener noreferrer"
              >
                Download
              </Link>
              <Link
                href="#tour"
                className="inline-flex items-center gap-1.5 px-1 py-3 text-sm font-semibold text-foreground-soft transition-colors hover:text-accent"
              >
                See how it works
                <span aria-hidden>→</span>
              </Link>
            </div>

            <p className="mt-7 flex flex-wrap items-center gap-x-2.5 gap-y-2 text-sm text-foreground-soft">
              <span>Jump to any window with</span>
              <Key>⌘⌥-</Key>
              <span className="text-line">·</span>
              <span>focus by number</span>
              <Key>⌘1–9</Key>
            </p>
          </div>
        </div>

        <div className="mx-auto mt-12 w-full max-w-7xl px-6 md:mt-16">
          <figure className="relative overflow-hidden rounded-xl border border-line/80 bg-surface/70 shadow-[0_40px_100px_-60px_color-mix(in_oklab,var(--ink)_55%,transparent)]">
            <img
              src="/media/hero2.png"
              alt="The Spaces app showing workspaces, terminals, editors, and live agent status side by side"
              className="h-auto w-full"
              fetchPriority="high"
            />
          </figure>
          <dl className="mt-10 grid max-w-3xl grid-cols-3 gap-6 border-t border-line/70 pt-7">
            <SpecItem label="Size" value="< 10 MB" />
            <SpecItem label="Runtime" value="Native Swift" />
            <SpecItem label="Price" value="Free" />
          </dl>
        </div>
      </section>

      {/* ── Problem ── */}
      <section id="problem" className="mt-24 border-t border-line/70">
        <div className="mx-auto w-full max-w-7xl px-6 py-20">
          <div className="max-w-3xl">
            <h2 className="text-3xl font-semibold leading-tight tracking-tight md:text-5xl">
              Speed is no longer about{" "}
              <span className="text-accent">typing code faster.</span>
            </h2>
            <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              The bottleneck isn&apos;t typing — it&apos;s the surrounding
              state: which terminal owns the dev server, which Chrome tab is
              the staging admin, which worktree is bound to port 3000, which
              agent is waiting on you. Managing that is the job now.
            </p>
          </div>

          <ol className="mt-14 grid border-t border-line/70 md:grid-cols-3">
            {problems.map((p, i) => (
              <li
                key={p.n}
                className={`flex flex-col gap-3 border-b border-line/70 py-8 md:border-b-0 md:py-0 md:pt-8 ${
                  i === 0 ? "md:pr-8" : "md:px-8"
                } ${i > 0 ? "md:border-l md:border-line/70" : ""}`}
              >
                <span className="font-mono text-xs tracking-[0.18em] text-accent tabular-nums">
                  {p.n}
                </span>
                <h3 className="text-lg font-semibold leading-snug tracking-tight">
                  {p.title}
                </h3>
                <p className="text-sm leading-6 text-foreground-soft">{p.body}</p>
              </li>
            ))}
          </ol>
        </div>
      </section>

      {/* ── How a workspace works (comparison) ── */}
      <section className="border-t border-line/70 bg-background-soft/40">
        <div className="mx-auto w-full max-w-7xl px-6 py-24">
          <div className="max-w-3xl">
            <h2 className="text-3xl font-semibold leading-tight tracking-tight md:text-5xl">
              One workspace per task.{" "}
              <span className="text-accent">Open, switch, and close as a unit.</span>
            </h2>
            <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              A workspace is one feature, branch, or experiment with its own
              directory, named ports, processes, browser sessions, and
              coding-agent terminals. Launching it starts every process and
              tracks every window. Stopping it shuts everything down. Reopening
              restores the state.
            </p>
          </div>

          <div className="mt-12 grid gap-5 md:grid-cols-2">
            <ComparisonColumn
              variant="without"
              eyebrow="Without Spaces"
              steps={withoutSpaces}
              result="ten minutes of setup before you've typed a line of code."
            />
            <ComparisonColumn
              variant="with"
              eyebrow="With Spaces"
              steps={withSpaces}
              result="you're coding, not context-switching."
            />
          </div>
        </div>
      </section>

      {/* ── How It Works (timeline) ── */}
      <section id="tour" className="border-t border-line/70">
        <div className="mx-auto w-full max-w-7xl px-6 py-20 md:py-24">
          <div className="max-w-3xl">
            <h2 className="text-3xl font-semibold leading-tight tracking-tight md:text-5xl">
              Project, workspace, <span className="text-accent">runtime.</span>
            </h2>
            <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              Configure each repo once at the project level. Create one
              workspace per task. Runtime opens or closes processes and
              windows as a unit.
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
                    <span
                      aria-hidden
                      className="mt-2 w-px flex-1 bg-line/70"
                    />
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

      {/* ── Built for the keyboard ── */}
      <section className="border-t border-line/70 bg-background-soft/60">
        <div className="mx-auto w-full max-w-7xl px-6 py-24">
          <div className="max-w-3xl">
            <h2 className="text-3xl font-semibold leading-tight tracking-tight md:text-5xl">
              Built for <span className="text-accent">the keyboard.</span>
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
      <section className="border-t border-line/70">
        <div className="mx-auto w-full max-w-7xl px-6 py-24">
          <div className="max-w-3xl">
            <h2 className="text-3xl font-semibold leading-tight tracking-tight md:text-5xl">
              Get to any window with{" "}
              <span className="text-accent">a few keystrokes</span>
            </h2>
            <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              Numbered shortcuts focus any window in the active workspace.
              Cycle through windows of the same workspace, or use the
              global command palette to pull any window across any workspace.
            </p>
            <p className="mt-6 flex flex-wrap items-center gap-x-2.5 gap-y-2 text-sm text-foreground-soft">
              <Key>⌘1–9</Key>
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
      <section id="features" className="border-t border-line/70 bg-background-soft/40">
        <div className="mx-auto w-full max-w-7xl px-6 py-20 md:py-24">
          <div className="flex flex-col gap-2 md:flex-row md:items-end md:justify-between">
            <h2 className="text-3xl font-semibold leading-tight tracking-tight md:text-5xl">
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
      <section id="faq" className="border-t border-line/70">
        <div className="mx-auto w-full max-w-7xl px-6 py-20 md:py-24">
          <div className="max-w-3xl">
            <h2 className="text-3xl font-semibold leading-tight tracking-tight md:text-5xl">
              You may be wondering.
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
      <section className="border-t border-line/70 bg-background-soft/40">
        <div className="mx-auto w-full max-w-7xl px-6 py-24 md:py-28">
          <h2 className="max-w-2xl text-3xl font-semibold leading-tight tracking-tight md:text-5xl">
            Try it on <span className="text-accent">your repo.</span>
          </h2>
          <p className="mt-4 max-w-2xl text-base leading-7 text-foreground-soft md:text-lg">
            Native macOS, signed DMG, in-app updates via Sparkle. Free and
            open source.
          </p>
          <div className="mt-8 flex flex-wrap gap-3">
            <Link
              href={githubReleasesURL}
              className="btn-primary inline-flex items-center gap-2 rounded-full px-6 py-3 text-sm font-semibold"
              target="_blank"
              rel="noopener noreferrer"
            >
              Download
            </Link>
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
      <dd className="mt-1.5 text-xl font-semibold tracking-tight tabular-nums md:text-2xl">
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

type ComparisonColumnProps = {
  variant: "without" | "with";
  eyebrow: string;
  steps: ComparisonStep[];
  result: string;
};

function ComparisonColumn({
  variant,
  eyebrow,
  steps,
  result,
}: ComparisonColumnProps) {
  const isWith = variant === "with";
  const containerClasses = isWith
    ? "border-accent/40 bg-surface/85"
    : "border-negative/40 bg-[color:color-mix(in_oklab,var(--negative)_7%,var(--surface))]";
  const eyebrowClasses = isWith ? "text-accent" : "text-negative";
  const dotClasses = isWith ? "bg-accent" : "bg-negative";
  const numberClasses = isWith
    ? "border-accent/40 bg-accent/10 text-accent"
    : "border-negative/40 bg-[color:color-mix(in_oklab,var(--negative)_12%,transparent)] text-negative";
  const resultClasses = isWith ? "text-foreground" : "text-foreground-soft";

  return (
    <article
      className={`flex flex-col gap-6 rounded-lg border p-6 md:p-8 ${containerClasses}`}
    >
      <p
        className={`inline-flex items-center gap-2 font-mono text-[0.7rem] uppercase tracking-[0.18em] ${eyebrowClasses}`}
      >
        <span className={`h-1.5 w-1.5 rounded-full ${dotClasses}`} />
        {eyebrow}
      </p>
      <ol className="flex flex-col gap-5">
        {steps.map((step) => (
          <li key={step.n} className="flex gap-4">
            <span
              className={`inline-flex h-7 w-7 shrink-0 items-center justify-center rounded-full border font-mono text-xs font-semibold tabular-nums ${numberClasses}`}
            >
              {step.n}
            </span>
            <div className="min-w-0">
              <p className="text-sm font-semibold tracking-tight text-foreground md:text-base">
                {step.title}
              </p>
              <p className="mt-1 text-sm leading-6 text-foreground-soft">
                {step.body}
              </p>
            </div>
          </li>
        ))}
      </ol>
      <p
        className={`mt-auto border-t border-line/70 pt-4 text-sm leading-6 ${resultClasses}`}
      >
        <span className="font-mono text-[0.62rem] uppercase tracking-[0.18em] text-foreground-soft">
          Result
        </span>
        <span className="ml-2">{result}</span>
      </p>
    </article>
  );
}
