import type { Metadata } from "next";
import Link from "next/link";
import { SiteHeader } from "../components/site-header";
import { docsPageLinks } from "./content";

export const metadata: Metadata = {
  title: "Docs",
  description: "Getting started with Muxy workspaces.",
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
  {
    name: "Reserved Ports",
    description:
      "Named port definitions allocated per workspace so parallel streams never collide on the same local port.",
  },
  {
    name: "Status Check",
    description:
      "A periodic shell command that tests a running process and surfaces green/red health in the UI.",
  },
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
            Muxy in five minutes.
          </h1>
          <p className="mt-4 max-w-4xl text-base leading-7 text-foreground-soft">
            This page gives a quick mental model for how Muxy helps you run
            and switch workspaces during parallel development.
          </p>
          <div className="mt-6 flex flex-wrap gap-3">
            <Link
              href="/"
              className="btn-primary rounded-full px-5 py-2.5 text-sm font-semibold transition-colors"
            >
              Getting Started
            </Link>
            <a
              href="#docs-map"
              className="rounded-full border border-line px-5 py-2.5 text-sm font-semibold transition-colors hover:border-accent hover:text-accent"
            >
              Jump to Overview
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
          id="docs-map"
          className="rounded-3xl border border-line bg-surface/86 p-7 backdrop-blur-sm md:p-8"
        >
          <h2 className="text-2xl font-semibold tracking-tight">
            Docs Overview
          </h2>
          <p className="mt-3 max-w-4xl text-sm leading-7 text-foreground-soft">
            These pages cover the most common user questions and operational
            workflows from setup through troubleshooting.
          </p>
          <div className="mt-5 grid gap-4 md:grid-cols-2">
            {docsPageLinks.map((page) => (
              <article
                key={page.href}
                className="rounded-2xl border border-line bg-surface/75 p-4"
              >
                <h3 className="text-lg font-semibold tracking-tight">
                  {page.title}
                </h3>
                <p className="mt-2 text-sm leading-7 text-foreground-soft">
                  {page.summary}
                </p>
                <Link
                  href={page.href}
                  className="mt-3 inline-flex rounded-full border border-line px-4 py-2 text-xs font-semibold transition-colors hover:border-accent hover:text-accent"
                >
                  Read Page
                </Link>
              </article>
            ))}
          </div>
        </section>
      </main>
    </div>
  );
}
