import type { Metadata } from "next";
import Link from "next/link";
import { CodeBlock, InlineCode } from "../../components/code-block";
import { DocsShell } from "../../components/docs-shell";
import { Prose, Section, SubHeading } from "../../components/section";

export const metadata: Metadata = {
  title: "Next.js + Django Monorepo (Docker)",
  description:
    "Recipe for a containerized full-stack monorepo with Spaces workspace settings.",
};

export default function NextjsDjangoMonorepoDockerGuidePage() {
  return (
    <DocsShell
      title="Next.js + Django Monorepo (Docker)"
      description="Use this when both frontend and backend are in one repo and run through Docker Compose."
      pagePath="/docs/guides/nextjs-django-monorepo-docker"
    >
      <Section title="Use case">
        <Prose>
          You need reproducible containerized frontend and backend environments per workspace,
          with host ports isolated by Spaces.
        </Prose>
      </Section>

      <Section title="Project settings explained">
        <SubHeading>Services</SubHeading>
        <CodeBlock>{`frontend
api`}</CodeBlock>
        <Prose>Spaces allocates a host port per service per workspace; Compose maps them to container ports.</Prose>
        <SubHeading>docker-compose.yml example</SubHeading>
        <CodeBlock>{`services:
  frontend:
    build: ./frontend
    ports:
      - "\${SPACES_FRONTEND_PORT}:3000"
    environment:
      - API_URL=http://backend:8000

  backend:
    build: ./backend
    ports:
      - "\${SPACES_API_PORT}:8000"`}</CodeBlock>

        <SubHeading>Setup script</SubHeading>
        <CodeBlock>{`cp .env.example .env`}</CodeBlock>
        <Prose>
          Keeps workspace configuration predictable; the same isolation-versus-centralized-updates
          tradeoff applies between copy and symlink. Point <InlineCode>cp</InlineCode> at whatever
          seed file your repo keeps, Spaces has no built-in shared env file.
        </Prose>

        <SubHeading>Process</SubHeading>
        <CodeBlock>{`SPACES_FRONTEND_PORT=$SPACES_FRONTEND_PORT SPACES_API_PORT=$SPACES_API_PORT docker compose up --build`}</CodeBlock>
        <Prose>One Compose process starts both services and streams their logs in a single terminal.</Prose>

        <SubHeading>Browser sessions</SubHeading>
        <Prose>Add two browser sessions, one URL per entry, so each opens as a Chrome tab when you focus it.</Prose>
        <CodeBlock>{`# frontend browser session
$SPACES_FRONTEND_URL`}</CodeBlock>
        <CodeBlock>{`# backend browser session
$SPACES_API_URL/admin`}</CodeBlock>
        <Prose>Named-service URLs keep each browser target tied to the correct workspace instance.</Prose>

        <SubHeading>Stop command strategy</SubHeading>
        <CodeBlock>{`# normal pause
docker compose stop

# full cleanup reset
docker compose down`}</CodeBlock>
        <Prose>
          Prefer <InlineCode>stop</InlineCode> for faster day-to-day iteration; use{" "}
          <InlineCode>down</InlineCode> when you need to tear down the network and container
          state.
        </Prose>
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
