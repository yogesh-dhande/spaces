"use client";

import { useState } from "react";

type CopyablePromptProps = {
  label?: string;
  text: string;
};

export function CopyablePrompt({ label = "Prompt", text }: CopyablePromptProps) {
  const [copied, setCopied] = useState(false);

  const handleCopy = async () => {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1600);
    } catch {
      // Clipboard API unavailable (non-secure context / older browser); no-op.
    }
  };

  return (
    <div className="relative mt-3 overflow-hidden rounded-sm border border-line/70 bg-code-surface shadow-sm">
      <button
        type="button"
        onClick={handleCopy}
        aria-label={copied ? "Copied prompt" : `Copy ${label.toLowerCase()}`}
        aria-live="polite"
        className="absolute right-2 top-2 inline-flex items-center rounded-sm border border-white/10 bg-white/[0.04] px-2.5 py-1 font-mono text-[0.65rem] uppercase tracking-[0.14em] text-white/70 transition-colors hover:border-white/25 hover:text-white"
      >
        {copied ? "Copied" : "Copy"}
      </button>
      <pre className="w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words px-4 py-3 pr-20 font-mono text-xs leading-6 text-code-foreground">
        <code>{text}</code>
      </pre>
    </div>
  );
}
