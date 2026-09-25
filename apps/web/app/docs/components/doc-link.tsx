import Link from "next/link";
import type { ReactNode } from "react";

type DocLinkProps = {
  href: string;
  children: ReactNode;
};

export function DocLink({ href, children }: DocLinkProps) {
  return (
    <Link href={href} className="text-accent hover:underline">
      {children}
    </Link>
  );
}
