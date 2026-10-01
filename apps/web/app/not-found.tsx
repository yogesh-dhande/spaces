import type { Metadata } from "next";
import Link from "next/link";
import { SiteHeader } from "./components/site-header";
import { SiteFooter } from "./components/site-footer";

export const metadata: Metadata = {
  title: "Page not found",
};

const destinations = [
  { title: "Install on your Mac", path: "/docs/installation" },
  { title: "iPhone app", path: "/docs/ios" },
  { title: "CLI", path: "/docs/cli" },
  { title: "Back to the homepage", path: "/" },
];

export default function NotFound() {
  return (
    <div className="relative min-h-screen overflow-x-clip">
      <SiteHeader />

      <main className="mx-auto w-full max-w-3xl px-6 pb-20 pt-10 md:pt-14">
        <p className="font-mono text-xs font-medium uppercase tracking-widest text-accent-2">
          Page not found
        </p>
        <h1 className="mt-4 text-3xl font-semibold leading-tight tracking-tight md:text-5xl">
          That page isn&apos;t here. Try one of these:
        </h1>
        <ul className="mt-10 border-t border-line/70">
          {destinations.map((destination) => (
            <li key={destination.path} className="border-b border-line/70">
              <Link
                href={destination.path}
                className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 py-4 transition-colors hover:underline"
              >
                <span className="text-base font-semibold text-accent">{destination.title}</span>
                <span className="text-sm text-foreground-soft">{destination.path}</span>
              </Link>
            </li>
          ))}
        </ul>
      </main>

      <SiteFooter />
    </div>
  );
}
