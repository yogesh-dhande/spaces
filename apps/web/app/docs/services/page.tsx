import type { Metadata } from "next";
import { CodeBlock, InlineCode } from "../components/code-block";
import { DocsShell } from "../components/docs-shell";
import { DocLink } from "../components/doc-link";
import { Prose, Section } from "../components/section";

export const metadata: Metadata = {
  title: "Services and URLs",
  description:
    "Named services get a port per workspace and a stable URL that stays the same across restarts.",
};

export default function ServicesDocsPage() {
  return (
    <DocsShell
      title="Services and URLs"
      description="A service is a named endpoint your project exposes, like web or api. Spaces gives every workspace its own port for that service and a stable, predictable URL."
      pagePath="/docs/services"
    >
      <Section title="What a service is">
        <Prose>
          You declare services on the project, the same way you declare processes and browser
          sessions. Each service name is a DNS label: lowercase letters, digits, and hyphens,
          starting and ending with a letter or digit, up to 63 characters, such as{" "}
          <InlineCode>web</InlineCode>, <InlineCode>api</InlineCode>, or{" "}
          <InlineCode>admin-ui</InlineCode>. Every workspace gets its own port for each service, so
          two workspaces of the same project never share one.
        </Prose>
      </Section>

      <Section id="ports" title="Ports">
        <Prose>
          Ports are assigned from 20000 to 30000, for example <InlineCode>24817</InlineCode>. A
          service&apos;s port stays assigned to its workspace for the workspace&apos;s life,
          including while it is stopped, and is released only when the workspace is deleted. Adding
          a service reserves its port right away, so you do not need to relaunch the workspace to
          use it.
        </Prose>
        <Prose>
          Your process reads its port from <InlineCode>SPACES_&lt;SERVICE&gt;_PORT</InlineCode>,
          see{" "}
          <DocLink href="/docs/environment-variables#service-variables">
            Environment variables
          </DocLink>
          . While a workspace is running, its assigned ports are not held open; if another process
          on the device that runs the workspace (this Mac, or the paired Mac or Linux machine that
          owns it) claims one before your server binds it, resolve the conflict on that device.
        </Prose>
      </Section>

      <Section id="stable-urls" title="Stable URLs">
        <Prose>Each service routes to a predictable URL:</Prose>
        <CodeBlock>{`http://<service>.<workspace-slug>.localhost:7391`}</CodeBlock>
        <Prose>
          The port is <InlineCode>7391</InlineCode>, with no setting to change it. Routing is plain
          HTTP on that port and listens only on your Mac, since Chrome treats{" "}
          <InlineCode>*.localhost</InlineCode> as a secure loopback address and needs no certificate
          or setup for it.
        </Prose>
        <Prose>
          The workspace slug is built from the branch name for a Git workspace (for example{" "}
          <InlineCode>login-fix-a3f9c2d1847b</InlineCode>) or the project name for a folder project,
          followed by a hash of the workspace&apos;s id; the home workspace (<InlineCode>~</InlineCode>)
          uses that same form, for example <InlineCode>home-1a2b3c4d5e6f</InlineCode>. Because each
          workspace gets its own hostname, cookies and local storage never carry over between
          workspaces: logging in on one branch does not log you into another.
        </Prose>
      </Section>

      <Section id="browsers" title="Browsers">
        <Prose>
          Chrome is the supported browser: it resolves <InlineCode>*.localhost</InlineCode> names
          without configuration. Firefox does not resolve arbitrary{" "}
          <InlineCode>*.localhost</InlineCode> names by default. A{" "}
          <DocLink href="/docs/browser-sessions">browser session</DocLink> opens a service URL in
          Chrome when you focus it.
        </Prose>
      </Section>

      <Section id="remote-devices" title="Services on a remote device">
        <Prose>
          A remote Mac or Linux machine does not route service URLs itself. When you focus a
          browser session for a service running on a remote workspace, your Mac forwards that
          service&apos;s port to itself over SSH and routes it at the same stable URL, so the URL
          works the same whether the workspace is local or remote. Remote workspace processes still
          receive <InlineCode>SPACES_&lt;SERVICE&gt;_URL</InlineCode>, so a server can allowlist the
          browser-facing host for CORS or framework host checks.
        </Prose>
      </Section>

      <Section title="Adding and removing services">
        <Prose>
          Add or remove services in project or workspace settings, or in{" "}
          <DocLink href="/docs/spaces-yaml">spaces.yaml</DocLink>.
        </Prose>
      </Section>
    </DocsShell>
  );
}
