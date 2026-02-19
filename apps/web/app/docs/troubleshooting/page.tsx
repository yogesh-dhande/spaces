import type { Metadata } from "next";
import { ScreenshotFrame } from "../../components/screenshot-frame";
import { DocsShell } from "../components/docs-shell";

export const metadata: Metadata = {
  title: "Troubleshooting",
  description: "Common setup, launch, and runtime issues in Muxy.",
};

export default function TroubleshootingDocsPage() {
  return (
    <DocsShell
      title="Troubleshooting"
      description="Diagnosis paths for common dependency, workspace lifecycle, process, and window-routing failures."
      pagePath="/docs/troubleshooting"
    >
      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Quick Triage</h2>
        <ol className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>1. Confirm dependencies: yabai, iTerm2, and Chrome are installed and running.</li>
          <li>2. Confirm accessibility permissions are granted.</li>
          <li>3. Confirm workspace is not archived and has valid settings.</li>
          <li>4. If launch reports existing runtime state, run <code>mx workspace up --restart</code> (or restart) instead of launch.</li>
          <li>5. Re-open workspace detail to refresh live browser-tab and window state.</li>
        </ol>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Workspace Creation Failures</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• `Branch name is required for git projects`: provide `--branch` when creating the workspace.</li>
          <li>• `Target branch not found`: use a valid local or remote target branch.</li>
          <li>• Workspace name conflict: use a unique workspace name or archive/delete old workspace state.</li>
          <li>• Project directory errors: confirm the project path exists and is accessible.</li>
        </ul>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Launch/Restart/Stop Issues</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• `Workspace is already running. Use restart.`: call restart to reconcile stale runtime state.</li>
          <li>• No terminals open: verify iTerm2 is installed and available.</li>
          <li>• No browser sessions open: verify Chrome is installed and session URLs are configured.</li>
          <li>• Services remain after stop: move extra teardown into workspace `stop_script`.</li>
        </ul>
        <pre className="mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-xl border border-line bg-background-soft/80 p-3 text-xs leading-6 text-foreground">
          <code>{`mx workspace up --dir /path/to/workspace
mx workspace restart --dir /path/to/workspace
mx workspace stop --dir /path/to/workspace
mx workspace launch --dir /path/to/workspace`}</code>
        </pre>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Window and Browser Routing Issues</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Missing window shortcut targets: open the workspace and recapture windows via launch/restart.</li>
          <li>• Browser tab not focused correctly: confirm browser sessions use stable URL prefixes.</li>
          <li>• Shared Chrome window confusion: keep workspace session URLs distinct where possible.</li>
          <li>• Stale state after app restart: select workspace and trigger refresh/restart flow.</li>
        </ul>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Status Check Issues</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Red checks: run the check command manually inside workspace context.</li>
          <li>• Timeout failures: increase timeout if service startup is slower than expected.</li>
          <li>• No checks shown: confirm the check `process` field matches a process template name.</li>
          <li>• Unexpected output: verify check command handles auth headers and local routing.</li>
        </ul>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Keyboard Shortcut Issues</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Global toggle shortcut does nothing: rebind in Settings if another app intercepts it.</li>
          <li>• `cmd+1..9` does not focus windows: ensure workspace has tracked windows in the Run tab list.</li>
          <li>• Next/previous cycles wrong context: focus the intended workspace first (`cmd+shift+return`).</li>
          <li>• Text input edits blocked: verify focus is inside a text field before using edit shortcuts.</li>
        </ul>
      </article>

      <article className="grid gap-4 rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm md:grid-cols-2">
        <ScreenshotFrame
          title="Workspace Error State"
          caption="Workspace detail with visible error text and recovery action controls."
        />
        <ScreenshotFrame
          title="Status and Window Diagnostics"
          caption="Run tab showing process check output and current tracked window list."
        />
      </article>
    </DocsShell>
  );
}
