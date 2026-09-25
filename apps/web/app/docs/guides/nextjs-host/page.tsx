import type { Metadata } from "next";
import Link from "next/link";
import { CodeBlock, InlineCode } from "../../components/code-block";
import { DocsShell } from "../../components/docs-shell";
import { Prose, Section, SubHeading } from "../../components/section";

export const metadata: Metadata = {
  title: "Next.js (No Docker)",
  description:
    "Recipe for running a single Next.js app directly on your machine with Spaces project settings.",
};

export default function NextjsHostGuidePage() {
  return (
    <DocsShell
      title="Next.js (No Docker)"
      description="Use this when your frontend runs directly on your machine, no containers, and you want multiple workspaces with isolated services and stable URLs."
      pagePath="/docs/guides/nextjs-host"
    >
      <Section title="Use case">
        <Prose>
          You have one Next.js repo and run <InlineCode>npm run dev</InlineCode> directly. You want
          multiple Spaces workspaces active at once, each with its own service and browser tab.
        </Prose>
      </Section>

      <Section title="Project settings explained">
        <SubHeading>Services</SubHeading>
        <CodeBlock>{`frontend`}</CodeBlock>
        <Prose>
          Declaring a named service gives each workspace its own local port and a stable URL, so
          two branches can both run a dev server without colliding.
        </Prose>

        <SubHeading>Setup script</SubHeading>
        <CodeBlock>{`npm i
cp .env.example .env`}</CodeBlock>
        <Prose>
          <InlineCode>npm i</InlineCode> makes sure dependencies are present in every workspace.{" "}
          <InlineCode>cp</InlineCode> gives each workspace its own{" "}
          <InlineCode>.env</InlineCode> copy, so branch-local env edits do not leak between
          workspaces; a symlink would keep one source of truth but couple every workspace&apos;s
          env together. Swap <InlineCode>.env.example</InlineCode> for whatever seed file your repo
          keeps, Spaces has no built-in shared env file.
        </Prose>

        <SubHeading>Processes</SubHeading>
        <CodeBlock>{`PORT=$SPACES_FRONTEND_PORT npm run dev`}</CodeBlock>
        <Prose>
          This binds Next.js to the service&apos;s assigned local port, so each browser session
          opens the right workspace&apos;s instance.
        </Prose>

        <SubHeading>Browser sessions</SubHeading>
        <CodeBlock>{`$SPACES_FRONTEND_URL`}</CodeBlock>
        <Prose>
          Point a browser session at the named service so each workspace opens its own app tab
          reliably. <InlineCode>$SPACES_FRONTEND_URL</InlineCode> resolves to{" "}
          <InlineCode>http://frontend.&lt;slug&gt;.localhost:7391</InlineCode>. Chrome treats{" "}
          <InlineCode>*.localhost</InlineCode> as a secure address, so this works over plain HTTP
          with no certificate.
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
