import type { Metadata } from "next";
import Link from "next/link";
import { DocsShell } from "../../components/docs-shell";
import { list, code } from "../../components/guide-styles";
import { Prose, Section } from "../../components/section";

export const metadata: Metadata = {
  title: "Guide: Next.js (Docker Compose)",
  description:
    "Cookbook guide for running a single Next.js service in Docker Compose with Spaces settings.",
};

export default function NextjsDockerGuidePage() {
  return (
    <DocsShell
      title="Guide: Next.js (Docker Compose)"
      description="Use this when your app runs in containers and you want workspace-isolated host ports with clear container health visibility."
      pagePath="/docs/guides"
    >
      <Section title="Use Case">
        <Prose>
          Your Next.js service runs via Compose. You need branch-isolated environments
          and deterministic port mapping per workspace.
        </Prose>
      </Section>

      <Section title="Project Settings Explained">

        <h3 className="mt-4 text-sm font-semibold text-foreground">Services</h3>
        <pre className={code}>
          <code>{`frontend`}</code>
        </pre>
        <Prose>
          Spaces assigns each service its own host port per workspace. Compose maps host <code>$SPACES_FRONTEND_PORT</code> to container port <code>3000</code>.
        </Prose>
        <h4 className="mt-4 text-sm font-semibold text-foreground">docker-compose.yml example</h4>
        <pre className={code}>
          <code>{`services:
  web:
    build: .
    ports:
      - "\${SPACES_FRONTEND_PORT}:3000"
    environment:
      - PORT=3000`}</code>
        </pre>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Setup Script</h3>
        <pre className={code}>
          <code>{`cp .env.example .env`}</code>
        </pre>
        <Prose>
          Copying <code>.env</code> gives each workspace an isolated env file.
          Symlink can reduce duplication, but one edit impacts all linked workspaces.
          Point <code>cp</code> at whatever seed file your repo keeps — Spaces does not provide a built-in shared env file.
        </Prose>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Processes</h3>
        <pre className={code}>
          <code>{`SPACES_FRONTEND_PORT=$SPACES_FRONTEND_PORT docker compose up --build`}</code>
        </pre>
        <Prose>
          The process keeps Compose attached in one terminal, which is useful for live logs and interactive shutdown.
        </Prose>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Browser Sessions</h3>
        <pre className={code}>
          <code>{`$SPACES_FRONTEND_URL`}</code>
        </pre>
        <Prose>
          This targets the workspace-specific service mapping. Without named services, one workspace can accidentally open another workspace&apos;s frontend.
        </Prose>

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

      </Section>

      <Link
        href="/docs/guides"
        className="mt-4 inline-flex items-center gap-1.5 text-sm font-semibold text-accent transition-colors hover:opacity-80"
      >
        ← Back to Cookbook Guides
      </Link>
    </DocsShell>
  );
}
