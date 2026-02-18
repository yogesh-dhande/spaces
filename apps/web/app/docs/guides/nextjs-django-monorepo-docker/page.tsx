import type { Metadata } from "next";
import Link from "next/link";
import { DocsShell } from "../../components/docs-shell";

export const metadata: Metadata = {
  title: "Guide: Next.js + Django Monorepo (Docker)",
  description:
    "Cookbook guide for containerized full-stack monorepo with Muxy workspace settings.",
};

const card = "rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm";
const prose = "mt-2 text-sm leading-7 text-foreground-soft";
const code =
  "mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-xl border border-line bg-background-soft/80 p-3 text-xs leading-6 text-foreground";

export default function NextjsDjangoMonorepoDockerGuidePage() {
  return (
    <DocsShell
      title="Guide: Next.js + Django Monorepo (Docker)"
      description="Use this when both frontend and backend are in one repo and run through Docker Compose."
      pagePath="/docs/guides"
    >
      <article className={card}>
        <h2 className="text-xl font-semibold tracking-tight">Use Case</h2>
        <p className={prose}>
          You need reproducible containerized frontend+backend environments per workspace, with host ports isolated by Muxy.
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
          Muxy allocates host ports per workspace. Compose maps them to container ports.
        </p>
        <h4 className="mt-4 text-sm font-semibold text-foreground">docker-compose.yml example</h4>
        <pre className={code}>
          <code>{`services:
  frontend:
    build: ./frontend
    ports:
      - "\${FRONTEND_PORT}:3000"
    environment:
      - API_URL=http://backend:8000

  backend:
    build: ./backend
    ports:
      - "\${API_PORT}:8000"`}</code>
        </pre>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Setup Script</h3>
        <pre className={code}>
          <code>{`cp /shared/.env .env`}</code>
        </pre>
        <p className={prose}>
          Keeps workspace configuration deterministic. Copy vs symlink tradeoff is the same: isolation vs centralized updates.
        </p>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Process</h3>
        <pre className={code}>
          <code>{`FRONTEND_PORT=$FRONTEND_PORT API_PORT=$API_PORT docker compose up --build`}</code>
        </pre>
        <p className={prose}>
          One Compose process starts both services and streams logs in a single terminal.
        </p>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Browser Sessions</h3>
        <pre className={code}>
          <code>{`http://localhost:$FRONTEND_PORT
http://localhost:$API_PORT/admin`}</code>
        </pre>
        <p className={prose}>
          Using named-port URLs keeps browser targets tied to the correct workspace instance.
        </p>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Stop Command Strategy</h3>
        <pre className={code}>
          <code>{`# normal pause
docker compose stop

# full cleanup reset
docker compose down`}</code>
        </pre>
        <p className={prose}>
          Prefer <code>stop</code> for faster iteration during normal workflow.
          Use <code>down</code> when you need to tear down network and container state.
        </p>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Status Checks</h3>
        <pre className={code}>
          <code>{`docker ps | grep -q monorepo_frontend
docker ps | grep -q monorepo_backend`}</code>
        </pre>
        <p className={prose}>
          Per-service checks reveal partial failure that is otherwise hidden when only the parent Compose process appears alive.
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
