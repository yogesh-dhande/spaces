import Link from "next/link";
import type { ReactNode } from "react";
import { SiteHeader } from "../../components/site-header";
import { docsPageLinks } from "../content";

type DocsShellProps = {
  title: string;
  description: string;
  pagePath: string;
  children: ReactNode;
};

export function DocsShell({
  title,
  description,
  pagePath,
  children,
}: DocsShellProps) {
  return (
    <div className="relative min-h-screen overflow-x-clip">
      <SiteHeader />

      <main className="mx-auto flex w-full max-w-6xl flex-col gap-6 px-6 pb-20">
        <section className="rounded-3xl border border-line bg-surface/88 p-7 backdrop-blur-sm md:p-9">
          <p className="font-mono text-xs uppercase tracking-[0.16em] text-foreground-soft">
            Documentation
          </p>
          <h1 className="mt-3 text-4xl font-semibold tracking-tight md:text-5xl">
            {title}
          </h1>
          <p className="mt-4 max-w-4xl text-base leading-7 text-foreground-soft">
            {description}
          </p>
          <div className="mt-6 flex flex-wrap gap-3">
            <Link
              href="/docs"
              className="rounded-full bg-accent px-5 py-2.5 text-sm font-semibold text-white transition-colors hover:bg-accent-strong"
            >
              Back to Docs Hub
            </Link>
            <Link
              href="/"
              className="rounded-full border border-line px-5 py-2.5 text-sm font-semibold transition-colors hover:border-accent hover:text-accent"
            >
              Back to Home
            </Link>
          </div>
        </section>

        <div className="grid gap-6 lg:grid-cols-[18rem_minmax(0,1fr)]">
          <aside className="min-w-0 rounded-3xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
            <p className="font-mono text-xs uppercase tracking-[0.14em] text-foreground-soft">
              Doc Pages
            </p>
            <nav className="mt-3 space-y-2">
              {docsPageLinks.map((item) => {
                const isActive = item.href === pagePath;
                return (
                  <Link
                    key={item.href}
                    href={item.href}
                    className={`block rounded-xl border px-3 py-2 text-sm transition-colors ${
                      isActive
                        ? "border-accent bg-accent/12 text-foreground"
                        : "border-line bg-surface/75 text-foreground-soft hover:border-accent hover:text-foreground"
                    }`}
                  >
                    {item.title}
                  </Link>
                );
              })}
            </nav>
          </aside>

          <section className="min-w-0 space-y-4">{children}</section>
        </div>
      </main>
    </div>
  );
}
