import Link from "next/link";
import { ParallelStackIllustration } from "./components/parallel-stack-illustration";
import { AppHeroPreview } from "./components/app-hero-preview";

import { ProblemSimulation } from "./components/problem-simulation";
import { SiteHeader } from "./components/site-header";


const keyFeatures = [
  {
    title: "Manage Git worktrees",
    description:
      "Create and run isolated workspace directories per branch so parallel feature work does not collide.",
  },
  {
    title: "Reserved ports per worktree",
    description:
      "Each workspace gets reserved ports so local services can run side by side without recurring port conflicts.",
  },
  {
    title: "Switch between workspaces with ease",
    description:
      "Jump between active workstreams quickly without rebuilding process, browser, and editor context.",
  },
  {
    title: "Switch between windows of the current workspace",
    description:
      "Cycle through the current workspace windows with deterministic shortcuts, instead of hunting across apps.",
  },
  {
    title: "Workspace context tooltips",
    description:
      "Add optional tooltips to workspaces describing what you're working on. Press cmd+shift+i to display the tooltip for the focused workspace as an overlay.",
  },
  {
    title: "Start and stop workspaces quickly",
    description:
      "No need to keep those tabs open or processes running just because it is a pain to set all of it up again. Muxy manages starting and stopping for you automatically.",
  },
  {
    title: "Bring your own tools",
    description:
      "Muxy works with your preferred stack, whether it is Claude Code or Codex, Cursor or Windsurf. You do not need to learn a new tool or settle for a weaker coding agent just for UX.",
  },
];

