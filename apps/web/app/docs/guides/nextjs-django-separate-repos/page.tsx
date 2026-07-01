import type { Metadata } from "next";
import Link from "next/link";
import { DocsShell } from "../../components/docs-shell";

export const metadata: Metadata = {
  title: "Guide: Next.js + Django (Separate Repos)",
  description:
    "Cookbook guide for operating frontend and backend from separate repositories with Spaces.",
};

const card = "border-t border-line/70 pt-8 first:border-t-0 first:pt-0";
const prose = "mt-2 text-sm leading-7 text-foreground-soft";
const list = "mt-3 space-y-2 text-sm leading-7 text-foreground-soft";
const code =
  "mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-lg border border-line/70 bg-background-soft/60 p-3 text-xs leading-6 text-foreground";

export default function NextjsDjangoSeparateReposGuidePage() {
  return (
    <DocsShell
      title="Guide: Next.js + Django (Separate Repos)"
      description="Use this when frontend and backend live in different projects but you want one active workspace context for both."
      pagePath="/docs/guides"
    >
      <article className={card}>
        <h2 className="text-2xl font-semibold tracking-tight">Use Case</h2>
        <p className={prose}>
          Frontend and backend are separate repos. You want one workspace to run both processes and keep browser sessions aligned.
        </p>
      </article>

      <article className={card}>
        <h2 className="text-2xl font-semibold tracking-tight">Project Settings</h2>
        <p className={prose}>
          The frontend workspace must own both frontend and backend services and run both processes if it is the central context for both services.
        </p>
        <h3 className="mt-4 text-sm font-semibold text-foreground">Frontend Project Template</h3>
<pre className={code}>
          <code>{`Services: frontend, backend
Frontend Server: API_URL=$SPACES_BACKEND_URL PORT=$SPACES_FRONTEND_PORT npm run dev
Backend Server: cd /path/to/backend-project && python manage.py runserver 0.0.0.0:$SPACES_BACKEND_PORT
Browser Session: $SPACES_FRONTEND_URL`}</code>
        </pre>
        <p className={prose}>
          The backend server is started from the frontend workspace so both processes can receive the same <code>SPACES_&lt;SERVICE&gt;_PORT</code> and <code>SPACES_&lt;SERVICE&gt;_URL</code> env vars Spaces injects for each service. The backend row can change directories directly because process commands run as shell input.
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
