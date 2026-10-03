import type { Metadata } from "next";
import Link from "next/link";
import { DocsShell } from "../docs/components/docs-shell";
import { articles } from "../docs/content";

export const metadata: Metadata = {
  title: "Articles",
  description:
    "How to run Claude Code, Codex, and opencode from your iPhone, on a remote server, and together.",
};

export default function ArticlesIndexPage() {
  return (
    <DocsShell
      title="Articles"
      description="How to run Claude Code, Codex, and opencode from your iPhone, on a remote server, and together, and when something else fits better."
      pagePath="/articles"
      breadcrumbRoot={{ label: "Articles", href: "/articles" }}
    >
      <div className="grid gap-3">
        {articles.map((article, i) => (
          <Link
            key={article.href}
            href={article.href}
            className="group grid gap-3 rounded-sm border border-line/70 bg-surface/60 p-5 transition-colors hover:border-accent/60 hover:bg-surface/80 md:grid-cols-[auto_minmax(0,1fr)_auto] md:items-center"
          >
            <span className="font-mono text-[0.6rem] uppercase tracking-[0.18em] text-foreground-soft">
              {String(i + 1).padStart(2, "0")}
            </span>
            <div>
              <h3 className="text-lg font-semibold tracking-tight">{article.title}</h3>
              <p className="mt-1 text-sm leading-6 text-foreground-soft">{article.summary}</p>
            </div>
            <span className="hidden items-center gap-1 text-xs font-semibold text-accent transition-transform group-hover:translate-x-0.5 md:flex">
              Read <span aria-hidden>→</span>
            </span>
          </Link>
        ))}
      </div>
    </DocsShell>
  );
}
