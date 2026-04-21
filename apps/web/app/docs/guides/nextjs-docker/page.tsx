import type { Metadata } from "next";
import Link from "next/link";
import { DocsShell } from "../../components/docs-shell";

export const metadata: Metadata = {
  title: "Guide: Next.js (Docker Compose)",
  description:
    "Cookbook guide for running a single Next.js service in Docker Compose with Muxy settings.",
};

const card = "border-t border-line/70 pt-8 first:border-t-0 first:pt-0";
const prose = "mt-2 text-sm leading-7 text-foreground-soft";
const list = "mt-3 space-y-2 text-sm leading-7 text-foreground-soft";
const code =
  "mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-lg border border-line/70 bg-background-soft/60 p-3 text-xs leading-6 text-foreground";

export default function NextjsDockerGuidePage() {
  return (
    <DocsShell
      title="Guide: Next.js (Docker Compose)"
      description="Use this when your app runs in containers and you want workspace-isolated host ports with clear container health visibility."
      pagePath="/docs/guides"
    >
      <article className={card}>
        <h2 className="text-2xl font-semibold tracking-tight">Use Case</h2>
        <p className={prose}>
          Your Next.js service runs via Compose. You need branch-isolated environments,
          deterministic port mapping, and health checks that detect individual service failure.
        </p>
      </article>

      <article className={card}>
        <h2 className="text-2xl font-semibold tracking-tight">Project Settings Explained</h2>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Port Definitions</h3>
        <pre className={code}>
          <code>{`FRONTEND_PORT`}</code>
        </pre>
        <p className={prose}>
          Muxy assigns one host port per workspace. Compose maps host <code>$FRONTEND_PORT</code> to container port <code>3000</code>.
        </p>
        <h4 className="mt-4 text-sm font-semibold text-foreground">docker-compose.yml example</h4>
        <pre className={code}>
          <code>{`services:
  web:
    build: .
    ports:
      - "\${FRONTEND_PORT}:3000"
    environment:
      - PORT=3000`}</code>
        </pre>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Setup Script</h3>
        <pre className={code}>
          <code>{`cp .env.example .env`}</code>
        </pre>
        <p className={prose}>
          Copying <code>.env</code> gives each workspace an isolated env file.
          Symlink can reduce duplication, but one edit impacts all linked workspaces.
          Point <code>cp</code> at whatever seed file your repo keeps — Muxy does not provide a built-in shared env file.
        </p>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Processes</h3>
        <pre className={code}>
          <code>{`FRONTEND_PORT=$FRONTEND_PORT docker compose up --build`}</code>
        </pre>
        <p className={prose}>
          The process keeps Compose attached in one terminal, which is useful for live logs and interactive shutdown.
        </p>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Browser Sessions</h3>
        <pre className={code}>
          <code>{`http://localhost:$FRONTEND_PORT`}</code>
        </pre>
        <p className={prose}>
          This targets the workspace-specific host mapping. Without named ports, one workspace can accidentally open another workspace&apos;s frontend.
        </p>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Stop Script: stop vs down</h3>
        <pre className={code}>
          <code>{`docker compose stop
# or
docker compose down`}</code>
        </pre>
        <ul className={list}>
          <li>• <code>docker compose stop</code>: stop containers but keep networks/volumes/containers for faster resume.</li>
          <li>• <code>docker compose down</code>: remove containers and network; cleaner reset, slower next startup.</li>
          <li>• Use <code>stop</code> for day-to-day pause/resume; use <code>down</code> when you need a clean teardown.</li>
        </ul>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Status Checks</h3>
        <pre className={code}>
          <code>{`curl -fsS http://localhost:$FRONTEND_PORT`}</code>
        </pre>
        <p className={prose}>
          An HTTP probe against the workspace-reserved host port is the most reliable signal: it succeeds only when Compose is up and the container is serving traffic. Status checks make service health explicit in the UI and can notify or restart on failure.
        </p>
      </article>

      <article className={card}>
        <h2 className="text-2xl font-semibold tracking-tight">Why Status Checks Matter in Compose</h2>
        <ul className={list}>
          <li>• Key use case: one service in multi-service Compose goes down, but you do not want Compose auto-restart; you still want an immediate notification.</li>
          <li>• Detect partial outage where frontend is up but backend/cache/worker has failed.</li>
          <li>• Alert when a container exists but endpoint is unhealthy (liveness differs from readiness).</li>
          <li>• Trigger controlled restart in Muxy rather than always-on container restart loops.</li>
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
