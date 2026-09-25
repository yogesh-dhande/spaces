import type { Metadata } from "next";
import Link from "next/link";
import { CodeBlock, InlineCode } from "../../components/code-block";
import { DocsShell } from "../../components/docs-shell";
import { Prose, Section, SubHeading } from "../../components/section";

export const metadata: Metadata = {
  title: "Next.js (Docker Compose)",
  description:
    "Recipe for running a single Next.js service in Docker Compose with Spaces settings.",
};

export default function NextjsDockerGuidePage() {
  return (
    <DocsShell
      title="Next.js (Docker Compose)"
      description="Use this when your app runs in containers and you want workspace-isolated host ports with clear container visibility."
      pagePath="/docs/guides/nextjs-docker"
    >
      <Section title="Use case">
        <Prose>
          Your Next.js service runs through Compose. You need branch-isolated environments and a
          predictable port mapping per workspace.
        </Prose>
      </Section>

      <Section title="Project settings explained">
        <SubHeading>Services</SubHeading>
        <CodeBlock>{`frontend`}</CodeBlock>
        <Prose>
          Spaces assigns each service its own host port per workspace. Compose maps host{" "}
          <InlineCode>$SPACES_FRONTEND_PORT</InlineCode> to container port{" "}
          <InlineCode>3000</InlineCode>.
        </Prose>
        <SubHeading>docker-compose.yml example</SubHeading>
        <CodeBlock>{`services:
  web:
    build: .
    ports:
      - "\${SPACES_FRONTEND_PORT}:3000"
    environment:
      - PORT=3000`}</CodeBlock>

        <SubHeading>Setup script</SubHeading>
        <CodeBlock>{`cp .env.example .env`}</CodeBlock>
        <Prose>
          Copying <InlineCode>.env</InlineCode> gives each workspace its own env file; a symlink
          would reduce duplication, but one edit would then affect every linked workspace. Point{" "}
          <InlineCode>cp</InlineCode> at whatever seed file your repo keeps, Spaces has no built-in
          shared env file.
        </Prose>

        <SubHeading>Processes</SubHeading>
        <CodeBlock>{`SPACES_FRONTEND_PORT=$SPACES_FRONTEND_PORT docker compose up --build`}</CodeBlock>
        <Prose>
          Keeping Compose attached in one terminal is useful for live logs and an interactive
          shutdown.
        </Prose>

        <SubHeading>Browser sessions</SubHeading>
        <CodeBlock>{`$SPACES_FRONTEND_URL`}</CodeBlock>
        <Prose>
          This targets the workspace-specific service mapping. Without a named service, one
          workspace could open another workspace&apos;s frontend by accident.
        </Prose>

        <SubHeading>Stop script: stop vs down</SubHeading>
        <CodeBlock>{`docker compose stop
# or
docker compose down`}</CodeBlock>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>
            <InlineCode>docker compose stop</InlineCode>: stops containers, keeps networks,
            volumes, and containers for a faster resume.
          </li>
          <li>
            <InlineCode>docker compose down</InlineCode>: removes containers and the network, a
            cleaner reset with a slower next startup.
          </li>
          <li>Use <InlineCode>stop</InlineCode> for day-to-day pause and resume, and <InlineCode>down</InlineCode> when you need a clean teardown.</li>
        </ul>
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
