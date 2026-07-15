import Link from "next/link";
import type { ComponentProps } from "react";

// Two sizes cover every call site: the default CTA and the compact header button.
const sizeClasses = {
  md: "gap-2 px-6 py-3",
  sm: "gap-1.5 px-4 py-2",
} as const;

type PrimaryButtonProps = ComponentProps<typeof Link> & {
  size?: keyof typeof sizeClasses;
};

/**
 * The one accent-filled call-to-action. Renders a Next.js Link (works for
 * internal routes and external URLs alike — pass target/rel through props).
 * Color, ring, and hover come from design tokens; per-call-site extras such as
 * a drop shadow go through `className`.
 */
export function PrimaryButton({
  size = "md",
  className = "",
  children,
  ...props
}: PrimaryButtonProps) {
  return (
    <Link
      {...props}
      className={`inline-flex items-center rounded-sm text-sm font-semibold text-background-soft bg-accent-strong ring-1 ring-inset ring-white/[0.16] transition-colors hover:bg-accent ${sizeClasses[size]} ${className}`}
    >
      {children}
    </Link>
  );
}
