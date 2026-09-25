import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";
import { Prose, Section } from "../components/section";

export const metadata: Metadata = {
  title: "The Editor",
  description:
    "Review a workspace's changes, edit files with previews, and send line comments to a coding agent.",
};

export default function EditorDocsPage() {
  return (
    <DocsShell
      title="The Editor"
      description="One window reviews a workspace's diff, edits its files, and sends line comments to whichever coding agent is running there."
      pagePath="/docs/editor"
    >
      <Section id="opening" title="Opening">
        <Prose>
          Open the Editor with <code>⌘⌥E</code> or &quot;Open in Editor&quot; on a sidebar row.
          There is one Editor window: it follows the sidebar selection and remembers each
          workspace&apos;s own saved mode; the first time it opens a workspace, a Git workspace
          starts in Diff and a folder workspace in Editor. Stopping or restarting the workspace it
          shows doesn&apos;t close it.
        </Prose>
      </Section>

      <Section id="diff" title="Diff">
        <Prose>
          The toolbar&apos;s Compare button names the current scope and opens a menu:
          &quot;Uncommitted&quot;, &quot;Last commit&quot;, a &quot;vs &lt;base branch&gt;&quot;
          preset (only when the workspace has a configured base branch), &quot;Branch…&quot;, or
          &quot;Commit or ref…&quot;.
        </Prose>
      </Section>

      <Section id="editing" title="Editing">
        <Prose>
          Files and Changes lists show each entry with a file-type icon. <code>⌘P</code> opens a
          file by name. A file or folder row&apos;s context menu offers &quot;New file&quot;,
          &quot;New folder&quot;, &quot;Rename&quot;, &quot;Move to…&quot;, and &quot;Delete&quot;,
          plus &quot;Open in system viewer&quot; for a file the Editor can&apos;t open as text
          (workspaces on this Mac only). Edits save themselves about 0.8 seconds after you stop
          typing; <code>⌘S</code> saves at once.
        </Prose>
      </Section>

      <Section id="previews" title="Previews">
        <ul className="mt-3 space-y-2 text-sm leading-7 text-foreground-soft">
          <li>• Markdown: Split, Source, or Preview.</li>
          <li>• JSON: a read-only Tree, or Text for editing.</li>
          <li>• SVG: a rendered Preview over an editable Source.</li>
          <li>• CSV and TSV: a read-only Table, or Text.</li>
          <li>• Images: fit to the pane, with pixel dimensions and byte size shown.</li>
        </ul>
      </Section>

      <Section id="comments" title="Line comments">
        <Prose>
          In Diff mode, clicking a line&apos;s gutter opens a draft comment card with a primary
          &quot;Send to &lt;agent&gt;&quot;, which sends it right away, and a secondary &quot;Add
          to batch&quot;. The toolbar&apos;s &quot;Send batch · n&quot; button sends every draft
          with text, whether or not it was marked batched.
        </Prose>
      </Section>

      <Section id="other-editors" title="Other editors">
        <Prose>
          Settings → General → &quot;Preferred editor&quot; lists Built-in first, then whichever
          of VS Code, Devin Desktop, and Zed are installed on your Mac. With another editor
          chosen, <code>⌘⌥E</code> and &quot;Open in Editor&quot; open the workspace there instead
          of the built-in Editor window.
        </Prose>
      </Section>
    </DocsShell>
  );
}
