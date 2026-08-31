import type { Metadata } from "next";
import Link from "next/link";
import { DocsShell } from "../../components/docs-shell";
import { code } from "../../components/guide-styles";
import { Prose, Section } from "../../components/section";

export const metadata: Metadata = {
  title: "Guide: Next.js (No Docker)",
  description:
    "Cookbook guide for running a single Next.js app directly on host with Spaces project settings.",
};

export default function NextjsHostGuidePage() {
  return (
    <DocsShell
      title="Guide: Next.js (No Docker)"
      description="Use this when your frontend runs directly on your machine (no containers) and you want multiple workspaces with isolated services and stable URLs."
      pagePath="/docs/guides"
    >
      <Section title="Use Case">
        <Prose>
          You have one Next.js repo and run <code>npm run dev</code> directly.
          You want multiple Spaces workspaces active at once, each with isolated services
          and browser tabs.
        </Prose>
      </Section>

      <Section title="Project Settings Explained">

        <h3 className="mt-4 text-sm font-semibold text-foreground">Services</h3>
        <pre className={code}>
          <code>{`frontend`}</code>
        </pre>
        <Prose>
          Declare a named service per workspace. Spaces assigns each service its own local port and a stable URL, so two branches can both run a dev server without collisions.
        </Prose>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Setup Script</h3>
        <pre className={code}>
          <code>{`npm i
cp .env.example .env`}</code>
        </pre>
        <Prose>
          <code>npm i</code> ensures dependencies are present in new workspaces.
          <code>cp</code> creates an independent <code>.env</code> copy per workspace.
          Copy is safer when you want branch-local env edits.
          A symlink keeps one source of truth, but changes affect all workspaces and can cause surprising cross-branch coupling.
          Swap <code>.env.example</code> for any real path you maintain — Spaces does not provide a built-in shared env file.
        </Prose>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Processes</h3>
        <pre className={code}>
          <code>{`PORT=$SPACES_FRONTEND_PORT npm run dev`}</code>
        </pre>
        <Prose>
          This binds Next.js to the service&apos;s assigned local port, so browser sessions target the correct workspace instance.
        </Prose>

        <h3 className="mt-4 text-sm font-semibold text-foreground">Browser Sessions</h3>
        <pre className={code}>
          <code>{`$SPACES_FRONTEND_URL`}</code>
        </pre>
        <Prose>
          Browser session URLs should use named services so each workspace opens its own app tab reliably. <code>$SPACES_FRONTEND_URL</code> resolves to <code>http://frontend.&lt;slug&gt;.localhost:7391</code>, routed by the bundled Caddy proxy. Chrome treats <code>*.localhost</code> as a secure context, so this works over plain HTTP without certificates.
        </Prose>

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
