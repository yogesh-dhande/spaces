import type { Metadata } from "next";
import Link from "next/link";
import { DocsShell } from "../../components/docs-shell";

export const metadata: Metadata = {
  title: "Guide: Next.js + Django Monorepo (Docker)",
  description:
    "Cookbook guide for containerized full-stack monorepo with Spaces workspace settings.",
};

const card = "border-t border-line/70 pt-8 first:border-t-0 first:pt-0";
const prose = "mt-2 text-sm leading-7 text-foreground-soft";
const code =
  "mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-lg border border-line/70 bg-background-soft/60 p-3 text-xs leading-6 text-foreground";

export default function NextjsDjangoMonorepoDockerGuidePage() {
  return (
    <DocsShell
      title="Guide: Next.js + Django Monorepo (Docker)"
      description="Use this when both frontend and backend are in one repo and run through Docker Compose."
      pagePath="/docs/guides"
    >
      <article className={card}>
        <h2 className="text-2xl font-semibold tracking-tight">Use Case</h2>
        <p className={prose}>
          You need reproducible containerized frontend+backend environments per workspace, with host ports isolated by Spaces.
        </p>
      </article>

      <article className={card}>
        <h2 className="text-2xl font-semibold tracking-tight">Project Settings Explained</h2>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Services</h3>
        <pre className={code}>
          <code>{`frontend
api`}</code>
        </pre>
        <p className={prose}>
          Spaces allocates a host port per service per workspace. Compose maps them to container ports.
        </p>
        <h4 className="mt-4 text-sm font-semibold text-foreground">docker-compose.yml example</h4>
        <pre className={code}>
          <code>{`services:
  frontend:
    build: ./frontend
    ports:
      - "\${SPACES_FRONTEND_PORT}:3000"
    environment:
      - API_URL=http://backend:8000

  backend:
    build: ./backend
    ports:
      - "\${SPACES_API_PORT}:8000"`}</code>
        </pre>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Setup Script</h3>
        <pre className={code}>
          <code>{`cp .env.example .env`}</code>
        </pre>
        <p className={prose}>
          Keeps workspace configuration deterministic. Copy vs symlink tradeoff is the same: isolation vs centralized updates. Point <code>cp</code> at whatever seed file your repo keeps — Spaces does not provide a built-in shared env file.
        </p>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Process</h3>
        <pre className={code}>
          <code>{`SPACES_FRONTEND_PORT=$SPACES_FRONTEND_PORT SPACES_API_PORT=$SPACES_API_PORT docker compose up --build`}</code>
        </pre>
        <p className={prose}>
          One Compose process starts both services and streams logs in a single terminal.
        </p>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Browser Sessions</h3>
        <p className={prose}>
          Add two browser sessions — one URL per entry — so each opens in Chrome when you focus it.
        </p>
        <pre className={code}>
          <code>{`# frontend browser session
$SPACES_FRONTEND_URL`}</code>
        </pre>
        <pre className={code}>
          <code>{`# backend browser session
$SPACES_API_URL/admin`}</code>
        </pre>
        <p className={prose}>
          Using named-service URLs keeps browser targets tied to the correct workspace instance.
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
