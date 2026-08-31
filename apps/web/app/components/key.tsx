// Amber marketing keycap used in body copy (hero, FAQ, keyboard section) to
// call out a keyboard shortcut. Shared between the page's own JSX and the
// content data (e.g. FAQ answers) that reference it inline.
export function Key({ children }: { children: React.ReactNode }) {
  return (
    <kbd className="inline-flex items-center rounded-sm border border-accent-2/55 bg-accent-2/20 px-2 py-1 font-mono text-xs font-semibold leading-none text-accent-2">
      {children}
    </kbd>
  );
}
