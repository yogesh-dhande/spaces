import Link from "next/link";
import { AppHeroPreview } from "./components/app-hero-preview";
import { ProblemSimulation } from "./components/problem-simulation";
import { SiteHeader } from "./components/site-header";

const painSignals = [
  "One feature is split across terminal tabs, editor windows, and browser tabs with no shared grouping.",
  "Desktop/app switching reduces clutter, but still sends you to the wrong window when context changes quickly.",
  "UI bugs force a reverse lookup: from page issue to repo tab to the exact terminal or agent session.",
  "Default port collisions keep resurfacing, which causes local route and auth redirect drift.",
];

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
    title: "Bring your own tools",
    description:
      "Spaceship works with your preferred stack, whether it is Claude Code or Codex, Cursor or Windsurf. You do not need to learn a new tool or settle for a weaker coding agent just for UX.",
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

      <main className="mx-auto flex w-full max-w-6xl flex-col gap-8 px-6 pb-20">
        <section className="grid gap-7 rounded-3xl border border-line bg-surface/90 p-7 shadow-[0_24px_48px_-34px_color-mix(in_oklab,var(--ink)_45%,transparent)] backdrop-blur-sm md:grid-cols-[1.1fr_0.9fr] md:p-9">
          <div className="space-y-5">
            <p className="inline-flex rounded-full border border-line bg-background-soft px-3 py-1 font-mono text-[0.68rem] uppercase tracking-[0.14em] text-foreground-soft">
              Parallel Development, Managed
            </p>
            <h1 className="max-w-2xl text-4xl font-semibold leading-tight tracking-tight md:text-6xl">
              Parallel work should not feel like chaos.
            </h1>
            <p className="max-w-2xl text-base leading-7 text-foreground-soft md:text-lg">
              Spaceship gives each stream of work a clear home so switching
              between projects does not mean rebuilding your context from
              scratch every hour.
            </p>
            <div className="flex flex-wrap gap-3">
              <a
                href="#solution"
                className="rounded-full bg-accent px-5 py-2.5 text-sm font-semibold text-white transition-colors hover:bg-accent-strong"
              >
                See How It Works
              </a>
              <Link
                href="/docs"
                className="rounded-full border border-line px-5 py-2.5 text-sm font-semibold transition-colors hover:border-accent hover:text-accent"
              >
                Read Docs
              </Link>
            </div>
          </div>
          
        </section>

        <section
          id="problem"
          className="rounded-3xl border border-line bg-surface/86 p-7 backdrop-blur-sm md:p-8"
        >
          <p className="font-mono text-xs uppercase tracking-[0.16em] text-foreground-soft">
            The Problem
          </p>
          <h2 className="mt-3 text-3xl font-semibold tracking-tight">
            The hard part is locating the right context quickly.
          </h2>
          <p className="font-mono text-[0.68rem] uppercase tracking-[0.12em] text-foreground-soft">
            And working within it without losing it again.
          </p>
          <div className="mt-6">

            <ul className="mt-2 space-y-1.5 text-sm leading-6 text-foreground-soft">
              {painSignals.map((point) => (
                <li key={point}>• {point}</li>
              ))}
            </ul>
          </div>
          <p className="mt-4 max-w-4xl text-base leading-7 text-foreground-soft">
            The comparison below shows where time goes when windows and ports are fragmented, and how Spaceship's workspace-first model removes that overhead.
          </p>

          <div className="mt-6">
            <ProblemSimulation />
          </div>

        </section>

        <section
          id="solution"
          className="rounded-3xl border border-line bg-surface/86 p-7 backdrop-blur-sm md:p-8"
        >
          <p className="font-mono text-xs uppercase tracking-[0.16em] text-foreground-soft">
            How It Works
          </p>
          <h2 className="mt-3 text-3xl font-semibold tracking-tight">
            How Spaceship Works
          </h2>
          <p className="mt-3 max-w-4xl text-base leading-7 text-foreground-soft">
            Spaceship organizes parallel work around workspaces, then lets you
            move through that workspace with predictable shortcuts.
          </p>
          <div className="mt-5 grid gap-4 md:grid-cols-3">
            <article className="rounded-2xl border border-line bg-surface/75 p-4">
              <p className="font-mono text-xs uppercase tracking-[0.12em] text-foreground-soft">
                01 Select
              </p>
              <p className="mt-2 text-sm leading-6 text-foreground-soft">
                Choose the workspace tied to the feature or branch you need to
                work on.
              </p>
            </article>
            <article className="rounded-2xl border border-line bg-surface/75 p-4">
              <p className="font-mono text-xs uppercase tracking-[0.12em] text-foreground-soft">
                02 Jump
              </p>
              <p className="mt-2 text-sm leading-6 text-foreground-soft">
                Open the right browser, editor, or terminal window for that
                workspace instantly.
              </p>
            </article>
            <article className="rounded-2xl border border-line bg-surface/75 p-4">
              <p className="font-mono text-xs uppercase tracking-[0.12em] text-foreground-soft">
                03 Continue
              </p>
              <p className="mt-2 text-sm leading-6 text-foreground-soft">
                Quickly switch between windows of a workspace with keyboard shortcuts.
              </p>
            </article>
          </div>
          <div className="my-6 ">
            <div>
              <p className="text-base leading-7 text-foreground-soft">
                This turns parallel development into a repeatable loop instead
                of a window hunt. Workspace boundaries stay clear, while
                switching between them stays fast.
              </p>
            </div>

          </div>
    <AppHeroPreview />
        </section>

        <section className="rounded-3xl border border-line bg-surface/86 p-7 backdrop-blur-sm md:p-8">
          <p className="font-mono text-xs uppercase tracking-[0.16em] text-foreground-soft">
            Key Features
          </p>
          <h2 className="mt-3 text-3xl font-semibold tracking-tight">
            Built for parallel streams of work
          </h2>
          <div className="mt-5 grid gap-4 md:grid-cols-2">
            {keyFeatures.map((feature) => (
              <article
                key={feature.title}
                className="rounded-2xl border border-line bg-surface/75 p-4"
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

        <section className="rounded-3xl border border-line bg-surface/88 p-8 text-center backdrop-blur-sm md:p-10">
          <h2 className="text-3xl font-semibold tracking-tight">
            Fewer context resets. More real building.
          </h2>
          <p className="mx-auto mt-3 max-w-3xl text-sm leading-7 text-foreground-soft md:text-base">
            Spaceship exists to reduce the hidden tax of parallel work: context
            hunting, app hopping, port conflicts, and accidental interruptions.
          </p>
          <div className="mt-6 flex flex-wrap justify-center gap-3">
            <Link
              href="/docs"
              className="rounded-full bg-accent px-5 py-2.5 text-sm font-semibold text-white transition-colors hover:bg-accent-strong"
            >
              Open Documentation
            </Link>
            <a
              href="#problem"
              className="rounded-full border border-line px-5 py-2.5 text-sm font-semibold transition-colors hover:border-accent hover:text-accent"
            >
              Revisit Problem
            </a>
          </div>
        </section>
      </main>
    </div>
  );
}