export default function HomePage() {
  return (
    <div className="relative min-h-screen overflow-x-clip">
      <div
        aria-hidden
        className="pointer-events-none absolute left-[-10rem] top-20 h-72 w-72 rounded-full bg-accent/16 blur-3xl"
      />
      <div
        aria-hidden
        className="pointer-events-none absolute right-[-8rem] top-10 h-64 w-64 rounded-full bg-accent/24 blur-3xl"
      />

      <SiteHeader />

      <main className="mx-auto flex w-full max-w-6xl flex-col gap-6 px-6 pb-20">

        {/* ── Hero ── */}
        <section className="grid gap-7 rounded-3xl border border-line bg-surface/90 p-7 shadow-[0_24px_48px_-34px_color-mix(in_oklab,var(--ink)_45%,transparent)] backdrop-blur-sm md:grid-cols-[1.1fr_0.9fr] md:p-9">
          <div className="space-y-5">
            <p className="inline-flex rounded-full border border-line bg-background-soft px-3 py-1 font-mono text-[0.68rem] uppercase tracking-[0.14em] text-foreground-soft">
              Parallel Development, Managed
            </p>
            <h1 className="max-w-2xl text-3xl font-semibold leading-tight tracking-tight md:text-5xl">
              Multiplex development.<br />Without losing focus.
            </h1>
            <p className="max-w-2xl text-base leading-7 text-foreground-soft md:text-lg">
              Muxy launches isolated development contexts, each with its
              own workspace, windows, terminals, ports, agents, and environment.
              And lets you move between them instantly.
            </p>
            <div className="flex flex-wrap gap-3">
              <Link
                href="/releases/latest"
                className="btn-primary rounded-full px-5 py-2.5 text-sm font-semibold transition-colors cursor-pointer"
              >
                Download
              </Link>
              <Link
                href="#solution"
                className="rounded-full border border-line px-5 py-2.5 text-sm font-semibold transition-colors hover:border-accent hover:text-accent"
              >
                See How It Works
              </Link>

            </div>
          </div>
          <ParallelStackIllustration />
        </section>

        {/* ── Problem: The Shift ── */}
        <section
          id="problem"
          className="rounded-3xl border border-line bg-surface/86 p-7 backdrop-blur-sm md:p-8"
        >
          <p className="font-mono text-xs uppercase tracking-[0.16em] text-foreground-soft">
            The Problem
          </p>
          <h2 className="mt-3 text-3xl font-semibold tracking-tight">
            Modern development is no longer linear
          </h2>
          <div className="mt-5 max-w-3xl space-y-4 text-sm leading-6 text-foreground-soft md:text-base md:leading-7">
            <p>
              Agents run tasks. Servers live in terminals. Features evolve in
              parallel.
            </p>
            <p>
              But our tools still assume we work on one thing at a time.
            </p>
          </div>
        </section>

        {/* ── Problem: The Friction ── */}
        <section className="rounded-3xl border border-line bg-surface/86 p-7 backdrop-blur-sm md:p-8">
          <p className="font-mono text-xs uppercase tracking-[0.16em] text-foreground-soft">
            What That Looks Like
          </p>
          <h2 className="mt-3 text-2xl font-semibold tracking-tight">
            Context gets scattered, then lost
          </h2>
          <div className="mt-5 max-w-3xl space-y-4 text-sm leading-6 text-foreground-soft md:text-base md:leading-7">
            <p>
              A single feature ends up scattered across terminal tabs, editor
              windows, and browser sessions — with no shared structure tying
              them together.
            </p>
            <p>
              Switching apps often lands you on the wrong window. Tracing a UI
              bug becomes a reverse lookup exercise: from page → repo →
              terminal → agent.
            </p>
            <p>Meanwhile, small frictions compound:</p>
            <ul className="ml-5 space-y-1.5 text-sm leading-6">
              <li>• Port collisions quietly break local flows</li>
              <li>• Context switching erodes focus</li>
              <li>• Active work disappears into window chaos</li>
            </ul>
            <p className="font-medium text-foreground">
              The more parallel your workflow becomes, the more your environment
              fights you.
            </p>
          </div>
        </section>

        {/* ── Problem: Visualized ── */}
        <section className="rounded-3xl border border-line bg-surface/86 p-7 backdrop-blur-sm md:p-8">
          <p className="font-mono text-xs uppercase tracking-[0.16em] text-foreground-soft">
            Side by Side
          </p>
          <h2 className="mt-3 text-2xl font-semibold tracking-tight">
            Where time actually goes
          </h2>
          <p className="mt-3 max-w-3xl text-sm leading-6 text-foreground-soft md:text-base md:leading-7">
            Fragmented windows and ports vs. Muxy&apos;s workspace-first
            model.
          </p>
          <div className="mt-6">
            <ProblemSimulation />
          </div>
        </section>

        {/* ── How It Works ── */}
        <section
          id="solution"
          className="rounded-3xl border border-line bg-surface/86 p-7 backdrop-blur-sm md:p-8"
        >
          <p className="font-mono text-xs uppercase tracking-[0.16em] text-foreground-soft">
            How It Works
          </p>
          <h2 className="mt-3 text-3xl font-semibold tracking-tight">
            Three steps, one loop
          </h2>
          <p className="mt-3 max-w-3xl text-sm leading-6 text-foreground-soft md:text-base md:leading-7">
            Muxy organizes parallel work around workspaces, then lets you
            move through them with predictable shortcuts.
          </p>
          <div className="mt-6 grid gap-4 md:grid-cols-3">
            <article className="rounded-2xl border border-line bg-surface/75 p-5">
              <p className="font-mono text-xs uppercase tracking-[0.12em] text-foreground-soft">
                01 Select
              </p>
              <p className="mt-2 text-sm leading-6 text-foreground-soft">
                Choose the workspace tied to the feature or branch you need to
                check in on.
              </p>
            </article>
            <article className="rounded-2xl border border-line bg-surface/75 p-5">
              <p className="font-mono text-xs uppercase tracking-[0.12em] text-foreground-soft">
                02 Jump
              </p>
              <p className="mt-2 text-sm leading-6 text-foreground-soft">
                Open the right browser, editor, or terminal window for that
                workspace instantly with a keyboard shortcut.
              </p>
            </article>
            <article className="rounded-2xl border border-line bg-surface/75 p-5">
              <p className="font-mono text-xs uppercase tracking-[0.12em] text-foreground-soft">
                03 Continue
              </p>
              <p className="mt-2 text-sm leading-6 text-foreground-soft">
                Cycle through only the windows of that workspace with keyboard
                shortcuts.
              </p>
            </article>
          </div>
        </section>

        {/* ── App Preview ── */}
        <section className="rounded-3xl border border-line bg-surface/86 p-7 backdrop-blur-sm md:p-8">
          <p className="font-mono text-xs uppercase tracking-[0.16em] text-foreground-soft">
            In Action
          </p>
          <h2 className="mt-3 text-2xl font-semibold tracking-tight">
            A repeatable loop, not a window hunt
          </h2>
          <p className="mt-3 max-w-3xl text-sm leading-6 text-foreground-soft md:text-base md:leading-7">
            Workspace boundaries stay clear. Switching between them stays fast.
          </p>
          <div className="mt-6">
            <AppHeroPreview />
          </div>
        </section>

        {/* ── Features ── */}
        <section className="rounded-3xl border border-line bg-surface/86 p-7 backdrop-blur-sm md:p-8">
          <p className="font-mono text-xs uppercase tracking-[0.16em] text-foreground-soft">
            Key Features
          </p>
          <h2 className="mt-3 text-3xl font-semibold tracking-tight">
            Built for parallel streams of work
          </h2>
          <div className="mt-6 grid gap-4 md:grid-cols-2">
            {keyFeatures.map((feature) => (
              <article
                key={feature.title}
                className="rounded-2xl border border-line bg-surface/75 p-5"
              >
                <h3 className="text-base font-semibold tracking-tight">
                  {feature.title}
                </h3>
                <p className="mt-2 text-sm leading-6 text-foreground-soft">
                  {feature.description}
                </p>
              </article>
            ))}
          </div>
        </section>

        {/* ── CTA ── */}
        <section className="rounded-3xl border border-line bg-surface/88 p-8 text-center backdrop-blur-sm md:p-10">
          <h2 className="text-3xl font-semibold tracking-tight">
            Fewer context resets. More real building.
          </h2>
          <p className="mx-auto mt-3 max-w-3xl text-sm leading-7 text-foreground-soft md:text-base">
            Muxy exists to reduce the hidden tax of parallel work: context
            hunting, app hopping, port conflicts, and accidental interruptions.
          </p>
          <div className="mt-6 flex flex-wrap justify-center gap-3">
            <Link
              href="/releases/latest"
              className="btn-primary rounded-full px-5 py-2.5 text-sm font-semibold transition-colors"
            >
              Download
            </Link>
            <Link
              href="/docs"
              className="rounded-full border border-line px-5 py-2.5 text-sm font-semibold transition-colors hover:border-accent hover:text-accent"
            >
              Read Docs
            </Link>
          </div>
        </section>
      </main>
    </div>
  );
}
