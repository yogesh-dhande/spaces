import type { ReactNode } from "react";

export function CodeBlock({ children }: { children: string }) {
  return (
    <pre className="mt-3 overflow-x-auto rounded-sm border border-line bg-code-surface px-4 py-3 font-mono text-xs leading-6 text-code-foreground">
      <code>{children}</code>
    </pre>
  );
}

export function Cmd({ children }: { children: ReactNode }) {
  return (
    <code className="rounded bg-surface px-1.5 py-0.5 font-mono text-xs text-accent">
      {children}
    </code>
  );
}

// Distinct from Cmd: an older, plainer inline-code treatment (no accent color, no
// monospace, a different background token) used across a handful of pages for
// literal paths/values rather than runnable commands. Kept as its own component
// rather than folded into Cmd so the rendered markup stays exactly as it was.
export function InlineCode({ children }: { children: ReactNode }) {
  return (
    <code className="rounded bg-background-soft px-1.5 py-0.5 text-xs">
      {children}
    </code>
  );
}
