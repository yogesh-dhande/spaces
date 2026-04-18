import Image from "next/image";
import Link from "next/link";
import MuxyLogo from "../muxy.svg";

const navItems = [
  { href: "/#features", label: "Features" },
  { href: "/#faq", label: "FAQ" },
  { href: "/docs", label: "Docs" },
  { href: "/docs/cli", label: "CLI" },
];

export function SiteHeader() {
  return (
    <header className="sticky top-0 z-40">
      <div
        aria-hidden
        className="absolute inset-x-0 top-0 h-[calc(100%+1.25rem)] bg-gradient-to-b from-background via-background/80 to-transparent"
      />
      <div className="relative mx-auto flex w-full max-w-7xl items-center justify-between gap-4 px-4 pt-4">
        <Link
          href="/"
          className="inline-flex items-center gap-2 rounded-full border border-line/80 bg-surface/85 px-3.5 py-2 text-sm font-semibold tracking-tight shadow-[0_6px_22px_-14px_color-mix(in_oklab,var(--ink)_60%,transparent)] backdrop-blur-md transition-colors hover:border-accent/60"
        >
          <Image src={MuxyLogo} alt="" width={18} height={18} />
          <span>Muxy</span>
        </Link>

        <nav className="hidden items-center gap-1 rounded-full border border-line/80 bg-surface/85 px-1.5 py-1 text-sm font-medium text-foreground-soft shadow-[0_6px_22px_-14px_color-mix(in_oklab,var(--ink)_60%,transparent)] backdrop-blur-md md:flex">
          {navItems.map((item, i) => (
            <span key={item.href} className="inline-flex items-center">
              {i > 0 ? (
                <span
                  aria-hidden
                  className="mx-0.5 h-3.5 w-px bg-line/70"
                />
              ) : null}
              <Link
                href={item.href}
                className="rounded-full px-3 py-1 transition-colors hover:bg-background-soft/70 hover:text-foreground"
              >
                {item.label}
              </Link>
            </span>
          ))}
        </nav>

        <div className="flex items-center gap-2">
          <Link
            href="/docs"
            className="hidden text-sm text-foreground-soft transition-colors hover:text-foreground md:hidden"
          >
            Docs
          </Link>
          <a
            href="/releases/latest"
            target="_blank"
            rel="noopener noreferrer"
            className="btn-primary inline-flex items-center gap-1.5 rounded-full px-4 py-2 text-sm font-semibold shadow-[0_6px_22px_-14px_color-mix(in_oklab,var(--ink)_60%,transparent)]"
          >
            <span>Download</span>
          </a>
        </div>
      </div>

      {/* Mobile nav */}
      <nav className="relative mx-auto mt-2 flex w-full max-w-7xl items-center gap-1 overflow-x-auto rounded-full border border-line/80 bg-surface/85 px-1.5 py-1 text-sm font-medium text-foreground-soft shadow-[0_6px_22px_-14px_color-mix(in_oklab,var(--ink)_60%,transparent)] backdrop-blur-md md:hidden">
        {navItems.map((item, i) => (
          <span key={item.href} className="inline-flex items-center">
            {i > 0 ? (
              <span aria-hidden className="mx-0.5 h-3.5 w-px bg-line/70" />
            ) : null}
            <Link
              href={item.href}
              className="whitespace-nowrap rounded-full px-3 py-1 transition-colors hover:bg-background-soft/70 hover:text-foreground"
            >
              {item.label}
            </Link>
          </span>
        ))}
      </nav>
    </header>
  );
}
