import type { Metadata } from "next";
import { CodeBlock, InlineCode } from "../components/code-block";
import { DocsShell } from "../components/docs-shell";
import { DocLink } from "../components/doc-link";
import { Prose, Section } from "../components/section";

export const metadata: Metadata = {
  title: "Processes",
  description:
    "The long-running commands a workspace starts, and what happens when one exits.",
};

export default function ProcessesDocsPage() {
  return (
    <DocsShell
      title="Processes"
      description="A process is a command you want running whenever the workspace is running, like a dev server, a worker, or a test watcher."
      pagePath="/docs/processes"
    >
      <Section title="What a process is">
        <Prose>
          You configure processes on the project; each workspace gets its own copy it can tweak
          without affecting the project. Each process is a pane in the{" "}
          <DocLink href="/docs/terminals">workspace panel</DocLink>, a target row with a number.
        </Prose>
      </Section>

      <Section id="commands" title="Commands">
        <Prose>
          Each process command is shell input, run through your login shell in the workspace
          directory with the workspace variables set (see{" "}
          <DocLink href="/docs/environment-variables">Environment variables</DocLink>). Plain
          commands such as <InlineCode>npm run dev</InlineCode> run naturally, and so do{" "}
          <InlineCode>cd</InlineCode>, <InlineCode>&amp;&amp;</InlineCode>, pipes, redirects, and
          environment assignments:
        </Prose>
        <CodeBlock>{`PORT=$SPACES_WEB_PORT npm run dev
cd frontend && PORT=$SPACES_WEB_PORT npm run dev
npm run dev | tee .logs/frontend.log`}</CodeBlock>
        <Prose>A command must be non-empty; Spaces leaves parsing to your shell.</Prose>
      </Section>

      <Section id="on-exit" title="On exit">
        <Prose>Pick what happens when the process exits:</Prose>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>
            <strong>none</strong>: mark it exited and move on.
          </li>
          <li>
            <strong>notify</strong>: show a macOS notification, &ldquo;Process Exited&rdquo;, on
            the device that runs the process.
          </li>
          <li>
            <strong>restart</strong>: show &ldquo;Process Restarting&rdquo;, then start it again.
          </li>
        </ul>
        <Prose>
          A Linux device has no notification center, so <InlineCode>notify</InlineCode> shows
          nothing there; the process still shows exited in the sidebar. An exited process shows red
          and raises an alert, see <DocLink href="/docs/alerts">Alerts</DocLink>.
        </Prose>
      </Section>

      <Section id="controlling" title="Controlling one process">
        <Prose>
          The row&apos;s context menu offers Start, Stop, and Restart when they apply. A restart
          keeps its pane in place. If a process exits while it is starting, its output shows in its
          pane.
        </Prose>
      </Section>

      <Section id="editing" title="Editing a process">
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>Adding a process: it appears immediately, and you can launch it directly if the workspace is already running.</li>
          <li>Changing its command: Spaces asks for restart confirmation, since the running process has to be relaunched.</li>
          <li>Changing only its name or on-exit policy: Spaces applies the edit immediately.</li>
          <li>
            Removing a process: Spaces removes it from the workspace&apos;s settings. A copy that
            is running keeps running, and its pane stays open, until you stop it yourself.
          </li>
        </ul>
      </Section>
    </DocsShell>
  );
}
