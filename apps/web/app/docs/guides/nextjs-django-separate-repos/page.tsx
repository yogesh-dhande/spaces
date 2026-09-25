import type { Metadata } from "next";
import Link from "next/link";
import { CodeBlock, InlineCode } from "../../components/code-block";
import { DocsShell } from "../../components/docs-shell";
import { Prose, Section, SubHeading } from "../../components/section";

export const metadata: Metadata = {
  title: "Next.js + Django (Separate Repos)",
  description:
    "Recipe for operating frontend and backend from separate repositories with Spaces.",
};

export default function NextjsDjangoSeparateReposGuidePage() {
  return (
    <DocsShell
      title="Next.js + Django (Separate Repos)"
      description="Use this when frontend and backend live in different projects but you want one active workspace context for both."
      pagePath="/docs/guides/nextjs-django-separate-repos"
    >
      <Section title="Use case">
        <Prose>
          Frontend and backend are separate repos. You want one workspace to run both processes
          and keep their browser sessions aligned.
        </Prose>
      </Section>

      <Section title="Project settings">
        <Prose>
          The frontend project owns both the frontend and backend services and runs both
          processes, since it is the workspace that serves as the shared context for both.
        </Prose>
        <SubHeading>Frontend project settings</SubHeading>
        <CodeBlock>{`Services: frontend, backend
Frontend process: API_URL=$SPACES_BACKEND_URL PORT=$SPACES_FRONTEND_PORT npm run dev
Backend process: cd /path/to/backend-project && python manage.py runserver 0.0.0.0:$SPACES_BACKEND_PORT
Browser session: $SPACES_FRONTEND_URL`}</CodeBlock>
        <Prose>
          The backend process starts from the frontend workspace so both processes receive the
          same <InlineCode>SPACES_&lt;SERVICE&gt;_PORT</InlineCode> and{" "}
          <InlineCode>SPACES_&lt;SERVICE&gt;_URL</InlineCode> variables Spaces sets for each
          service. The backend command can <InlineCode>cd</InlineCode> into the other repo
          directly, since a process command runs as shell input.
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
