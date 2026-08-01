import type { Metadata } from "next";
import Link from "next/link";
import { DocsShell } from "../components/docs-shell";

export const metadata: Metadata = {
  title: "Services",
  description: "Named services, stable per-workspace URLs, and the bundled Caddy proxy.",
};

export default function ServicesDocsPage() {
  return (
    <DocsShell
      title="Services"
      description="A service is a named endpoint your project exposes — like web or api. Spaces gives every workspace its own port for that service and routes it to a stable, predictable URL."
      pagePath="/docs/services"
    >
      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">What Is a Service?</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          You configure services on the project, the same way you configure processes and browser sessions. Each service is a unique DNS-safe name — lowercase letters, digits, and hyphens, starting and ending with a letter or digit, up to 63 characters — such as <code>web</code>, <code>api</code>, or <code>admin-ui</code>.
        </p>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Every workspace gets its own dynamically assigned local port for each service. Two workspaces of the same project never share a port, so you can run several branches of the same app at once without hand-assigning ports or editing <code>.env</code> files.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Stable URLs Through Caddy</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          A bundled Caddy reverse proxy runs on your Mac and routes each service to a predictable URL:
        </p>
        <pre className="mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-sm border border-line/70 bg-background-soft/60 p-3 text-xs leading-6 text-foreground">
          <code>{`http://<service>.<workspace-slug>.localhost:7391`}</code>
        </pre>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• The router port is <code>7391</code>. There is no user-facing setting to change it.</li>
          <li>• Routing is plain HTTP on that shared port and listens only on loopback addresses — no TLS, certificate, or admin setup, since Chrome and Safari treat <code>*.localhost</code> as a secure context.</li>
          <li>• Chrome is the supported browser. Firefox does not resolve arbitrary <code>*.localhost</code> names by default.</li>
          <li>• Caddy routes every service host whether or not it has a browser session attached.</li>
        </ul>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Because each workspace routes through its own hostname rather than a shared <code>localhost</code> port, browser cookies and local storage never bleed between workspaces — logging in on one branch does not log you into another.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Environment Variables</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Every process, setup script, and stop script in the workspace runs with these variables for each service — <code><ServiceToken>web</ServiceToken></code> becomes <code><ServiceToken>WEB</ServiceToken></code>, <code>admin-ui</code> becomes <code>ADMIN_UI</code>:
        </p>
        <pre className="mt-3 w-full max-w-full min-w-0 overflow-x-auto whitespace-pre-wrap break-words rounded-sm border border-line/70 bg-background-soft/60 p-3 text-xs leading-6 text-foreground">
          <code>
            {"SPACES_"}<ServiceToken>WEB</ServiceToken>{"_PORT   # assigned local port, e.g. 51234\n"}
            {"SPACES_"}<ServiceToken>WEB</ServiceToken>{"_HOST   # routed hostname, no scheme or port\n"}
            {"SPACES_"}<ServiceToken>WEB</ServiceToken>{"_URL    # routed URL, e.g. http://"}<ServiceToken>web</ServiceToken>{".my-branch.localhost:7391"}
          </code>
        </pre>
        <p className="mt-3 text-sm leading-7 text-foreground-soft">
          Bind your dev server to <code>$SPACES_WEB_PORT</code> and reference <code>$SPACES_WEB_URL</code> directly instead of composing a URL by hand — see{" "}
          <Link href="/docs/processes" className="text-accent hover:underline">
            Processes
          </Link>{" "}
          for how these variables reach a running command.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Remote & Linux Workspaces</h2>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Remote and Linux daemons do not run the Caddy router themselves. When the Mac app observes a running remote workspace with named services, it opens one SSH local-forward per assigned service port and registers Caddy routes on your Mac to those forwards — so the same stable URL works whether the workspace is local or remote.
        </p>
        <p className="mt-2 text-sm leading-7 text-foreground-soft">
          Remote and Linux workspace processes still receive <code>SPACES_&lt;SERVICE&gt;_URL</code>, so app servers can allowlist the browser-facing host or origin for CORS and framework host checks.
        </p>
      </article>

      <article className="border-t border-line/70 pt-8 first:border-t-0 first:pt-0">
        <h2 className="text-2xl font-semibold tracking-tight">Adding & Removing Services</h2>
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Adding a service reserves its port immediately — you don&apos;t need to relaunch the workspace to use it.</li>
          <li>• A service&apos;s port stays assigned to its workspace until that workspace is deleted, even while the workspace is stopped.</li>
          <li>• While a workspace is running, its assigned ports are not placeholder-reserved on your machine; if another local process claims one first, resolve the conflict manually before your server binds it.</li>
        </ul>
      </article>
    </DocsShell>
  );
}

// Highlights the service name inside a variable or URL so its every
// occurrence reads as the same token, e.g. SPACES_WEB_URL vs web.my-branch.localhost.
function ServiceToken({ children }: { children: string }) {
  return <span className="text-accent-2">{children}</span>;
}
