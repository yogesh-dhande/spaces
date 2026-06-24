import type { ReactNode } from "react";

export function CodeBlock({ children }: { children: string }) {
  return (
    <pre className="mt-3 overflow-x-auto rounded-xl border border-line bg-code-surface px-4 py-3 font-mono text-xs leading-6 text-code-foreground">
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
