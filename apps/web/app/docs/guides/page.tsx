import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";

export const metadata: Metadata = {
  title: "Cookbook Guides",
  description:
    "End-to-end project setup recipes you can copy and adapt for common stacks.",
};

/* ── shared styles ─────────────────────────────────────────────── */

const card =
  "rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm";
const heading = "text-xl font-semibold tracking-tight";
const prose = "mt-2 text-sm leading-7 text-foreground-soft";
const list = "mt-3 space-y-2 text-sm leading-7 text-foreground-soft";
const code =
  "mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-xl border border-line bg-background-soft/80 p-3 text-xs leading-6 text-foreground";

/* ── page ──────────────────────────────────────────────────────── */

export default function GuidesDocsPage() {
  return (
    <DocsShell
      title="Cookbook Guides"
      description="Real-world project setups you can copy and adapt. Each recipe describes what to configure in the Muxy GUI — port definitions, setup scripts, processes, browser sessions, and status checks."
      pagePath="/docs/guides"
    >
      {/* ── Recipe 1: Next.js without Docker ────────────────── */}
      <article className={card}>
        <h2 className={heading}>Next.js without Docker</h2>
        <p className={prose}>
          A single Next.js app running directly on the host with a coding agent
          alongside the dev server.
        </p>

        <h3 className="mt-4 text-sm font-semibold text-foreground">
          Port Definitions
        </h3>
        <ul className={list}>
          <li>
            • <strong>FRONTEND_PORT</strong> — reserved for the Next.js dev
            server.
          </li>
        </ul>

        <h3 className="mt-4 text-sm font-semibold text-foreground">
          Setup Script
        </h3>
        <pre className={code}>
          <code>{`npm install && cp /shared/.env .env`}</code>
        </pre>

        <h3 className="mt-4 text-sm font-semibold text-foreground">
          Processes
        </h3>
        <ul className={list}>
          <li>
            • <strong>Dev Server</strong> —{" "}
            <code className="text-xs">PORT=$FRONTEND_PORT npm run dev</code>
          </li>
          <li>
            • <strong>Coding Agent</strong> —{" "}
            <code className="text-xs">claude</code>
          </li>
        </ul>

        <h3 className="mt-4 text-sm font-semibold text-foreground">
          Browser Sessions
        </h3>
        <ul className={list}>
          <li>
            • <code className="text-xs">http://localhost:$FRONTEND_PORT</code> —
            local dev preview.
          </li>
          <li>• GitHub repository URL — PR reviews and issues.</li>
        </ul>

        <h3 className="mt-4 text-sm font-semibold text-foreground">
          Status Checks
        </h3>
        <ul className={list}>
          <li>
            • Port check on <strong>FRONTEND_PORT</strong> — confirms the dev
            server is listening.
          </li>
        </ul>
      </article>

      {/* ── Recipe 2: Next.js with Docker ───────────────────── */}
      <article className={card}>
        <h2 className={heading}>Next.js with Docker</h2>
        <p className={prose}>
          The same Next.js app, but running inside a Docker container managed by
          Compose.
        </p>

        <h3 className="mt-4 text-sm font-semibold text-foreground">
          Port Definitions
        </h3>
        <ul className={list}>
          <li>
            • <strong>FRONTEND_PORT</strong> — mapped from container to host.
          </li>
        </ul>

        <h3 className="mt-4 text-sm font-semibold text-foreground">
          Setup Script
        </h3>
        <pre className={code}>
          <code>{`cp /shared/.env .env`}</code>
        </pre>

        <h3 className="mt-4 text-sm font-semibold text-foreground">
          Processes
        </h3>
        <ul className={list}>
          <li>
            • <strong>Docker Compose</strong> —{" "}
            <code className="text-xs">
              FRONTEND_PORT=$FRONTEND_PORT docker compose up --build
            </code>
          </li>
          <li>
            • <strong>Coding Agent</strong> —{" "}
            <code className="text-xs">claude</code>
          </li>
        </ul>

        <h3 className="mt-4 text-sm font-semibold text-foreground">
          docker-compose.yml Reference
        </h3>
        <pre className={code}>
          <code>{`services:
  web:
    build: .
    ports:
      - "\${FRONTEND_PORT}:3000"
    environment:
      - PORT=3000`}</code>
        </pre>
        <p className={prose}>
          The container always listens on a fixed internal port (3000). Muxy
          maps the reserved <code className="text-xs">FRONTEND_PORT</code> to
          the host side so each workspace gets its own port.
        </p>

        <h3 className="mt-4 text-sm font-semibold text-foreground">
          Browser Sessions
        </h3>
        <ul className={list}>
          <li>
            • <code className="text-xs">http://localhost:$FRONTEND_PORT</code> —
            local dev preview.
          </li>
          <li>• GitHub repository URL.</li>
        </ul>
      </article>

      {/* ── Recipe 3: Next.js + Django, no Docker ──────────── */}
      <article className={card}>
        <h2 className={heading}>Next.js + Django (Single Repo, No Docker)</h2>
        <p className={prose}>
          A full-stack monorepo with a Next.js frontend and Django API, both
          running directly on the host.
        </p>

        <h3 className="mt-4 text-sm font-semibold text-foreground">
          Port Definitions
        </h3>
        <ul className={list}>
          <li>
            • <strong>FRONTEND_PORT</strong> — Next.js dev server.
          </li>
          <li>
            • <strong>API_PORT</strong> — Django dev server.
          </li>
        </ul>

        <h3 className="mt-4 text-sm font-semibold text-foreground">
          Setup Script
        </h3>
        <pre className={code}>
          <code>{`cd frontend && npm install && cd ../backend && pip install -r requirements.txt`}</code>
        </pre>

        <h3 className="mt-4 text-sm font-semibold text-foreground">
          Processes
        </h3>
        <ul className={list}>
          <li>
            • <strong>Frontend</strong> —{" "}
            <code className="text-xs">
              cd frontend && API_URL=http://localhost:$API_PORT
              PORT=$FRONTEND_PORT npm run dev
            </code>
          </li>
          <li>
            • <strong>Backend</strong> —{" "}
            <code className="text-xs">
              cd backend && python manage.py runserver 0.0.0.0:$API_PORT
            </code>
          </li>
          <li>
            • <strong>Coding Agent</strong> —{" "}
            <code className="text-xs">claude</code>
          </li>
        </ul>

        <h3 className="mt-4 text-sm font-semibold text-foreground">
          Browser Sessions
        </h3>
        <ul className={list}>
          <li>
            • <code className="text-xs">http://localhost:$FRONTEND_PORT</code> —
            frontend preview.
          </li>
          <li>
            • <code className="text-xs">
              http://localhost:$API_PORT/admin
            </code>{" "}
            — Django admin.
          </li>
          <li>• GitHub repository URL.</li>
        </ul>

        <h3 className="mt-4 text-sm font-semibold text-foreground">
          Status Checks
        </h3>
        <ul className={list}>
          <li>
            • Port check on <strong>FRONTEND_PORT</strong> — frontend ready.
          </li>
          <li>
            • Port check on <strong>API_PORT</strong> — API ready.
          </li>
        </ul>
      </article>

      {/* ── Recipe 4: Next.js + Django, Docker ─────────────── */}
      <article className={card}>
        <h2 className={heading}>Next.js + Django (Single Repo, Docker)</h2>
        <p className={prose}>
          The same full-stack monorepo, containerized with Docker Compose.
        </p>

        <h3 className="mt-4 text-sm font-semibold text-foreground">
          Port Definitions
        </h3>
        <ul className={list}>
          <li>
            • <strong>FRONTEND_PORT</strong> — mapped to the frontend container.
          </li>
          <li>
            • <strong>API_PORT</strong> — mapped to the backend container.
          </li>
        </ul>

        <h3 className="mt-4 text-sm font-semibold text-foreground">
          Processes
        </h3>
        <ul className={list}>
          <li>
            • <strong>Docker Compose</strong> —{" "}
            <code className="text-xs">
              FRONTEND_PORT=$FRONTEND_PORT API_PORT=$API_PORT docker compose up
              --build
            </code>
          </li>
          <li>
            • <strong>Coding Agent</strong> —{" "}
            <code className="text-xs">claude</code>
          </li>
        </ul>

        <h3 className="mt-4 text-sm font-semibold text-foreground">
          docker-compose.yml Reference
        </h3>
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
      - "\${API_PORT}:8000"
    environment:
      - DJANGO_PORT=8000`}</code>
        </pre>
        <p className={prose}>
          Containers communicate over the Compose network using service names.
          Muxy maps host-side ports so each workspace is isolated.
        </p>

        <h3 className="mt-4 text-sm font-semibold text-foreground">
          Browser Sessions
        </h3>
        <ul className={list}>
          <li>
            • <code className="text-xs">http://localhost:$FRONTEND_PORT</code> —
            frontend preview.
          </li>
          <li>
            • <code className="text-xs">http://localhost:$API_PORT/admin</code>{" "}
            — Django admin.
          </li>
        </ul>
      </article>

      {/* ── Recipe 5: Next.js + Django, separate repos ────── */}
      <article className={card}>
        <h2 className={heading}>Next.js + Django (Separate Repos)</h2>
        <p className={prose}>
          Frontend and backend live in separate Muxy projects. Because
          environment variables are scoped to a single workspace, the frontend
          workspace must define both ports and run the backend process itself.
        </p>

        <h3 className="mt-4 text-sm font-semibold text-foreground">
          Frontend Project (Project-Level Template)
        </h3>
        <ul className={list}>
          <li>
            • Port definitions: <strong>FRONTEND_PORT</strong>,{" "}
            <strong>BACKEND_PORT</strong>
          </li>
          <li>
            • Process — <strong>Dev Server</strong>:{" "}
            <code className="text-xs">
              API_URL=http://localhost:$BACKEND_PORT PORT=$FRONTEND_PORT npm run
              dev
            </code>
          </li>
          <li>
            • Browser session:{" "}
            <code className="text-xs">http://localhost:$FRONTEND_PORT</code>
          </li>
        </ul>

        <h3 className="mt-4 text-sm font-semibold text-foreground">
          Backend Project (Project-Level Template)
        </h3>
        <ul className={list}>
          <li>
            • Port definitions: <strong>API_PORT</strong>
          </li>
          <li>
            • Process — <strong>Django Server</strong>:{" "}
            <code className="text-xs">
              python manage.py runserver 0.0.0.0:$API_PORT
            </code>
          </li>
          <li>
            • Browser session:{" "}
            <code className="text-xs">
              http://localhost:$API_PORT/admin
            </code>
          </li>
        </ul>

        <h3 className="mt-4 text-sm font-semibold text-foreground">
          Cross-Project Pattern: Workspace Override
        </h3>
        <p className={prose}>
          Ports are only available inside the workspace that defines them. To run
          both services from a single context, override the frontend
          workspace&apos;s settings and add a new process that starts the backend
          from its project directory:
        </p>
        <pre className={code}>
          <code>{`# Added as a workspace-level process override in the frontend workspace
cd /path/to/backend-project && python manage.py runserver 0.0.0.0:$BACKEND_PORT`}</code>
        </pre>
        <p className={prose}>
          This way <code className="text-xs">BACKEND_PORT</code> is reserved by
          the frontend workspace and injected into both the Next.js and Django
          processes. The backend project&apos;s own workspaces continue to use{" "}
          <code className="text-xs">API_PORT</code> independently.
        </p>
        <p className={prose}>
          Use <code className="text-xs">MUXY_WORKSPACE_DIR</code> in setup
          scripts if you need to reference the workspace&apos;s own directory,
          for example to copy shared config files.
        </p>
      </article>
    </DocsShell>
  );
}
