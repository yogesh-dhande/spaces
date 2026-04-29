import Image from "next/image";
import Link from "next/link";
import SpacesLogo from "../spaces.svg";

const githubReleasesURL = "https://github.com/yogesh-dhande/spaces/releases/latest";

export function SiteFooter() {
  return (
    <footer className="mt-24 border-t border-line/70">
      <div className="mx-auto flex w-full max-w-7xl flex-col items-start justify-between gap-6 px-6 py-10 md:flex-row md:items-center">
        <div className="flex items-center gap-2">
          <Image src={SpacesLogo} alt="" width={20} height={20} />
          <span className="text-sm font-semibold tracking-tight">Spaces</span>
          <span className="ml-2 text-xs text-foreground-soft">
            Your command center for parallel development.
          </span>
        </div>

        <nav className="flex flex-wrap items-center gap-x-6 gap-y-2 text-sm text-foreground-soft">
          <Link href="/#features" className="transition-colors hover:text-foreground">
            Features
          </Link>
          <Link href="/#faq" className="transition-colors hover:text-foreground">
            FAQ
          </Link>
          <Link href="/docs" className="transition-colors hover:text-foreground">
            Docs
          </Link>
          <Link
            href="/docs/cli"
            className="transition-colors hover:text-foreground"
          >
            CLI Reference
          </Link>
          <a
            href={githubReleasesURL}
            target="_blank"
            rel="noopener noreferrer"
            className="transition-colors hover:text-foreground"
          >
            Download
          </a>
          <a
            href="mailto:support@spaces.dev"
            className="transition-colors hover:text-foreground"
          >
            support@spaces.dev
          </a>
        </nav>
      </div>
    </footer>
  );
}
