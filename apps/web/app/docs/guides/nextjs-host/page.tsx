import type { Metadata } from "next";
import Link from "next/link";
import { DocsShell } from "../../components/docs-shell";

export const metadata: Metadata = {
  title: "Guide: Next.js (No Docker)",
  description:
    "Cookbook guide for running a single Next.js app directly on host with Muxy project settings.",
};

const card = "border-t border-line/70 pt-8 first:border-t-0 first:pt-0";
const prose = "mt-2 text-sm leading-7 text-foreground-soft";
const list = "mt-3 space-y-2 text-sm leading-7 text-foreground-soft";
const code =
  "mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-lg border border-line/70 bg-background-soft/60 p-3 text-xs leading-6 text-foreground";

export default function NextjsHostGuidePage() {
  return (
    <DocsShell
      title="Guide: Next.js (No Docker)"
      description="Use this when your frontend runs directly on your machine (no containers) and you want multiple workspaces without port conflicts."
      pagePath="/docs/guides"
    >
      <article className={card}>
        <h2 className="text-2xl font-semibold tracking-tight">Use Case</h2>
        <p className={prose}>
          You have one Next.js repo and run <code>npm run dev</code> directly.
          You want multiple Muxy workspaces active at once, each with isolated ports
          and browser tabs.
        </p>
      </article>

      <article className={card}>
        <h2 className="text-2xl font-semibold tracking-tight">Project Settings Explained</h2>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Port Definitions</h3>
        <pre className={code}>
          <code>{`FRONTEND_PORT`}</code>
        </pre>
        <p className={prose}>
          Reserve a named port per workspace. This avoids collisions when two branches both run a dev server.
        </p>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Setup Script</h3>
        <pre className={code}>
          <code>{`npm i
cp .env.example .env`}</code>
        </pre>
        <p className={prose}>
          <code>npm i</code> ensures dependencies are present in new workspaces.
          <code>cp</code> creates an independent <code>.env</code> copy per workspace.
          Copy is safer when you want branch-local env edits.
          A symlink keeps one source of truth, but changes affect all workspaces and can cause surprising cross-branch coupling.
          Swap <code>.env.example</code> for any real path you maintain — Muxy does not provide a built-in shared env file.
        </p>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Processes</h3>
        <pre className={code}>
          <code>{`PORT=$FRONTEND_PORT npm run dev`}</code>
        </pre>
        <p className={prose}>
          This binds Next.js to the workspace-reserved host port, so browser sessions and checks target the correct workspace instance.
        </p>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Browser Sessions</h3>
        <pre className={code}>
          <code>{`http://localhost:$FRONTEND_PORT`}</code>
        </pre>
        <p className={prose}>
          Browser session URLs should use named ports so each workspace opens its own app tab reliably.
        </p>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Status Checks</h3>
        <pre className={code}>
          <code>{`curl -fsS http://localhost:$FRONTEND_PORT`}</code>
        </pre>
        <p className={prose}>
          Status checks give early signal when the server is down, hung, or failed after startup.
          Useful for restart policies and for quickly seeing run health in the Muxy UI.
        </p>
      </article>

      <article className={card}>
        <h2 className="text-2xl font-semibold tracking-tight">Other Status Check Use Cases</h2>
        <ul className={list}>
          <li>• Detect API readiness with health endpoints before opening dependent frontend pages.</li>
          <li>• Alert when background workers die but terminal windows remain open.</li>
          <li>• Detect auth/certificate errors by running a command that validates expected response content.</li>
        </ul>
      </article>

      <Link
        href="/docs/guides"
        className="mt-4 inline-flex items-center gap-1.5 text-sm font-semibold text-accent transition-colors hover:opacity-80"
      >
        ← Back to Cookbook Guides
      </Link>
    </DocsShell>
  );
}
