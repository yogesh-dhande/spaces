import Link from "next/link";
import { ParallelStackIllustration } from "./components/parallel-stack-illustration";
import { AppHeroPreview } from "./components/app-hero-preview";

import { ProblemSimulation } from "./components/problem-simulation";
import { SiteHeader } from "./components/site-header";


const keyFeatures = [
  {
    title: "Manager mode for coding agents",
    description:
      "Track all your coding agents in one place. Get notified when an agent is waiting on you. Use keyboard shortcuts to quickly navigate between them.",
  },
  {
    title: "Manage Git worktrees. Or not.",
    description:
      "Create and run isolated workspaces per branch so parallel feature work does not collide. Prefer separate checkouts instead of worktrees? Muxy works great for that too!",
  },
  {
    title: "Organize work into virtual workspaces",
    description:
      "Muxy organizes your terminals, browser tabs, and editors into worktree and project-specific workspaces. Switch between branches and tasks instantly—without port collisions or lost context.",
  },
  {
    title: "Reserved ports per workspace",
    description:
      "Each workspace gets named reserved ports as environment variables (e.g. $FRONTEND_PORT, $BACKEND_PORT) so services can run side by side without recurring port conflicts.",
  },
  {
    title: "Switch between workspaces with ease",
    description:
      "Jump between active workspaces quickly without needing to sort through dozens of browser/editor/terminal windows.",
  },
  {
    title: "Switch between windows of the current workspace",
    description:
      "Cycle through the current workspace windows with deterministic shortcuts, instead of hunting across apps.",
  },
  {
    title: "Context tooltips",
    description:
      "Ask your coding agent to set a workspace tooltip so you always have context when you switch in. Press cmd+shift+i to toggle it on/off when looking at any window belonging to the workspace.",
  },
  {
    title: "Start and stop quickly",
    description:
      "No need to keep those tabs open or processes running just because it is a pain to set it all up again. Muxy manages starting and stopping for you automatically.",
  },
  {
    title: "Bring your own tools",
    description:
      "Muxy works with your preferred stack, whether it is Claude Code or Codex, Cursor or Windsurf. You do not need to learn a new tool or settle for a weaker coding agent just for UX.",
  },
  {
    title: "Native MacOS app under 5 MB",
    description:
      "Built with Swift and AppKit — not Electron. No bloated runtime, no sluggish UI. Muxy stays out of your way and off your CPU.",
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
            <h1 className="max-w-2xl text-2xl font-semibold leading-tight tracking-tight md:text-4xl">
              Stop Hunting for Tabs.<br />Start Building Features.
            </h1>
            <p className="max-w-2xl text-base leading-7 text-foreground-soft md:text-lg">
              Muxy reduces the hidden tax of parallel work: context
              hunting, app hopping, port conflicts, and accidental interruptions.
            </p>
            <div className="flex flex-wrap gap-3">
              <Link
                href="/releases/latest"
                className="btn-primary rounded-full px-5 py-2.5 text-sm font-semibold transition-colors cursor-pointer"
              >
                Download (it's free!)
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
          <h3 className="mt-3 text-2xl font-semibold tracking-tight">
            Development is no longer about typing code.
          </h3>
          <p>
             It's about managing context.
          </p>
          <ul className="mt-5 max-w-3xl space-y-4 text-sm leading-6 text-foreground-soft md:text-base md:leading-7">
            <li >"Where is the tab for the checkout page?"</li>
            <li>"Port 3000 is already in use."</li>
            <li>"Which terminal is running the job queue again?"</li>
          </ul>
        </section>

        {/* ── Problem: The Friction ── */}
        <section className="rounded-3xl border border-line bg-surface/86 p-7 backdrop-blur-sm md:p-8">
          <h3 className="mt-3 text-2xl font-semibold tracking-tight">
            Context gets scattered, then lost
          </h3>
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
            <p>
              What was I working on again?
            </p>
          </div>
        </section>

        <section className="rounded-3xl border border-line bg-surface/86 p-7 backdrop-blur-sm md:p-8">
          <h3 className="mt-3 text-2xl font-semibold tracking-tight">
            Meanwhile, small frictions compound
          </h3>
          <div className="mt-5 max-w-3xl space-y-4 text-sm leading-6 text-foreground-soft md:text-base md:leading-7">
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

        <section className="mt-8 md:mt-16">
          <h2 className="mt-3 text-3xl md:text-4xl font-semibold tracking-tight">
            Introducing Muxy
          </h2>
          <div className="mt-5 max-w-3xl space-y-4 text-sm leading-6 text-foreground-soft md:text-base md:leading-7">
            <p className="text-foreground">
              Muxy organizes your terminals, browser tabs, and editors into worktree and project-specific workspaces.
            </p>
            <p className="text-foreground">
              Switch between branches and tasks instantly—without port collisions or lost context.
            </p>
          </div>
          <div className="mt-6">
            <ProblemSimulation />
          </div>
        </section>

        {/* ── How It Works ── */}
        <section
          id="solution"
          className="my-8 md:my-16 rounded-3xl border border-line bg-surface/86 p-7 backdrop-blur-sm md:p-8"
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
        <section className="rounded-3xl my-8 md:my-16 ">
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
        <section id="features" className="my-8 md:my-16 rounded-3xl border border-line bg-surface/86 p-7 backdrop-blur-sm md:p-8">
          <p className="font-mono text-xs uppercase tracking-[0.16em] text-foreground-soft">
            Key Features
          </p>
          <h2 className="mt-3 text-3xl font-semibold tracking-tight">
            Built for parallel streams of work
          </h2>
          <p className="mt-3 max-w-3xl text-sm leading-6 text-foreground-soft md:text-base md:leading-7">
            Muxy manages repos, worktrees, ports, processes, and windows. So you can focus on your work.
          </p>
          <div className="mt-6 grid gap-4 md:grid-cols-2">
            {keyFeatures.map((feature) => (
              <article
                key={feature.title}
                className="rounded-2xl p-5"
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

        {/* ── FAQ ── */}
        <section
          id="faq"
          className="my-8 md:my-16 rounded-3xl backdrop-blur-sm"
        >
          <p className="font-mono text-xs uppercase tracking-[0.16em] text-foreground-soft">
            FAQ
          </p>
          <h2 className="mt-3 text-3xl font-semibold tracking-tight">
            Common questions
          </h2>
          <div className="mt-6 space-y-2">

            <details className="group rounded-xl border border-line bg-surface/75">
              <summary className="flex cursor-pointer select-none list-none items-center justify-between px-4 py-3.5 text-sm font-semibold text-foreground">
                How much does it cost?
                <span aria-hidden className="ml-3 shrink-0 text-foreground-soft transition-transform duration-200 group-open:rotate-180">▾</span>
              </summary>
              <div className="border-t border-line px-4 pb-4 pt-3 text-sm leading-7 text-foreground-soft">
                Muxy is free!
              </div>
            </details>

            <details className="group rounded-xl border border-line bg-surface/75">
              <summary className="flex cursor-pointer select-none list-none items-center justify-between px-4 py-3.5 text-sm font-semibold text-foreground">
                What are the system requirements?
                <span aria-hidden className="ml-3 shrink-0 text-foreground-soft transition-transform duration-200 group-open:rotate-180">▾</span>
              </summary>
              <div className="border-t border-line px-4 pb-4 pt-3 text-sm leading-7 text-foreground-soft">
                <ul className="ml-4 list-disc space-y-1">
                  <li>macOS 14 Sonoma or later</li>
                  <li><a href="https://github.com/koekeishiya/yabai" className="text-accent hover:underline">yabai</a> — an open-source window manager used for window tracking and focus switching</li>
                  <li><a href="https://iterm2.com" className="text-accent hover:underline">iTerm2</a></li>
                </ul>
              </div>
            </details>

            <details className="group rounded-xl border border-line bg-surface/75">
              <summary className="flex cursor-pointer select-none list-none items-center justify-between px-4 py-3.5 text-sm font-semibold text-foreground">
                What is yabai? Why does it need accessibility permissions?
                <span aria-hidden className="ml-3 shrink-0 text-foreground-soft transition-transform duration-200 group-open:rotate-180">▾</span>
              </summary>
              <div className="border-t border-line px-4 pb-4 pt-3 text-sm leading-7 text-foreground-soft">
                <a href="https://github.com/koekeishiya/yabai" className="text-accent hover:underline">yabai</a> is an open-source macOS window management utility. Muxy uses it to bring the right window to the front when you switch workspaces.
                macOS requires accessibility permissions before any app can programmatically control windows on behalf of other processes — yabai uses this to perform focus switching on Muxy&apos;s behalf.
              </div>
            </details>

            <details className="group rounded-xl border border-line bg-surface/75">
              <summary className="flex cursor-pointer select-none list-none items-center justify-between px-4 py-3.5 text-sm font-semibold text-foreground">
                Can I use it with CLI coding agents like Claude Code or Codex CLI?
                <span aria-hidden className="ml-3 shrink-0 text-foreground-soft transition-transform duration-200 group-open:rotate-180">▾</span>
              </summary>
              <div className="border-t border-line px-4 pb-4 pt-3 text-sm leading-7 text-foreground-soft">
                Yes. Open a terminal inside any workspace with{" "}
                <kbd className="inline-flex items-center rounded border border-line bg-surface px-1.5 py-0.5 font-mono text-xs leading-none">⌘⇧T</kbd>{" "}
                and start your agent as normal. The terminal window is automatically attached to the workspace so you can jump back to it with keyboard shortcuts at any time.
                To let the agent set workspace tooltips and signal its status, add the{" "}
                <Link href="/docs/cli" className="text-accent hover:underline">Muxy agent instructions</Link>{" "}
                to your project&apos;s AGENTS.md. See the{" "}
                <Link href="/docs/guides" className="text-accent hover:underline">cookbook guides</Link>{" "}
                for step-by-step setup.
              </div>
            </details>

            <details className="group rounded-xl border border-line bg-surface/75">
              <summary className="flex cursor-pointer select-none list-none items-center justify-between px-4 py-3.5 text-sm font-semibold text-foreground">
                Can I use it with the Codex app?
                <span aria-hidden className="ml-3 shrink-0 text-foreground-soft transition-transform duration-200 group-open:rotate-180">▾</span>
              </summary>
              <div className="border-t border-line px-4 pb-4 pt-3 text-sm leading-7 text-foreground-soft">
                Yes. Muxy works alongside the Codex app — it automatically imports Codex worktrees as workspaces. See the{" "}
                <Link href="/docs/guides" className="text-accent hover:underline">cookbook guides</Link>{" "}
                for a detailed walkthrough.
              </div>
            </details>

            <details className="group rounded-xl border border-line bg-surface/75">
              <summary className="flex cursor-pointer select-none list-none items-center justify-between px-4 py-3.5 text-sm font-semibold text-foreground">
                Can I use it with Conductor?
                <span aria-hidden className="ml-3 shrink-0 text-foreground-soft transition-transform duration-200 group-open:rotate-180">▾</span>
              </summary>
              <div className="border-t border-line px-4 pb-4 pt-3 text-sm leading-7 text-foreground-soft">
                Yes. You can use Conductor to create worktrees and write code. Muxy will automatically import them as workspaces so you can manage windows and context with Muxy. 
                We recommend using Muxy setup scripts and processes to configure workspaces and leaving Conductor setup and run scripts empty. See the{" "}
                <Link href="/docs/guides" className="text-accent hover:underline">cookbook guides</Link>{" "}
                for a detailed walkthrough.
              </div>
            </details>

            <details className="group rounded-xl border border-line bg-surface/75">
              <summary className="flex cursor-pointer select-none list-none items-center justify-between px-4 py-3.5 text-sm font-semibold text-foreground">
                Do you collect any data?
                <span aria-hidden className="ml-3 shrink-0 text-foreground-soft transition-transform duration-200 group-open:rotate-180">▾</span>
              </summary>
              <div className="border-t border-line px-4 pb-4 pt-3 text-sm leading-7 text-foreground-soft">
                No. Muxy is a native desktop app that runs entirely on your Mac. It does not send any data back to Muxy or any third party.
              </div>
            </details>

            <details className="group rounded-xl border border-line bg-surface/75">
              <summary className="flex cursor-pointer select-none list-none items-center justify-between px-4 py-3.5 text-sm font-semibold text-foreground">
                Where do I send bug reports?
                <span aria-hidden className="ml-3 shrink-0 text-foreground-soft transition-transform duration-200 group-open:rotate-180">▾</span>
              </summary>
              <div className="border-t border-line px-4 pb-4 pt-3 text-sm leading-7 text-foreground-soft">
                Email <a href="mailto:support@muxy.dev" className="text-accent hover:underline">support@muxy.dev</a>.
              </div>
            </details>

          </div>
        </section>

        {/* ── CTA ── */}
        <section className="rounded-3xl border border-line bg-surface/88 p-8 text-center backdrop-blur-sm md:p-10">
          <h2 className="text-3xl font-semibold tracking-tight">
            Build faster with Muxy
          </h2>
          <p className="mx-auto mt-3 max-w-3xl text-sm leading-7 text-foreground-soft md:text-base">
            Muxy helps you build faster by managing context and reducing chaos.
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
