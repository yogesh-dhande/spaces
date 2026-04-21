import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";

export const metadata: Metadata = {
  title: "Status Checks",
  description: "Health checks attached to workspace processes.",
};

export default function StatusChecksDocsPage() {
  return (
    <DocsShell
      title="Status Checks"
      description="Status checks run shell commands against running workspace processes and show passed/failed status indicators in the UI."
      pagePath="/docs/status-checks"
    >
      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">What Is a Status Check?</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          A status check is a shell command Muxy runs on a schedule while the workspace is running. Exit code <code>0</code> means healthy; anything else (or a timeout) means unhealthy. The result shows up as a green or red dot next to the linked process.
        </p>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Each check has a command, an interval, a timeout, and the process it belongs to. A process can have more than one check.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">On Failure</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Pick what Muxy should do when a check fails:
        </p>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• <strong>none</strong> &mdash; just mark it red.</li>
          <li>• <strong>notify</strong> &mdash; send a macOS notification.</li>
          <li>• <strong>restart</strong> &mdash; restart the linked process.</li>
        </ul>
      </article>
    </DocsShell>
  );
}
