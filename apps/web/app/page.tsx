import Link from "next/link";
import { ParallelStackIllustration } from "./components/parallel-stack-illustration";
import { AppHeroPreview } from "./components/app-hero-preview";
import { SiteHeader } from "./components/site-header";
import { SiteFooter } from "./components/site-footer";

const githubReleasesURL = "https://github.com/yogesh-dhande/spaces/releases/latest";

type Feature = {
  title: string;
  description: string;
  span?: "wide" | "tall";
};

const keyFeatures: Feature[] = [
  {
    title: "Manager mode for coding agents",
    description:
      "See all your coding agents in one Alerts view. Know instantly which ones are working, which ones are waiting on you, and which ones are done. Jump to any agent with a keyboard shortcut.",
    span: "wide",
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
      "Let your coding agent leave a note about what it did, what's pending, or where things broke. Press cmd+shift+i on any window in the workspace to read it — the context is always one shortcut away.",
  },
  {
    title: "Launch and teardown on demand",
    description:
      "Close a workspace and Spaces shuts down its processes and closes its windows. Come back tomorrow, open it, and everything restarts exactly as it was.",
    span: "wide",
  },
  {
    title: "Native MacOS app under 5 MB",
    description:
      "Built with Swift and AppKit — not Electron. No 200MB runtime, no sluggish UI, no fan spinning up just to show you a window list. Spaces stays out of your way and off your CPU.",
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
        <li>
          <a
            href="https://github.com/koekeishiya/yabai"
            className="text-accent hover:underline"
          >
            yabai
          </a>{" "}
          — an open-source window manager used for window tracking and focus switching
        </li>
        <li>
          <a href="https://iterm2.com" className="text-accent hover:underline">
            iTerm2
          </a>
        </li>
        <li>
          <a
            href="https://github.com/tmux/tmux"
            className="text-accent hover:underline"
          >
            tmux
          </a>{" "}
          — used to back workspace terminal sessions
        </li>
      </ul>
    ),
  },
  {
    question: "What is yabai? Why does it need accessibility permissions?",
    answer: (
      <>
        <a
          href="https://github.com/koekeishiya/yabai"
          className="text-accent hover:underline"
        >
          yabai
        </a>{" "}
        is an open-source macOS window management utility. Spaces uses it to bring
        the right window to the front when you switch workspaces. macOS requires
        accessibility permissions before any app can programmatically control
        windows on behalf of other processes — yabai uses this to perform focus
        switching on Spaces&apos;s behalf.
      </>
    ),
  },
  {
    question: "Can I use it with CLI coding agents like Claude Code or Codex CLI?",
    answer: (
      <>
        Yes. Open a terminal inside any workspace with{" "}
        <kbd className="inline-flex items-center rounded border border-line bg-surface px-1.5 py-0.5 font-mono text-xs leading-none">
          ⌘⇧T
        </kbd>{" "}
        and start your agent as normal. The terminal window is automatically
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
    question: "I only work on one project at a time. How will Spaces help me?",
    answer: (
      <ul className="ml-4 list-disc space-y-1">
        <li>
          Spaces is still helpful in managing windows, monitoring processes,
          quickly spinning up or down projects
        </li>
        <li>
          You can leave other projects open and running without them getting in
          the way of the project you are focusing on.
        </li>
      </ul>
    ),
  },
  {
    question: "Do you collect any data?",
    answer: (
      <>
        No. Spaces is a native desktop app that runs entirely on your Mac. It does
        not send any data back to Spaces or any third party.
      </>
    ),
  },
  {
    question: "Where do I send bug reports?",
    answer: (
      <>
        Email{" "}
        <a href="mailto:support@spaces.dev" className="text-accent hover:underline">
          support@spaces.dev
        </a>
        .
      </>
    ),
  },
  {
    question: "What does Spaces mean?",
    answer: (
      <>
        Multiplex your work? Or something like that. I needed a name and a
        domain. You know how it goes.
      </>
    ),
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
    body: "Failed processes, failed checks, and agents waiting on a human all surface in one Alerts view.",
  },
];

