import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";

export const metadata: Metadata = {
  title: "FAQ",
  description: "Common questions about Muxy behavior and boundaries.",
};

const faqs = [
  {
    q: "What is a workspace in Muxy?",
    a: "A workspace is a stream of work with its own runtime context: processes, browser sessions, status checks, captured windows, and reserved ports. For Git projects it is typically backed by a worktree.",
  },
  {
    q: "Can I archive the default workspace?",
    a: "No. The default workspace is protected and cannot be archived.",
  },
  {
    q: "What happens when I archive a workspace?",
    a: "Archive stops all processes and closes tracked windows, releases reserved ports, and marks the workspace archived. For Git projects, the worktree directory is removed but branches are kept.",
  },
  {
    q: "Does Muxy manage window tiling and geometry?",
    a: "No. Muxy manages window context and focus only. Tiling and geometry stay with yabai and your existing setup.",
  },
  {
    q: "How are browser tabs matched to a workspace?",
    a: "By URL prefix from browser session definitions. Muxy intentionally avoids title-based matching to prevent false positives.",
  },
  {
    q: "Does Muxy close my entire Chrome window when stopping a workspace?",
    a: "No. Browser cleanup closes matching tabs only, not entire Chrome windows.",
  },
  {
    q: "How are port conflicts handled?",
    a: "Each workspace reserves ports based on named port definitions (e.g. FRONTEND_PORT, API_PORT). Ports are reserved so they cannot be claimed by other processes between allocation and use. Commands consume the values via environment variables.",
  },
  {
    q: "Can workspace settings diverge from project templates?",
    a: "Yes. Workspace settings start as copies of project templates. After creation, each workspace maintains independent overrides that do not affect the project.",
  },
  {
    q: "What are Muxy's supported browser and terminal apps?",
    a: "Google Chrome for browser sessions and iTerm2 for process terminal windows.",
  },
  {
    q: "Can I customize keyboard shortcuts?",
    a: "Yes. Shortcut overrides are supported through the Settings view.",
  },
  {
    q: "Does Muxy require editor plugins?",
    a: "No. Muxy does not introspect editor internals and does not require extensions.",
  },
];

export default function FaqDocsPage() {
  return (
    <DocsShell
      title="FAQ"
      description="Answers to common questions about workspace behavior, boundaries, and daily workflow."
      pagePath="/docs/faq"
    >
      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Common Questions</h2>
        <div className="mt-4 space-y-4">
          {faqs.map((item) => (
            <section key={item.q} className="rounded-xl border border-line bg-surface/75 p-4">
              <h3 className="text-sm font-semibold text-foreground">{item.q}</h3>
              <p className="mt-2 text-sm leading-7 text-foreground-soft">{item.a}</p>
            </section>
          ))}
        </div>
      </article>

      <article className="rounded-2xl border border-line bg-surface/82 p-5 backdrop-blur-sm">
        <h2 className="text-xl font-semibold tracking-tight">Non-Goals Recap</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• No tiling or geometry management.</li>
          <li>• No exact browser tab-order restoration guarantees.</li>
          <li>• No editor-internal automation or plugin requirement.</li>
          <li>• No secrets management beyond environment variables.</li>
        </ul>
      </article>
    </DocsShell>
  );
}
