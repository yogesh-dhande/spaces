import Image from "next/image";
import Link from "next/link";
import SpacesLogo from "../spaces.svg";
import { PrimaryButton } from "./primary-button";

const githubReleasesURL = "https://github.com/yogesh-dhande/spaces/releases/latest";

const navItems = [
  { href: "/#features", label: "Features" },
  { href: "/#faq", label: "FAQ" },
  { href: "/docs", label: "Docs" },
  { href: "/docs/cli", label: "CLI" },
];

export function SiteHeader() {
  return (
    <header className="sticky top-0 z-40 border-b border-line/70 bg-background/80 backdrop-blur-md">
      <div className="mx-auto flex h-14 w-full max-w-7xl items-center justify-between gap-4 px-6">
        <Link
          href="/"
          className="inline-flex items-center gap-2 text-sm font-semibold tracking-tight transition-colors hover:text-accent"
        >
          <Image src={SpacesLogo} alt="" width={18} height={18} />
          <span>Spaces</span>
        </Link>

        <nav className="hidden items-center gap-6 text-sm font-medium text-foreground-soft md:flex">
          {navItems.map((item) => (
            <Link
              key={item.href}
              href={item.href}
              className="transition-colors hover:text-foreground"
            >
              {item.label}
            </Link>
          ))}
        </nav>

        <PrimaryButton
          href={githubReleasesURL}
          target="_blank"
          rel="noopener noreferrer"
          size="sm"
          className="shadow-[0_6px_22px_-14px_color-mix(in_oklab,var(--ink)_60%,transparent)]"
        >
          <span>Download</span>
        </PrimaryButton>
      </div>

      {/* Mobile nav */}
      <nav className="mx-auto flex w-full max-w-7xl items-center gap-5 overflow-x-auto px-6 pb-2.5 text-sm font-medium text-foreground-soft md:hidden">
        {navItems.map((item) => (
          <Link
            key={item.href}
            href={item.href}
            className="whitespace-nowrap transition-colors hover:text-foreground"
          >
            {item.label}
          </Link>
        ))}
      </nav>
    </header>
  );
}
