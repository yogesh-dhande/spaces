import Image from "next/image";
import Link from "next/link";
import SpacesLogo from "../spaces.svg";
import { PrimaryButton } from "./primary-button";

const githubRepoURL = "https://github.com/yogesh-dhande/spaces";
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

        <div className="flex items-center gap-2">
          <a
            href={githubRepoURL}
            target="_blank"
            rel="noopener noreferrer"
            aria-label="Open Spaces on GitHub"
            className="inline-flex size-9 items-center justify-center text-foreground-soft transition-colors hover:text-foreground"
          >
            <GitHubIcon className="size-[18px]" />
          </a>
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

function GitHubIcon({ className }: { className?: string }) {
  return (
    <svg
      aria-hidden="true"
      viewBox="0 0 24 24"
      fill="currentColor"
      className={className}
    >
      <path
        fillRule="evenodd"
        clipRule="evenodd"
        d="M12 2C6.48 2 2 6.58 2 12.23c0 4.52 2.86 8.35 6.84 9.7.5.1.68-.22.68-.5v-1.9c-2.78.62-3.36-1.21-3.36-1.21-.46-1.19-1.12-1.51-1.12-1.51-.91-.64.07-.63.07-.63 1.01.07 1.54 1.06 1.54 1.06.9 1.57 2.35 1.12 2.92.85.09-.67.35-1.12.64-1.38-2.22-.26-4.55-1.14-4.55-5.07 0-1.12.39-2.03 1.03-2.75-.1-.26-.45-1.3.1-2.71 0 0 .84-.27 2.75 1.05A9.38 9.38 0 0 1 12 6.88c.85 0 1.69.12 2.49.35 1.91-1.32 2.75-1.05 2.75-1.05.55 1.41.2 2.45.1 2.71.64.72 1.03 1.63 1.03 2.75 0 3.94-2.34 4.81-4.57 5.06.36.32.68.94.68 1.9v2.82c0 .28.18.6.69.5A10.05 10.05 0 0 0 22 12.23C22 6.58 17.52 2 12 2Z"
      />
    </svg>
  );
}
