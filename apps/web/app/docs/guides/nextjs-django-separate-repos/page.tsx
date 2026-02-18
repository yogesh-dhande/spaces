import type { Metadata } from "next";
import Link from "next/link";
import { DocsShell } from "../../components/docs-shell";

export const metadata: Metadata = {
  title: "Guide: Next.js + Django (Separate Repos)",
  description:
    "Cookbook guide for operating frontend and backend from separate repositories with Muxy.",
};

const card = "rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm";
const prose = "mt-2 text-sm leading-7 text-foreground-soft";
const list = "mt-3 space-y-2 text-sm leading-7 text-foreground-soft";
const code =
  "mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-xl border border-line bg-background-soft/80 p-3 text-xs leading-6 text-foreground";

export default function NextjsDjangoSeparateReposGuidePage() {
  return (
    <DocsShell
      title="Guide: Next.js + Django (Separate Repos)"
      description="Use this when frontend and backend live in different projects but you want one active workspace context for both."
      pagePath="/docs/guides"
    >
      <article className={card}>
        <h2 className="text-xl font-semibold tracking-tight">Use Case</h2>
        <p className={prose}>
          Frontend and backend are separate repos. You want one workspace to run both processes and keep browser sessions aligned.
        </p>
      </article>

      <article className={card}>
        <h2 className="text-xl font-semibold tracking-tight">Project Settings Explained</h2>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Frontend Project Template</h3>
        <pre className={code}>
          <code>{`Ports: FRONTEND_PORT, BACKEND_PORT
Process: API_URL=http://localhost:$BACKEND_PORT PORT=$FRONTEND_PORT npm run dev
Browser Session: http://localhost:$FRONTEND_PORT`}</code>
        </pre>
        <p className={prose}>
          The frontend workspace must own both ports if it is the central context for both services.
        </p>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Workspace Override Process</h3>
        <pre className={code}>
          <code>{`cd /path/to/backend-project && python manage.py runserver 0.0.0.0:$BACKEND_PORT`}</code>
        </pre>
        <p className={prose}>
          Add this as a workspace-level process in the frontend workspace so both processes receive the same reserved env vars.
        </p>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Why This Works</h3>
        <ul className={list}>
          <li>• Named ports are workspace-scoped, not cross-project global variables.</li>
          <li>• Workspace overrides let one workspace run commands from another repo while staying in one orchestration context.</li>
          <li>• Browser sessions can still use <code>http://localhost:$FRONTEND_PORT</code> and backend/admin URLs consistently.</li>
        </ul>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Status Checks</h3>
        <pre className={code}>
          <code>{`curl -fsS http://localhost:$FRONTEND_PORT
curl -fsS http://localhost:$BACKEND_PORT/health`}</code>
        </pre>
        <p className={prose}>
          Detects partial outage early and helps avoid chasing frontend symptoms caused by backend failure.
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
