import type { Metadata } from "next";
import Link from "next/link";
import { SiteHeader } from "../components/site-header";
import { SiteFooter } from "../components/site-footer";
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

      {/* Hero */}
      <section className="relative">
        <div
          aria-hidden
          className="pointer-events-none absolute left-[-8rem] top-0 h-72 w-72 rounded-full bg-accent/16 blur-3xl"
        />
        <div className="mx-auto w-full max-w-7xl px-6 pb-12 pt-16 md:pt-24">
          <p className="font-mono text-[0.7rem] uppercase tracking-[0.18em] text-foreground-soft">
            Documentation
          </p>
          <h1 className="mt-4 max-w-3xl text-4xl font-semibold leading-[1.05] tracking-tight md:text-6xl">
            Muxy in five minutes.
          </h1>
          <p className="mt-5 max-w-2xl text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
            A quick mental model for how Muxy helps you run and switch
            workspaces during parallel development.
          </p>
          <div className="mt-8 flex flex-wrap items-center gap-3">
            <Link
              href="/"
              className="btn-primary inline-flex items-center gap-2 rounded-full px-6 py-3 text-sm font-semibold"
            >
              Getting Started
              <span aria-hidden>→</span>
            </Link>
            <a
              href="#docs-map"
              className="inline-flex items-center gap-1.5 rounded-full px-5 py-3 text-sm font-semibold text-foreground-soft transition-colors hover:text-accent"
            >
              Jump to overview
              <span aria-hidden>↓</span>
            </a>
          </div>
        </div>
      </section>

      {/* Core Terms */}
      <section className="border-y border-line/70 bg-background-soft/60">
        <div className="mx-auto w-full max-w-7xl px-6 py-20">
          <div className="grid gap-10 lg:grid-cols-12">
            <div className="lg:col-span-4">
              <p className="font-mono text-[0.7rem] uppercase tracking-[0.18em] text-foreground-soft">
                Glossary
              </p>
              <h2 className="mt-4 text-3xl font-semibold tracking-tight md:text-4xl">
                Core terms.
              </h2>
              <p className="mt-4 max-w-sm text-sm leading-7 text-foreground-soft">
                The small vocabulary you need to get oriented with Muxy.
              </p>
            </div>

            <dl className="grid gap-x-8 gap-y-6 lg:col-span-8 md:grid-cols-2">
              {terms.map((item) => (
                <div
                  key={item.name}
                  className="border-t border-line/70 pt-5"
                >
                  <dt className="font-mono text-[0.62rem] uppercase tracking-[0.18em] text-accent">
                    {item.name}
                  </dt>
                  <dd className="mt-2 text-sm leading-7 text-foreground-soft">
                    {item.description}
                  </dd>
                </div>
              ))}
            </dl>
          </div>
        </div>
      </section>

      {/* Docs map */}
      <section id="docs-map" className="mx-auto w-full max-w-7xl px-6 py-20 md:py-24">
        <div className="flex flex-col items-start justify-between gap-6 md:flex-row md:items-end">
          <div>
            <p className="font-mono text-[0.7rem] uppercase tracking-[0.18em] text-foreground-soft">
              Overview
            </p>
            <h2 className="mt-4 max-w-2xl text-3xl font-semibold tracking-tight md:text-4xl">
              Docs Overview
            </h2>
          </div>
          <p className="max-w-md text-sm leading-7 text-foreground-soft">
            These pages cover the most common user questions and operational
            workflows from setup through troubleshooting.
          </p>
        </div>

        <div className="mt-10 grid gap-4 md:grid-cols-2 lg:grid-cols-3">
          {docsPageLinks.map((page, i) => (
            <Link
              key={page.href}
              href={page.href}
              className="group flex flex-col gap-3 rounded-2xl border border-line/80 bg-surface/80 p-5 transition-colors hover:border-accent/60"
            >
              <span className="font-mono text-[0.6rem] uppercase tracking-[0.18em] text-foreground-soft">
                {String(i + 1).padStart(2, "0")}
              </span>
              <h3 className="text-lg font-semibold tracking-tight">
                {page.title}
              </h3>
              <p className="text-sm leading-6 text-foreground-soft">
                {page.summary}
              </p>
              <span className="mt-1 inline-flex items-center gap-1 text-xs font-semibold text-accent transition-transform group-hover:translate-x-0.5">
                Read page <span aria-hidden>→</span>
              </span>
            </Link>
          ))}
        </div>
      </section>

      <SiteFooter />
    </div>
  );
}
