import type { Metadata } from "next";
import Link from "next/link";
import { DocsShell } from "../../components/docs-shell";

export const metadata: Metadata = {
  title: "Guide: Next.js + Django Monorepo (No Docker)",
  description:
    "Cookbook guide for running a full-stack monorepo directly on host with Muxy.",
};

const card = "border-t border-line/70 pt-8 first:border-t-0 first:pt-0";
const prose = "mt-2 text-sm leading-7 text-foreground-soft";
const code =
  "mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-lg border border-line/70 bg-background-soft/60 p-3 text-xs leading-6 text-foreground";

export default function NextjsDjangoMonorepoHostGuidePage() {
  return (
    <DocsShell
      title="Guide: Next.js + Django Monorepo (No Docker)"
      description="Use this when frontend and backend live in one repo and both run directly on your machine."
      pagePath="/docs/guides"
    >
      <article className={card}>
        <h2 className="text-2xl font-semibold tracking-tight">Use Case</h2>
        <p className={prose}>
          One repo with <code>/frontend</code> and <code>/backend</code>.
          You want each workspace to spin up both services with isolated ports and predictable URLs.
        </p>
      </article>

      <article className={card}>
        <h2 className="text-2xl font-semibold tracking-tight">Project Settings Explained</h2>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Port Definitions</h3>
        <pre className={code}>
          <code>{`FRONTEND_PORT
API_PORT`}</code>
        </pre>
        <p className={prose}>
          Separate reserved ports keep frontend/backend stable per workspace and prevent collisions across branches.
        </p>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Setup Script</h3>
        <pre className={code}>
          <code>{`cd frontend && npm i
cd ../backend && pip install -r requirements.txt
cp .env.example .env`}</code>
        </pre>
        <p className={prose}>
          Bootstraps both app layers. The setup script runs in a shell, so chained <code>cd &amp;&amp; ...</code> steps are fine here (processes are the place where you must wrap with <code>bash -lc</code>). Copying <code>.env</code> gives per-workspace config freedom. Symlink centralizes updates but can cause cross-workspace side effects. Swap <code>.env.example</code> for whatever seed file your repo keeps — Muxy does not provide a built-in shared env file.
        </p>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Processes</h3>
        <p className={prose}>
          Add two processes. Muxy invokes each command directly, so use <code>bash -lc</code> when you need <code>cd</code> plus shell composition.
        </p>
        <pre className={code}>
          <code>{`# frontend process
bash -lc "cd frontend && API_URL=http://localhost:\$API_PORT PORT=\$FRONTEND_PORT npm run dev"`}</code>
        </pre>
        <pre className={code}>
          <code>{`# backend process
bash -lc "cd backend && python manage.py runserver 0.0.0.0:\$API_PORT"`}</code>
        </pre>
        <p className={prose}>
          Frontend points to the workspace backend port. Both processes stay in one workspace context with shared named-port env vars.
        </p>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Browser Sessions</h3>
        <p className={prose}>
          Add two browser sessions — each URL is its own entry — so both the frontend preview and Django admin reopen with the workspace.
        </p>
        <pre className={code}>
          <code>{`# frontend browser session
http://localhost:$FRONTEND_PORT`}</code>
        </pre>
        <pre className={code}>
          <code>{`# backend browser session
http://localhost:$API_PORT/admin`}</code>
        </pre>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Status Checks</h3>
        <p className={prose}>
          Add two status checks. Muxy treats one entry as one command, so separate entries let you tell frontend, backend, and integration failures apart.
        </p>
        <pre className={code}>
          <code>{`# frontend status check
curl -fsS http://localhost:$FRONTEND_PORT`}</code>
        </pre>
        <pre className={code}>
          <code>{`# backend status check
curl -fsS http://localhost:$API_PORT/health`}</code>
        </pre>
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
