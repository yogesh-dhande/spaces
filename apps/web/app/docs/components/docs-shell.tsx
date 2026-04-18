import Link from "next/link";
import type { ReactNode } from "react";
import { SiteHeader } from "../../components/site-header";
import { SiteFooter } from "../../components/site-footer";
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

      <main className="mx-auto w-full max-w-7xl px-6 pb-16">
        {/* Breadcrumb + hero */}
        <section className="border-b border-line/70 pb-10 pt-10 md:pt-14">
          <nav className="flex items-center gap-1.5 font-mono text-[0.68rem] uppercase tracking-[0.18em] text-foreground-soft">
            <Link href="/docs" className="transition-colors hover:text-foreground">
              Docs
            </Link>
            <span aria-hidden>/</span>
            <span className="text-foreground">{title}</span>
          </nav>
          <h1 className="mt-4 max-w-4xl text-3xl font-semibold leading-tight tracking-tight md:text-5xl">
            {title}
          </h1>
          <p className="mt-4 max-w-3xl text-base leading-7 text-foreground-soft md:text-lg md:leading-8">
            {description}
          </p>
        </section>

        <div className="grid gap-10 pt-10 lg:grid-cols-[16rem_minmax(0,1fr)]">
          <aside className="min-w-0 lg:sticky lg:top-20 lg:self-start">
            <p className="font-mono text-[0.62rem] uppercase tracking-[0.18em] text-foreground-soft">
              Docs
            </p>
            <nav className="mt-3 flex flex-col gap-0.5 border-l border-line/70">
              {docsPageLinks.map((item) => {
                const isActive = item.href === pagePath;
                return (
                  <Link
                    key={item.href}
                    href={item.href}
                    className={`-ml-px border-l-2 px-3 py-1.5 text-sm transition-colors ${
                      isActive
                        ? "border-accent font-semibold text-foreground"
                        : "border-transparent text-foreground-soft hover:border-line hover:text-foreground"
                    }`}
                  >
                    {item.title}
                  </Link>
                );
              })}
            </nav>
          </aside>

          <section className="min-w-0 space-y-10">{children}</section>
        </div>
      </main>

      <SiteFooter />
    </div>
  );
}
