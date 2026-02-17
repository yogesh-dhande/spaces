import Link from "next/link";

const navItems = [
  { href: "/#problem", label: "Problem" },
  { href: "/#solution", label: "Solution" },
  { href: "/docs", label: "Docs" },
  {
    href: "/releases/latest",
    label: "Download",
    external: true,
  },
];

export function SiteHeader() {
  return (
    <header className="mx-auto flex w-full max-w-6xl items-center justify-between px-6 py-6">
      <Link
        href="/"
        className="rounded-full border border-line bg-surface px-4 py-2 text-sm font-semibold tracking-wide shadow-[0_1px_0_0_color-mix(in_oklab,var(--line)_68%,transparent)] transition-colors hover:border-accent"
      >
        Muxy
      </Link>
      <nav className="flex items-center gap-1 rounded-full border border-line bg-surface/75 p-1 text-sm text-foreground-soft backdrop-blur-sm">
        {navItems.map((item) =>
          item.external ? (
            <a
              key={item.href}
              href={item.href}
              target="_blank"
              rel="noopener noreferrer"
              className="rounded-full px-3 py-1.5 transition-colors hover:bg-background-soft hover:text-foreground"
            >
              {item.label}
            </a>
          ) : (
            <Link
              key={item.href}
              href={item.href}
              className="rounded-full px-3 py-1.5 transition-colors hover:bg-background-soft hover:text-foreground"
            >
              {item.label}
            </Link>
          )
        )}
      </nav>
    </header>
  );
}