export default function HomePage() {
  return (
    <div className="relative min-h-screen overflow-x-clip">
      <SiteHeader />

      {/* ── Hero ── */}
      <section className="relative">
        <div
          aria-hidden
          className="pointer-events-none absolute left-[-8rem] top-8 h-80 w-80 rounded-full bg-accent/16 blur-3xl"
        />
        <div
          aria-hidden
          className="pointer-events-none absolute right-[-6rem] top-0 h-72 w-72 rounded-full bg-accent/20 blur-3xl"
        />

        <div className="mx-auto grid w-full max-w-7xl grid-cols-1 items-center gap-10 px-6 pb-16 pt-16 md:pt-24 lg:grid-cols-12 lg:gap-12">
          <div className="lg:col-span-7">
            <p className="inline-flex items-center gap-2 font-mono text-[0.7rem] uppercase tracking-[0.18em] text-foreground-soft">
              <span className="h-1.5 w-1.5 rounded-full bg-accent" />
              Build faster with Spaces
            </p>
            <h1 className="mt-5 text-4xl font-semibold leading-[1.05] tracking-tight md:text-5xl lg:text-[3.75rem]">
              Instant context switching
              <br />
              <span className="text-foreground-soft">for faster development.</span>
            </h1>
            <p className="mt-6 max-w-xl text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              A MacOS app designed to reduce context hunting, app hopping, port
              conflicts, and accidental interruptions.
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
                href="#solution"
                className="inline-flex items-center gap-1.5 rounded-full px-5 py-3 text-sm font-semibold text-foreground-soft transition-colors hover:text-accent"
              >
                See how it works
                <span aria-hidden>→</span>
              </Link>
            </div>

            <dl className="mt-12 grid max-w-xl grid-cols-3 gap-4 border-t border-line/70 pt-6 text-left">
              <div>
                <dt className="font-mono text-[0.62rem] uppercase tracking-[0.14em] text-foreground-soft">
                  Size
                </dt>
                <dd className="mt-1 text-lg font-semibold tracking-tight">&lt; 5 MB</dd>
              </div>
              <div>
                <dt className="font-mono text-[0.62rem] uppercase tracking-[0.14em] text-foreground-soft">
                  Runtime
                </dt>
                <dd className="mt-1 text-lg font-semibold tracking-tight">Native Swift</dd>
              </div>
              <div>
                <dt className="font-mono text-[0.62rem] uppercase tracking-[0.14em] text-foreground-soft">
                  Price
                </dt>
                <dd className="mt-1 text-lg font-semibold tracking-tight">Free</dd>
              </div>
            </dl>
          </div>

          <div className="lg:col-span-5">
            <div className="rounded-[1.8rem] border border-line/80 bg-surface/70 p-3 shadow-[0_30px_80px_-40px_color-mix(in_oklab,var(--ink)_55%,transparent)] backdrop-blur-sm">
              <ParallelStackIllustration />
            </div>
          </div>
        </div>
      </section>

      {/* ── Problem band ── */}
      <section id="problem" className="border-y border-line/70 bg-background-soft/60">
        <div className="mx-auto w-full max-w-7xl px-6 py-20">
          <div className="mx-auto max-w-3xl text-center">
            <p className="font-mono text-[0.7rem] uppercase tracking-[0.18em] text-foreground-soft">
              The Problem
            </p>
            <h2 className="mt-4 text-3xl font-semibold leading-tight tracking-tight md:text-5xl">
              Speed is no longer about typing code faster.
            </h2>
            <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              The bottleneck moved. It&apos;s not the code — it&apos;s
              everything around the code: the workspaces, the ports, the
              windows, the branches, the agents. Managing that is the job now.
            </p>
          </div>

          <div className="mt-12 grid gap-6 md:grid-cols-3">
            <ProblemCard
              n="01"
              title="Context scattered across surfaces"
              body="A single feature lives across four terminal tabs, two editor windows, and a browser session — with nothing connecting them. Coming back after lunch means reconstructing where you were from clues."
            />
            <ProblemCard
              n="02"
              title="Every switch is a scavenger hunt"
              body="You&rsquo;re hunting for the checkout tab across 80 open tabs in two browser windows. The dev server is running somewhere — you just can't remember which terminal. Port 3000 is taken and you don&rsquo;t know by what."
            />
            <ProblemCard
              n="03"
              title="Worktrees make it worse"
              body="You spin up a worktree so a PR review doesn&rsquo;t kill your dev server — now you have two sets of windows to track and both want port 3000. Multiply by three projects and the desktop becomes the problem."
            />
          </div>
        </div>
      </section>

      {/* ── Introducing Spaces ── */}
      <section className="mx-auto w-full max-w-7xl px-6 py-20 md:py-28">
        <div className="mx-auto max-w-3xl text-center">
          <p className="font-mono text-[0.7rem] uppercase tracking-[0.18em] text-foreground-soft">
            Introducing Spaces
          </p>
          <h2 className="mt-4 text-3xl font-semibold leading-tight tracking-tight md:text-5xl">
            The command center for parallel development.
          </h2>
          <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
            Spaces groups the tabs, terminals, editors, and agents for each task
            into a workspace you can open, switch, and close as one unit. Move
            between projects and features without losing your place — or
            colliding with yourself.
          </p>
        </div>

        <div className="mt-12 grid gap-6 md:grid-cols-2">
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
      </section>

      {/* ── How It Works ── */}
      <section
        id="solution"
        className="border-y border-line/70 bg-background-soft/60"
      >
        <div className="mx-auto w-full max-w-7xl px-6 py-20">
          <div className="mx-auto max-w-3xl text-center">
            <p className="font-mono text-[0.7rem] uppercase tracking-[0.18em] text-foreground-soft">
              How It Works
            </p>
            <h2 className="mt-4 text-3xl font-semibold leading-tight tracking-tight md:text-5xl">
              Three primitives. One mental model.
            </h2>
            <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              Spaces works the way you already think about coding — projects
              contain tasks, tasks have their own windows and state. It just
              makes those layers real.
            </p>
          </div>

          <div className="mx-auto mt-12 max-w-3xl">
            <article className="rounded-3xl border border-line/80 bg-surface/90 p-5 shadow-[0_30px_80px_-50px_color-mix(in_oklab,var(--ink)_55%,transparent)] md:p-7">
              <LayerHeader step="01" label="Project" icon="▤" />
              <p className="mt-3 text-sm leading-6 text-foreground-soft md:text-base md:leading-7">
                Point Spaces at a repo. Define your setup script, named ports,
                browser URLs, and the processes you run. Do this once.
              </p>
              <div className="mt-5 rounded-2xl border border-line/80 bg-background-soft/70 p-5 md:p-6">
                <LayerHeader step="02" label="Workspace" icon="◫" />
                <p className="mt-3 text-sm leading-6 text-foreground-soft md:text-base md:leading-7">
                  Create a workspace for each feature, branch, or experiment.
                  Each one gets its own directory, ports, env, and processes — isolated
                  from the rest. Create as many as you need.
                </p>
                <div className="mt-5 rounded-xl border border-line/80 bg-surface/90 p-4 md:p-5">
                  <LayerHeader step="03" label="Runtime" icon="▦" />
                  <p className="mt-3 text-sm leading-6 text-foreground-soft md:text-base md:leading-7">
                    With one click, start all the processes and open browser URLs of a workspace.
                    Spaces manages the runtime environment, windows, and monitors coding agents. 
                    You can jump to any workspace window or cycle between windows of the current workspace 
                    using keyboard shortcuts.
                  </p>
                </div>
              </div>
            </article>
          </div>
        </div>
      </section>

      {/* ── In Action ── */}
      <section className="mx-auto w-full max-w-7xl px-6 py-20 md:py-28">
        <div className="mx-auto max-w-3xl text-center">
          <p className="font-mono text-[0.7rem] uppercase tracking-[0.18em] text-foreground-soft">
            In Action
          </p>
          <h2 className="mt-4 text-3xl font-semibold leading-tight tracking-tight md:text-5xl">
            A repeatable loop, not a window hunt.
          </h2>
          <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
            Workspace boundaries stay clear. Switching between them stays fast.
          </p>
        </div>

        <div className="mt-12 rounded-3xl border border-line/80 bg-surface/70 p-3 shadow-[0_40px_80px_-50px_color-mix(in_oklab,var(--ink)_55%,transparent)] md:p-5">
          <AppHeroPreview />
        </div>
      </section>

      {/* ── Features bento ── */}
      <section
        id="features"
        className="border-y border-line/70 bg-background-soft/60"
      >
        <div className="mx-auto w-full max-w-7xl px-6 py-20 md:py-24">
          <div className="mx-auto max-w-3xl text-center">
            <p className="font-mono text-[0.7rem] uppercase tracking-[0.18em] text-foreground-soft">
              Key Features
            </p>
            <h2 className="mt-4 text-3xl font-semibold leading-tight tracking-tight md:text-5xl">
              Your whole dev loop, in one place
            </h2>
            <p className="mt-5 text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
              Spaces turns the scattered terminals, tabs, editors, agents, and worktrees into logical workspaces you can open, switch, and close as one.
            </p>
          </div>

          <div className="mt-12 grid auto-rows-[1fr] grid-flow-dense gap-4 md:grid-cols-6">
            {keyFeatures.map((feature) => (
              <FeatureCard key={feature.title} feature={feature} />
            ))}
          </div>
        </div>
      </section>

      {/* ── FAQ ── */}
      <section id="faq" className="mx-auto w-full max-w-7xl px-6 py-20 md:py-28">
        <div className="mx-auto max-w-3xl text-center">
          <p className="font-mono text-[0.7rem] uppercase tracking-[0.18em] text-foreground-soft">
            FAQ
          </p>
          <h2 className="mt-4 text-3xl font-semibold leading-tight tracking-tight md:text-5xl">
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

        <div className="mx-auto mt-12 max-w-3xl">
          <dl className="divide-y divide-line/70 border-y border-line/70">
            {faqItems.map((item) => (
              <details key={item.question} className="group py-2">
                <summary className="flex cursor-pointer select-none list-none items-center justify-between py-3 text-base font-semibold text-foreground md:text-lg">
                  {item.question}
                  <span
                    aria-hidden
                    className="ml-4 shrink-0 font-mono text-xs text-foreground-soft transition-transform duration-200 group-open:rotate-45"
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
      </section>

      {/* ── CTA ── */}
      <section className="mx-auto w-full max-w-7xl px-6 pb-24">
        <div className="relative overflow-hidden rounded-3xl border border-line/80 bg-surface/80 px-8 py-16 text-center md:px-16 md:py-20">
          <div
            aria-hidden
            className="pointer-events-none absolute left-1/2 top-0 h-64 w-[40rem] -translate-x-1/2 rounded-full bg-accent/18 blur-3xl"
          />
          <div
            aria-hidden
            className="pointer-events-none absolute -bottom-20 left-1/2 h-48 w-[30rem] -translate-x-1/2 rounded-full bg-accent/14 blur-3xl"
          />
          <div className="relative">
            <p className="font-mono text-[0.7rem] uppercase tracking-[0.18em] text-foreground-soft">
              Ready to build faster?
            </p>
            <h2 className="mt-4 text-3xl font-semibold tracking-tight md:text-5xl">
              Stop hunting. Start shipping.
            </h2>
            <p className="mx-auto mt-4 max-w-2xl text-base leading-7 text-foreground-soft md:text-lg">
              Spaces helps you build faster by managing context and reducing
              chaos.
            </p>
            <div className="mt-8 flex flex-wrap justify-center gap-3">
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
        </div>
      </section>

      <SiteFooter />
    </div>
  );
}

type ProblemCardProps = {
  n: string;
  title: string;
  body: string;
};

function ProblemCard({ n, title, body }: ProblemCardProps) {
  return (
    <article className="flex flex-col gap-3 rounded-2xl border border-line/80 bg-surface/80 p-5">
      <span className="font-mono text-[0.62rem] uppercase tracking-[0.18em] text-foreground-soft">
        {n}
      </span>
      <h3 className="text-lg font-semibold leading-snug tracking-tight">
        {title}
      </h3>
      <p className="text-sm leading-6 text-foreground-soft">{body}</p>
    </article>
  );
}

type FeatureCardProps = {
  feature: Feature;
};

type LayerHeaderProps = {
  step: string;
  label: string;
  icon: string;
};

function LayerHeader({ step, label, icon }: LayerHeaderProps) {
  return (
    <div className="flex items-center gap-3">
      <span
        aria-hidden
        className="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-lg border border-line/80 bg-background-soft/80 font-mono text-sm text-accent"
      >
        {icon}
      </span>
      <div className="flex min-w-0 flex-col">
        <span className="font-mono text-[0.62rem] uppercase tracking-[0.18em] text-accent">
          Step {step}
        </span>
        <span className="text-lg font-semibold tracking-tight md:text-xl">
          {label}
        </span>
      </div>
    </div>
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
    ? "border-accent/40 bg-surface/90 shadow-[0_30px_80px_-50px_color-mix(in_oklab,var(--accent)_50%,transparent)]"
    : "border-[#ff6f5b]/40 bg-[color:color-mix(in_oklab,#ff6f5b_6%,var(--surface))]";
  const eyebrowClasses = isWith ? "text-accent" : "text-[#ff6f5b]";
  const dotClasses = isWith ? "bg-accent" : "bg-[#ff6f5b]";
  const numberClasses = isWith
    ? "border-accent/40 bg-accent/10 text-accent"
    : "border-[#ff6f5b]/40 bg-[color:color-mix(in_oklab,#ff6f5b_10%,transparent)] text-[#ff6f5b]";
  const resultClasses = isWith ? "text-foreground" : "text-foreground-soft";

  return (
    <article
      className={`flex flex-col gap-6 rounded-2xl border p-6 md:p-8 ${containerClasses}`}
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
              className={`inline-flex h-7 w-7 shrink-0 items-center justify-center rounded-full border font-mono text-xs font-semibold ${numberClasses}`}
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

function FeatureCard({ feature }: FeatureCardProps) {
  const span = feature.span === "wide" ? "md:col-span-4" : "md:col-span-2";

  return (
    <article
      className={`group relative flex flex-col gap-2 rounded-2xl border border-line/80 bg-surface/80 p-6 transition-colors hover:border-accent/60 ${span}`}
    >
      <h3 className="text-base font-semibold tracking-tight md:text-[1.05rem]">
        {feature.title}
      </h3>
      <p className="text-sm leading-6 text-foreground-soft">
        {feature.description}
      </p>
    </article>
  );
}
