import type { Metadata } from "next";
import Link from "next/link";
import { DocsShell } from "../components/docs-shell";
import { cookbookGuides } from "../content";

export const metadata: Metadata = {
  title: "Cookbook Guides",
  description:
    "End-to-end project setup recipes you can copy and adapt for common stacks.",
};

const guides = cookbookGuides;

export default function GuidesDocsPage() {
  return (
    <DocsShell
      title="Cookbook Guides"
      description="Real-world project setups you can copy and adapt. Each guide is a separate page with full use-case context and an explanation of every project setting."
      pagePath="/docs/guides"
    >
      <article>
        <p className="font-mono text-[0.62rem] uppercase tracking-[0.18em] text-accent">
          What&apos;s in each guide
        </p>
        <h2 className="mt-3 text-2xl font-semibold tracking-tight">
          A use case plus every knob, explained.
        </h2>
        <ul className="mt-5 grid gap-3 text-sm leading-7 text-foreground-soft md:grid-cols-2">
          <li className="flex gap-3">
            <span className="mt-2 h-1.5 w-1.5 shrink-0 rounded-full bg-accent" />
            <span>A concrete use case.</span>
          </li>
          <li className="flex gap-3">
            <span className="mt-2 h-1.5 w-1.5 shrink-0 rounded-full bg-accent" />
            <span>Project-setting by project-setting explanation of what it solves and how it works.</span>
          </li>
          <li className="flex gap-3">
            <span className="mt-2 h-1.5 w-1.5 shrink-0 rounded-full bg-accent" />
            <span>Why named ports, process commands, browser sessions, setup scripts, and status checks are configured a specific way.</span>
          </li>
          <li className="flex gap-3">
            <span className="mt-2 h-1.5 w-1.5 shrink-0 rounded-full bg-accent" />
            <span>Docker-specific operational guidance where relevant.</span>
          </li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8">
        <p className="font-mono text-[0.62rem] uppercase tracking-[0.18em] text-accent">
          Index
        </p>
        <h2 className="mt-3 text-2xl font-semibold tracking-tight">
          Browse guides
        </h2>
        <div className="mt-6 grid gap-3">
          {guides.map((guide, i) => (
            <Link
              key={guide.href}
              href={guide.href}
              className="group grid gap-3 rounded-2xl border border-line/70 bg-surface/60 p-5 transition-colors hover:border-accent/60 hover:bg-surface/80 md:grid-cols-[auto_minmax(0,1fr)_auto] md:items-center"
            >
              <span className="font-mono text-[0.6rem] uppercase tracking-[0.18em] text-foreground-soft">
                {String(i + 1).padStart(2, "0")}
              </span>
              <div>
                <h3 className="text-lg font-semibold tracking-tight">
                  {guide.title}
                </h3>
                <p className="mt-1 text-sm leading-6 text-foreground-soft">
                  {guide.summary}
                </p>
                <div className="mt-2 flex flex-wrap gap-1.5">
                  {guide.stack.map((tag) => (
                    <span
                      key={tag}
                      className="rounded-full border border-line/70 bg-background-soft/60 px-2 py-0.5 font-mono text-[0.58rem] uppercase tracking-[0.12em] text-foreground-soft"
                    >
                      {tag}
                    </span>
                  ))}
                </div>
              </div>
              <span className="hidden items-center gap-1 text-xs font-semibold text-accent transition-transform group-hover:translate-x-0.5 md:flex">
                Open <span aria-hidden>→</span>
              </span>
            </Link>
          ))}
        </div>
      </article>
    </DocsShell>
  );
}
