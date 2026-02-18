import type { Metadata } from "next";
import Link from "next/link";
import { DocsShell } from "../../components/docs-shell";

export const metadata: Metadata = {
  title: "Guide: Next.js + Django Monorepo (No Docker)",
  description:
    "Cookbook guide for running a full-stack monorepo directly on host with Muxy.",
};

const card = "rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm";
const prose = "mt-2 text-sm leading-7 text-foreground-soft";
const code =
  "mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-xl border border-line bg-background-soft/80 p-3 text-xs leading-6 text-foreground";

export default function NextjsDjangoMonorepoHostGuidePage() {
  return (
    <DocsShell
      title="Guide: Next.js + Django Monorepo (No Docker)"
      description="Use this when frontend and backend live in one repo and both run directly on your machine."
      pagePath="/docs/guides"
    >
      <article className={card}>
        <h2 className="text-xl font-semibold tracking-tight">Use Case</h2>
        <p className={prose}>
          One repo with <code>/frontend</code> and <code>/backend</code>.
          You want each workspace to spin up both services with isolated ports and predictable URLs.
        </p>
      </article>

      <article className={card}>
        <h2 className="text-xl font-semibold tracking-tight">Project Settings Explained</h2>

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
cp /shared/.env .env`}</code>
        </pre>
        <p className={prose}>
          Bootstraps both app layers. Copying <code>.env</code> gives per-workspace config freedom.
          Symlink centralizes updates but can cause cross-workspace side effects.
        </p>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Processes</h3>
        <pre className={code}>
          <code>{`cd frontend && API_URL=http://localhost:$API_PORT PORT=$FRONTEND_PORT npm run dev
cd backend && python manage.py runserver 0.0.0.0:$API_PORT`}</code>
        </pre>
        <p className={prose}>
          Frontend points to the workspace backend port. Both processes stay in one workspace context with shared named-port env vars.
        </p>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Browser Sessions</h3>
        <pre className={code}>
          <code>{`http://localhost:$FRONTEND_PORT
http://localhost:$API_PORT/admin`}</code>
        </pre>
        <p className={prose}>
          Opens both frontend preview and Django admin for the same workspace.
        </p>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Status Checks</h3>
        <pre className={code}>
          <code>{`curl -fsS http://localhost:$FRONTEND_PORT
curl -fsS http://localhost:$API_PORT/health`}</code>
        </pre>
        <p className={prose}>
          Separate checks help isolate whether failures are in frontend, backend, or integration between the two.
        </p>
      </article>

      <Link
        href="/docs/guides"
        className="inline-flex rounded-full border border-line px-4 py-2 text-sm font-semibold transition-colors hover:border-accent hover:text-accent"
      >
        Back to Cookbook Guides
      </Link>
    </DocsShell>
  );
}
