// Shared className constants for docs pages under `app/docs/*`. Kept in one place
// (and consumed by ./section.tsx's Card/Prose components) so pages render
// identically without redeclaring the same Tailwind class strings everywhere.
export const card = "border-t border-line/70 pt-8 first:border-t-0 first:pt-0";
export const prose = "mt-2 text-sm leading-7 text-foreground-soft";
export const list = "mt-3 space-y-2 text-sm leading-7 text-foreground-soft";
export const code =
  "mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-sm border border-line/70 bg-background-soft/60 p-3 text-xs leading-6 text-foreground";
