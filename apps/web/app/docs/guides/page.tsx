import type { Metadata } from "next";
import Link from "next/link";
import { DocsShell } from "../components/docs-shell";

export const metadata: Metadata = {
  title: "Cookbook Guides",
  description:
    "End-to-end project setup recipes you can copy and adapt for common stacks.",
};

const guides = [
  {
    href: "/docs/guides/nextjs-host",
    title: "Next.js (No Docker)",
    summary:
      "Single-repo frontend running directly on host with Muxy-managed ports and status checks.",
  },
  {
    href: "/docs/guides/nextjs-docker",
    title: "Next.js (Docker Compose)",
    summary:
      "Single frontend service in Compose, with notes on stop vs down and container-level health checks.",
  },
  {
    href: "/docs/guides/nextjs-django-monorepo-host",
    title: "Next.js + Django Monorepo (No Docker)",
    summary:
      "Frontend and backend processes from one repo, each with dedicated reserved ports.",
  },
  {
    href: "/docs/guides/nextjs-django-monorepo-docker",
    title: "Next.js + Django Monorepo (Docker)",
    summary:
      "Containerized full-stack setup with host port mapping per workspace.",
  },
  {
    href: "/docs/guides/nextjs-django-separate-repos",
    title: "Next.js + Django (Separate Repos)",
    summary:
      "Cross-project pattern using workspace overrides to run both services in one context.",
  },
] as const;

export default function GuidesDocsPage() {
  return (
    <DocsShell
      title="Cookbook Guides"
      description="Real-world project setups you can copy and adapt. Each guide is a separate page with full use-case context and an explanation of every project setting."
      pagePath="/docs/guides"
    >
      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Guide Index</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Each guide has its own page with:
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• A concrete use case.</li>
          <li>• Project-setting by project-setting explanation of what it solves and how it works.</li>
          <li>• Why named ports, process commands, browser sessions, setup scripts, and status checks are configured a specific way.</li>
          <li>• Docker-specific operational guidance where relevant.</li>
        </ul>
      </article>

      <div className="grid gap-4">
        {guides.map((guide) => (
          <article
            key={guide.href}
            className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm"
          >
            <h3 className="text-lg font-semibold tracking-tight">{guide.title}</h3>
            <p className="mt-2 text-sm leading-7 text-foreground-soft">
              {guide.summary}
            </p>
            <Link
              href={guide.href}
              className="mt-4 inline-flex rounded-full border border-line px-4 py-2 text-sm font-semibold transition-colors hover:border-accent hover:text-accent"
            >
              Open Guide
            </Link>
          </article>
        ))}
      </div>
    </DocsShell>
  );
}
