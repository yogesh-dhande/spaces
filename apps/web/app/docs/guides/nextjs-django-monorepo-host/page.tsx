import type { Metadata } from "next";
import Link from "next/link";
import { CodeBlock, InlineCode } from "../../components/code-block";
import { DocsShell } from "../../components/docs-shell";
import { Prose, Section, SubHeading } from "../../components/section";

export const metadata: Metadata = {
  title: "Next.js + Django Monorepo (No Docker)",
  description:
    "Recipe for running a full-stack monorepo directly on your machine with Spaces.",
};

export default function NextjsDjangoMonorepoHostGuidePage() {
  return (
    <DocsShell
      title="Next.js + Django Monorepo (No Docker)"
      description="Use this when frontend and backend live in one repo and both run directly on your machine."
      pagePath="/docs/guides/nextjs-django-monorepo-host"
    >
      <Section title="Use case">
        <Prose>
          One repo with <InlineCode>/frontend</InlineCode> and{" "}
          <InlineCode>/backend</InlineCode>. You want each workspace to bring up both services with
          isolated ports and a predictable URL per service.
        </Prose>
      </Section>

      <Section title="Project settings explained">
        <SubHeading>Services</SubHeading>
        <CodeBlock>{`frontend
api`}</CodeBlock>
        <Prose>
          Separate services keep the frontend and backend stable per workspace and prevent them
          colliding across branches.
        </Prose>

        <SubHeading>Setup script</SubHeading>
        <CodeBlock>{`cd frontend && npm i
cd ../backend && pip install -r requirements.txt
cp .env.example .env`}</CodeBlock>
        <Prose>
          Bootstraps both app layers. The setup script runs in a shell, so chained{" "}
          <InlineCode>cd &amp;&amp; ...</InlineCode> steps work here. Copying{" "}
          <InlineCode>.env</InlineCode> gives each workspace its own config; a symlink would
          centralize updates but could cause cross-workspace side effects. Swap{" "}
          <InlineCode>.env.example</InlineCode> for whatever seed file your repo keeps, Spaces has
          no built-in shared env file.
        </Prose>

        <SubHeading>Processes</SubHeading>
        <Prose>
          Add two processes. Process commands run as shell input, so <InlineCode>cd</InlineCode>{" "}
          plus an env assignment runs naturally.
        </Prose>
        <CodeBlock>{`# frontend process
cd frontend && API_URL=$SPACES_API_URL PORT=$SPACES_FRONTEND_PORT npm run dev`}</CodeBlock>
        <CodeBlock>{`# backend process
cd backend && python manage.py runserver 0.0.0.0:$SPACES_API_PORT`}</CodeBlock>
        <Prose>
          The frontend points at the workspace&apos;s own backend service, so both processes share
          the workspace&apos;s per-service variables.
        </Prose>

        <SubHeading>Browser sessions</SubHeading>
        <Prose>
          Add two browser sessions, each its own entry, so the frontend preview and the Django
          admin are each one focus away.
        </Prose>
        <CodeBlock>{`# frontend browser session
$SPACES_FRONTEND_URL`}</CodeBlock>
        <CodeBlock>{`# backend browser session
$SPACES_API_URL/admin`}</CodeBlock>
      </Section>

      <Link
        href="/docs/guides"
        className="mt-4 inline-flex items-center gap-1.5 text-sm font-semibold text-accent transition-colors hover:opacity-80"
      >
        ← All recipes
      </Link>
    </DocsShell>
  );
}
