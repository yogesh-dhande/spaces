import type { Metadata } from "next";
import { InlineCode } from "../components/code-block";
import { DocsShell } from "../components/docs-shell";
import { DocLink } from "../components/doc-link";
import { Prose, Section } from "../components/section";
import { RefTable } from "../components/ref-table";

export const metadata: Metadata = {
  title: "Environment variables",
  description:
    "The variables Spaces sets for processes, terminals, and scripts in a workspace.",
};

export default function EnvironmentVariablesDocsPage() {
  return (
    <DocsShell
      title="Environment variables"
      description="Spaces sets these variables for every process, terminal, and script that runs in a workspace, so your commands can find their port, URL, and directory without hardcoding them."
      pagePath="/docs/environment-variables"
    >
      <Section id="workspace-variables" title="Workspace variables">
        <RefTable
          columns={["Variable", "Value"]}
          rows={[
            [<InlineCode key="id">SPACES_WORKSPACE_ID</InlineCode>, "the workspace's id"],
            [<InlineCode key="pid">SPACES_PROJECT_ID</InlineCode>, "the project's id"],
            [
              <InlineCode key="slug">SPACES_WORKSPACE_SLUG</InlineCode>,
              <>
                a DNS-safe slug, for example <InlineCode>login-fix-a3f9c2d1847b</InlineCode> (
                <InlineCode>home-1a2b3c4d5e6f</InlineCode> for the home workspace,{" "}
                <InlineCode>~</InlineCode>)
              </>,
            ],
            [<InlineCode key="wdir">SPACES_WORKSPACE_DIR</InlineCode>, "the workspace's directory"],
            [<InlineCode key="pdir">SPACES_PROJECT_DIR</InlineCode>, "the project's directory"],
          ]}
        />
      </Section>

      <Section id="service-variables" title="Service variables">
        <Prose>
          Each declared service gets three variables, named from the service with hyphens turned
          into underscores and uppercased, for example <InlineCode>api-server</InlineCode> becomes{" "}
          <InlineCode>API_SERVER</InlineCode>:
        </Prose>
        <RefTable
          columns={["Variable", "Value"]}
          rows={[
            [<InlineCode key="port">SPACES_&lt;SERVICE&gt;_PORT</InlineCode>, "the assigned local port"],
            [
              <InlineCode key="host">SPACES_&lt;SERVICE&gt;_HOST</InlineCode>,
              <><InlineCode>&lt;service&gt;.&lt;slug&gt;.localhost</InlineCode>, no scheme or port</>,
            ],
            [
              <InlineCode key="url">SPACES_&lt;SERVICE&gt;_URL</InlineCode>,
              <><InlineCode>http://&lt;service&gt;.&lt;slug&gt;.localhost:7391</InlineCode></>,
            ],
          ]}
        />
        <Prose>
          See <DocLink href="/docs/services#ports">Services and URLs</DocLink> for how the port and
          URL are assigned and routed.
        </Prose>
      </Section>

      <Section id="terminal-variables" title="Terminal variables">
        <Prose>
          <InlineCode>SPACES_TERMINAL_TRACKING_ID</InlineCode> identifies the terminal session a
          command is running in. Coding agents read it to report their own lifecycle with{" "}
          <DocLink href="/docs/orchestration#signal">spaces agent signal</DocLink>.
        </Prose>
      </Section>

      <Section id="where-they-apply" title="Where they apply">
        <Prose>
          The workspace and service variables are set for every process, every terminal, and the
          setup and stop scripts. <InlineCode>SPACES_TERMINAL_TRACKING_ID</InlineCode> is set only
          in terminal sessions, since the setup and stop scripts do not run inside a tracked
          terminal. A workspace&apos;s settings dialog has a read-only Environment section that
          lists the values a running process or terminal actually receives, see{" "}
          <DocLink href="/docs/workspaces#workspace-settings">Workspaces</DocLink>.
        </Prose>
      </Section>
    </DocsShell>
  );
}
