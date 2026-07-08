import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";

export const metadata: Metadata = {
  title: "Window Management",
  description: "How Spaces captures and focuses workspace windows.",
};

export default function WindowManagementDocsPage() {
  return (
    <DocsShell
      title="Window Management"
      description="Spaces captures the windows a workspace opens and jumps you back to any one of them with a keystroke. It doesn't move or resize them."
      pagePath="/docs/window-management"
    >
      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">What Spaces Tracks</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Spaces remembers the client windows that belong to a workspace:
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Spaces terminal panes for processes, coding agents, and ad hoc terminals.</li>
          <li>• Chrome tabs for browser sessions after you focus those sessions.</li>
        </ul>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Place those windows wherever you want. Spaces never moves, resizes, or tiles them without explicit user action — and never touches windows it didn&apos;t open.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Command Palette First</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Press <code>cmd+alt+-</code> to open the command palette.</li>
          <li>• With an empty query, Spaces shows Alerts first and then your most recently used windows so you can jump to any with a keyboard shortcut.</li>
          <li>• Start typing to fuzzy search across workspace title, target name, and detail text.</li>
          <li>• Press <code>return</code> to focus a live window or open the selected target directly if it isn&apos;t live yet.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Direct Window Focus from the UI</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <code>cmd+1</code> through <code>cmd+0</code> open or focus targets 1 through 10 of the selected workspace.</li>
          <li>• Click a row in the workspace&apos;s window list to focus that window.</li>
          <li>• Use <code>cmd+alt+]</code> and <code>cmd+alt+[</code> to cycle through already-open Chrome browser-session tabs and Spaces terminal panes in the current workspace.</li>
          <li>• A brief color pulse (optional) flashes on terminal windows so you can see where focus landed.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Open in Your Editor</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Press <code>cmd+alt+e</code> to open the selected workspace in your preferred editor. Choose it in Settings under General — Spaces lists whichever of VS Code, Devin Desktop, and Zed you have installed.</li>
          <li>• Re-opening focuses the editor&apos;s existing window for that folder instead of opening a duplicate.</li>
          <li>• For a workspace on a paired remote device, the editor opens the remote folder over SSH as a local window. Devin Desktop and Zed handle this out of the box; for VS Code, Spaces offers to install the Remote-SSH extension if it&apos;s missing.</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Recovery</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• If you close a tracked browser tab, focusing it reopens the URL in a tracked workspace Chrome window.</li>
          <li>• If you close a tracked terminal window, Spaces reopens it and reattaches to the still-running process.</li>
          <li>• If the underlying process is gone, Spaces prompts you before restarting it (<code>Cmd+R</code> to recover, <code>Esc</code> to cancel).</li>
        </ul>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Example Window Set</h2>
        <pre className="mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-lg border border-line/70 bg-background-soft/60 p-3 text-xs leading-6 text-foreground">
          <code>{`Workspace: feat/checkout
1. frontend — http://localhost:21004
2. admin panel — http://localhost:21005/admin
3. GitHub — https://github.com/org/repo
4. web server — npm run dev
5. worker — npm run worker`}</code>
        </pre>
      </article>
    </DocsShell>
  );
}
