import type { Metadata } from "next";
import Link from "next/link";
import { ScreenshotFrame } from "../components/screenshot-frame";
import { SiteHeader } from "../components/site-header";

export const metadata: Metadata = {
  title: "Docs",
  description: "Getting started with Spaceship workspaces.",
};

const terms = [
  {
    name: "Project",
    description:
      "A codebase you configure once so new workspaces start with consistent behavior.",
  },
  {
    name: "Workspace",
    description:
      "An isolated stream of work for a feature, fix, or experiment.",
  },
  {
    name: "Process",
    description:
      "Commands you want running with the workspace, like app servers or agents.",
  },
  {
    name: "Browser Session",
    description:
      "Pages you want tied to a workspace so you can return to the same context.",
  },
];

const quickStart = [
  "Add or connect a project.",
  "Create a workspace for the branch or task you are starting.",
  "Launch the workspace and continue where you left off.",
  "Switch to another workspace without rebuilding your context.",
];

const boundaries = [
  "Spaceship manages workspace context and switching.",
  "Your existing tools still handle editing, tiling, and coding.",
  "Workspaces can run in parallel while you stay focused on one.",
];

export default function DocsPage() {
  return (
    <div className="relative min-h-screen overflow-x-clip">
      <SiteHeader />

      <main className="mx-auto flex w-full max-w-6xl flex-col gap-8 px-6 pb-20">
        <section className="rounded-3xl border border-line bg-surface/90 p-7 backdrop-blur-sm md:p-10">
          <p className="font-mono text-xs uppercase tracking-[0.16em] text-foreground-soft">
            Documentation
          </p>
          <h1 className="mt-3 max-w-4xl text-4xl font-semibold tracking-tight md:text-5xl">
            Spaceship in five minutes.
          </h1>
          <p className="mt-4 max-w-4xl text-base leading-7 text-foreground-soft">
            This page gives a quick mental model for how Spaceship helps you run
            and switch workspaces during parallel development.
          </p>
          <div className="mt-6 flex flex-wrap gap-3">
            <Link
              href="/"
              className="rounded-full bg-accent px-5 py-2.5 text-sm font-semibold text-white transition-colors hover:bg-accent-strong"
            >
              Back to Home
            </Link>
            <a
              href="#quickstart"
              className="rounded-full border border-line px-5 py-2.5 text-sm font-semibold transition-colors hover:border-accent hover:text-accent"
            >
              Jump to Quick Start
            </a>
          </div>
        </section>

        <section className="rounded-3xl border border-line bg-surface/86 p-7 backdrop-blur-sm md:p-8">
          <h2 className="text-2xl font-semibold tracking-tight">Core Terms</h2>
          <div className="mt-5 grid gap-4 md:grid-cols-2">
            {terms.map((item) => (
              <div key={item.name}>
                <h3 className="font-mono text-xs uppercase tracking-[0.12em] text-foreground-soft">
                  {item.name}
                </h3>
                <p className="mt-1 text-sm leading-7 text-foreground-soft">
                  {item.description}
                </p>
              </div>
            ))}
          </div>
        </section>

        <section
          id="quickstart"
          className="grid gap-6 rounded-3xl border border-line bg-surface/86 p-7 backdrop-blur-sm md:grid-cols-[1fr_1fr] md:p-8"
        >
          <div>
            <h2 className="text-2xl font-semibold tracking-tight">Quick Start</h2>
            <ol className="mt-4 space-y-2 text-sm leading-7 text-foreground-soft">
              {quickStart.map((step, index) => (
                <li key={step}>
                  <span className="mr-2 font-mono text-xs text-foreground">
                    {index + 1}.
                  </span>
                  {step}
                </li>
              ))}
            </ol>
            <h3 className="mt-6 text-lg font-semibold tracking-tight">
              Product boundary
            </h3>
            <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
              {boundaries.map((item) => (
                <li key={item}>• {item}</li>
              ))}
            </ul>
          </div>
          <div className="space-y-4">
            <ScreenshotFrame
              title="Project + Workspace List"
              caption="Placeholder for left-pane navigation with projects and nested workspaces."
            />
            <ScreenshotFrame
              title="Workspace Actions"
              caption="Placeholder for launch, restart, stop, and archive controls in context."
            />
          </div>
        </section>
      </main>
    </div>
  );
}
