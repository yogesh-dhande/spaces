import type { Metadata } from "next";
import { CodeBlock, InlineCode } from "../components/code-block";
import { DocsShell } from "../components/docs-shell";
import { DocLink } from "../components/doc-link";
import { Prose, Section } from "../components/section";
import { RefTable } from "../components/ref-table";

export const metadata: Metadata = {
  title: "spaces.yaml",
  description:
    "The file that describes a project's setup, services, processes, and browser sessions.",
};

export default function SpacesYamlDocsPage() {
  return (
    <DocsShell
      title="spaces.yaml"
      description="A spaces.yaml file describes a project's setup script, services, processes, and browser sessions, so you can check them into the repo and import them."
      pagePath="/docs/spaces-yaml"
    >
      <Section id="where-it-lives" title="Where it lives">
        <Prose>
          Spaces reads <InlineCode>spaces.yaml</InlineCode> from the project folder: for an
          existing folder project, that folder; for a cloned repository, the default
          workspace&apos;s checkout on its default branch. Spaces reads it when you add a project,
          and again whenever you import it into project settings.
        </Prose>
      </Section>

      <Section id="example" title="Example">
        <CodeBlock>{`version: 1
setup_script: |
  npm install
  cp .env.example .env
stop_script: ""
services:
  - web
processes:
  - name: web
    command: PORT=$SPACES_WEB_PORT npm run dev
    on_exit: none
browser_sessions:
  - name: web
    url: $SPACES_WEB_URL`}</CodeBlock>
      </Section>

      <Section id="keys" title="Keys">
        <RefTable
          columns={["Key", "Value"]}
          rows={[
            [<InlineCode key="version">version</InlineCode>, "1"],
            [<InlineCode key="setup_script">setup_script</InlineCode>, "runs before anything else launches"],
            [<InlineCode key="stop_script">stop_script</InlineCode>, "runs when the workspace stops"],
            [<InlineCode key="services">services</InlineCode>, "a list of service names"],
            [
              <InlineCode key="processes">processes</InlineCode>,
              <>
                a list of <InlineCode>name</InlineCode>, <InlineCode>command</InlineCode>, and{" "}
                <InlineCode>on_exit</InlineCode> (<InlineCode>none</InlineCode>,{" "}
                <InlineCode>notify</InlineCode>, or <InlineCode>restart</InlineCode>)
              </>,
            ],
            [
              <InlineCode key="browser_sessions">browser_sessions</InlineCode>,
              <>
                a list of <InlineCode>name</InlineCode> and <InlineCode>url</InlineCode>
              </>,
            ],
          ]}
        />
      </Section>

      <Section id="validation" title="Validation">
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>A <InlineCode>version</InlineCode> higher than Spaces supports is rejected; omitting it uses the current version.</li>
          <li>Every process and browser session needs a name.</li>
          <li>Service names must be DNS labels, see <DocLink href="/docs/services">Services and URLs</DocLink>.</li>
          <li>Keys Spaces does not recognize are ignored.</li>
        </ul>
      </Section>

      <Section id="import-and-export" title="Import and export">
        <Prose>
          Import previews the file&apos;s settings in project settings without saving them. On a
          Git project, Save offers &ldquo;Update All Workspaces&rdquo; or &ldquo;Project
          Only&rdquo; only when the save carries an import; saving without one never rewrites
          other workspaces. A non-git project has one workspace that shares the project&apos;s
          settings, so every save applies to it directly. Export writes the project&apos;s saved
          settings to <InlineCode>spaces.yaml</InlineCode> and needs no unsaved edits pending.
        </Prose>
      </Section>
    </DocsShell>
  );
}
