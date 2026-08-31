import type { Metadata } from "next";
import Link from "next/link";
import { DocsShell } from "../../components/docs-shell";
import { code } from "../../components/guide-styles";
import { Prose, Section } from "../../components/section";

export const metadata: Metadata = {
  title: "Guide: Next.js + Django (Separate Repos)",
  description:
    "Cookbook guide for operating frontend and backend from separate repositories with Spaces.",
};

export default function NextjsDjangoSeparateReposGuidePage() {
  return (
    <DocsShell
      title="Guide: Next.js + Django (Separate Repos)"
      description="Use this when frontend and backend live in different projects but you want one active workspace context for both."
      pagePath="/docs/guides"
    >
      <Section title="Use Case">
        <Prose>
          Frontend and backend are separate repos. You want one workspace to run both processes and keep browser sessions aligned.
        </Prose>
      </Section>

      <Section title="Project Settings">
        <Prose>
          The frontend workspace must own both frontend and backend services and run both processes if it is the central context for both services.
        </Prose>
        <h3 className="mt-4 text-sm font-semibold text-foreground">Frontend Project Template</h3>
<pre className={code}>
          <code>{`Services: frontend, backend
Frontend Server: API_URL=$SPACES_BACKEND_URL PORT=$SPACES_FRONTEND_PORT npm run dev
Backend Server: cd /path/to/backend-project && python manage.py runserver 0.0.0.0:$SPACES_BACKEND_PORT
Browser Session: $SPACES_FRONTEND_URL`}</code>
        </pre>
        <Prose>
          The backend server is started from the frontend workspace so both processes can receive the same <code>SPACES_&lt;SERVICE&gt;_PORT</code> and <code>SPACES_&lt;SERVICE&gt;_URL</code> env vars Spaces injects for each service. The backend row can change directories directly because process commands run as shell input.
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
