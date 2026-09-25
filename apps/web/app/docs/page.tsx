import type { Metadata } from "next";
import Link from "next/link";
import { SiteHeader } from "../components/site-header";
import { SiteFooter } from "../components/site-footer";
import { PrimaryButton } from "../components/primary-button";
import { docsNavGroups } from "./content";

export const metadata: Metadata = {
  title: "Docs",
  description: "What Spaces is and the terms the rest of the docs use.",
};

const concepts: { name: string; description: string; href: string }[] = [
  {
    name: "Device",
    description: "A Mac or Linux machine running Spaces. Your Mac is one device; each paired machine is another.",
    href: "/docs/remote-access",
  },
  {
    name: "Project",
    description: "A folder or Git repository added to a device, with settings for how its workspaces run.",
    href: "/docs/projects",
  },
  {
    name: "Workspace",
    description: "One branch of a Git project in its own worktree, or a folder project's single directory, with its own processes, services, and terminals.",
    href: "/docs/workspaces",
  },
  {
    name: "Worktree",
    description: "The git worktree each Git workspace gets: its own branch checkout, sharing the project's one clone.",
    href: "/docs/projects#git-and-folder-projects",
  },
  {
    name: "Default workspace",
    description: "The workspace created with a project, on the repository's default branch, or the folder itself for a folder project. Listed first and cannot be deleted.",
    href: "/docs/projects#default-workspace",
  },
  {
    name: "Home workspace (~)",
    description: "Every device's workspace for terminals that belong to no project.",
    href: "/docs/projects#home-workspace",
  },
  {
    name: "Service",
    description: "A name a project declares; each workspace gets its own port for it and a stable URL that stays the same across restarts.",
    href: "/docs/services",
  },
  {
    name: "Process",
    description: "A long-running command a workspace starts, such as a dev server.",
    href: "/docs/processes",
  },
  {
    name: "Terminal",
    description: "An ad hoc shell, a process, or a coding agent, running on a device and shown as a pane in its workspace.",
    href: "/docs/terminals",
  },
  {
    name: "Tab and pane",
    description: "How terminals are arranged in a workspace's panel: tabs across the top, split into panes.",
    href: "/docs/terminals#tabs-and-panes",
  },
  {
    name: "Browser session",
    description: "A name and a URL a workspace opens as a Chrome tab when you focus it.",
    href: "/docs/browser-sessions",
  },
  {
    name: "Target",
    description: "A numbered row under a workspace, a browser session, process, agent, or terminal, that you can jump to with a keystroke.",
    href: "/docs/window-management#numbered-targets",
  },
  {
    name: "Coding agent",
    description: "Claude Code, Codex, or opencode, run in a terminal, whose state Spaces shows using hooks it installs for the agent.",
    href: "/docs/coding-agents",
  },
  {
    name: "Alert",
    description: "A row for something that needs you: a blocked or finished agent, an exited process, a bell, or a failed automation run.",
    href: "/docs/alerts",
  },
  {
    name: "Automation",
    description: "A script or agent Spaces runs on a device, by hand or on a schedule.",
    href: "/docs/automations",
  },
  {
    name: "Cycling mode",
    description: "What the cycle shortcuts step through: a workspace's windows, your alerts, every agent, or every open session.",
    href: "/docs/window-management#cycling",
  },
  {
    name: "Editor",
    description: "The window for reviewing a workspace's diff and editing its files.",
    href: "/docs/editor",
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
            Spaces in five minutes.
          </h1>
          <p className="mt-5 max-w-2xl text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
            Spaces runs your terminals, dev servers, and coding agents in parallel workspaces, one per
            branch, and keeps them running independent of any client. A native Mac app and an iPhone app
            drive the Spaces service on each of your machines: your Mac, another Mac, or a Linux box.
            Terminals, processes, and coding agents run in that service, so they keep running when you
            close the app or lose the connection.
          </p>
          <div className="mt-8 flex flex-wrap items-center gap-3">
            <PrimaryButton href="/docs/getting-started">
              Quickstart
              <span aria-hidden>→</span>
            </PrimaryButton>
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

      {/* Core concepts */}
      <section className="border-y border-line/70 bg-background-soft/60">
        <div className="mx-auto w-full max-w-7xl px-6 py-20">
          <div className="grid gap-10 lg:grid-cols-12">
            <div className="lg:col-span-4">
              <p className="font-mono text-[0.7rem] uppercase tracking-[0.18em] text-foreground-soft">
                Glossary
              </p>
              <h2 className="mt-4 text-3xl font-semibold tracking-tight md:text-4xl">
                Core concepts.
              </h2>
              <p className="mt-4 max-w-sm text-sm leading-7 text-foreground-soft">
                The small vocabulary the rest of the docs use.
              </p>
            </div>

            <dl className="grid gap-x-8 gap-y-6 lg:col-span-8 md:grid-cols-2">
              {concepts.map((item) => (
                <div key={item.name} className="border-t border-line/70 pt-5">
                  <dt className="font-mono text-[0.62rem] uppercase tracking-[0.18em]">
                    <Link href={item.href} className="text-accent hover:underline">
                      {item.name}
                    </Link>
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
              All docs
            </h2>
          </div>
          <p className="max-w-md text-sm leading-7 text-foreground-soft">
            Grouped by task, from first launch through troubleshooting.
          </p>
        </div>

        {docsNavGroups.map((group) => {
          const pages = group.pages.filter((page) => page.href !== "/docs");
          if (pages.length === 0) return null;
          return (
            <div key={group.label} className="mt-12 first:mt-10">
              <h3 className="font-mono text-[0.68rem] uppercase tracking-[0.18em] text-foreground-soft">
                {group.label}
              </h3>
              <div className="mt-4 grid gap-4 md:grid-cols-2 lg:grid-cols-3">
                {pages.map((page) => (
                  <Link
                    key={page.href}
                    href={page.href}
                    className="group flex flex-col gap-3 rounded-sm border border-line/80 bg-surface/80 p-5 transition-colors hover:border-accent/60"
                  >
                    <h4 className="text-lg font-semibold tracking-tight">{page.title}</h4>
                    <p className="text-sm leading-6 text-foreground-soft">{page.summary}</p>
                    <span className="mt-1 inline-flex items-center gap-1 text-xs font-semibold text-accent transition-transform group-hover:translate-x-0.5">
                      Read page <span aria-hidden>→</span>
                    </span>
                  </Link>
                ))}
              </div>
            </div>
          );
        })}
      </section>

      <SiteFooter />
    </div>
  );
}
