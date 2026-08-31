import type { Metadata } from "next";
import Link from "next/link";
import { DocsShell } from "../../components/docs-shell";
import { code } from "../../components/guide-styles";
import { Prose, Section } from "../../components/section";

export const metadata: Metadata = {
  title: "Guide: Next.js + Django Monorepo (No Docker)",
  description:
    "Cookbook guide for running a full-stack monorepo directly on host with Spaces.",
};

export default function NextjsDjangoMonorepoHostGuidePage() {
  return (
    <DocsShell
      title="Guide: Next.js + Django Monorepo (No Docker)"
      description="Use this when frontend and backend live in one repo and both run directly on your machine."
      pagePath="/docs/guides"
    >
      <Section title="Use Case">
        <Prose>
          One repo with <code>/frontend</code> and <code>/backend</code>.
          You want each workspace to spin up both services with isolated ports and predictable URLs per service.
        </Prose>
      </Section>

      <Section title="Project Settings Explained">

        <h3 className="mt-4 text-sm font-semibold text-foreground">Services</h3>
        <pre className={code}>
          <code>{`frontend
api`}</code>
        </pre>
        <Prose>
          Separate services keep frontend/backend stable per workspace and prevent collisions across branches.
        </Prose>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Setup Script</h3>
        <pre className={code}>
          <code>{`cd frontend && npm i
cd ../backend && pip install -r requirements.txt
cp .env.example .env`}</code>
        </pre>
        <Prose>
          Bootstraps both app layers. The setup script runs in a shell, so chained <code>cd &amp;&amp; ...</code> steps are fine here. Copying <code>.env</code> gives per-workspace config freedom. Symlink centralizes updates but can cause cross-workspace side effects. Swap <code>.env.example</code> for whatever seed file your repo keeps — Spaces does not provide a built-in shared env file.
        </Prose>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Processes</h3>
        <Prose>
          Add two processes. Process commands run as shell input, so <code>cd</code> plus env assignment runs naturally.
        </Prose>
        <pre className={code}>
          <code>{`# frontend process
cd frontend && API_URL=$SPACES_API_URL PORT=$SPACES_FRONTEND_PORT npm run dev`}</code>
        </pre>
        <pre className={code}>
          <code>{`# backend process
cd backend && python manage.py runserver 0.0.0.0:$SPACES_API_PORT`}</code>
        </pre>
        <Prose>
          Frontend points to the workspace backend service. Both processes stay in one workspace context with shared per-service env vars.
        </Prose>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Browser Sessions</h3>
        <Prose>
          Add two browser sessions — each URL is its own entry — so the frontend preview and Django admin are each one focus away.
        </Prose>
        <pre className={code}>
          <code>{`# frontend browser session
$SPACES_FRONTEND_URL`}</code>
        </pre>
        <pre className={code}>
          <code>{`# backend browser session
$SPACES_API_URL/admin`}</code>
        </pre>

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
