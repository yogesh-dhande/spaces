import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";
import { DocLink } from "../components/doc-link";
import { InlineCode } from "../components/code-block";
import { Prose, Section } from "../components/section";

export const metadata: Metadata = {
  title: "Sessions",
  description:
    "Search the past conversations of your coding agents on any device, and resume one in the right workspace or jump to it if it is running.",
};

export default function SessionsDocsPage() {
  return (
    <DocsShell
      title="Sessions"
      description="Sessions searches the conversations your coding agents have kept, so you can find the one where you solved something and pick it back up."
      pagePath="/docs/sessions"
    >
      <Section id="what" title="What it searches">
        <Prose>
          Sessions searches the conversations stored by Claude Code, Codex, opencode, GitHub Copilot
          CLI, pi, and Amp on one device at a time, across all your projects. That includes
          conversations you had before Spaces and ones you never opened in it. Mac and Linux devices
          work the same way, and each searches its own agents&apos; history.
        </Prose>
        <Prose>
          Only what you typed and what the agent replied is searched, not tool calls or their output.
          Runs that were not conversations, such as <InlineCode>claude -p</InlineCode>,{" "}
          <InlineCode>codex exec</InlineCode>, and <InlineCode>opencode run</InlineCode>, are left
          out. A subagent&apos;s work counts as part of the conversation that started it. Spaces
          keeps the search index on the device and builds it in the background, so searching does not
          slow your terminals.
        </Prose>
      </Section>

      <Section id="searching" title="Searching">
        <Prose>
          Every word you type has to match, in any order, and a word matches the start of a word, so{" "}
          <InlineCode>migr</InlineCode> finds &quot;migration&quot;. Put words in double quotes to
          match them together, in order. Case and accents are ignored. All the words must appear in
          one exchange: a prompt of yours together with the agent&apos;s replies to it.
        </Prose>
        <Prose>
          Results are ordered by the most recent matching message, newest first. With nothing typed,
          the list shows every conversation, most recently active first. Each page holds 20; Show more
          loads the next 20. The agents menu next to the device choice limits the search to the agents
          you pick. It lists only agents that have conversations on that device, and it is remembered
          for each device.
        </Prose>
        <Prose>
          The project menu beside it narrows the results to one project, or &quot;All projects&quot;.
          A conversation counts under the project it would open in, so everything listed under a
          project resumes there; conversations from outside every project, and ones with no recorded
          folder, are under ~ (home). The choice is remembered for each device.
        </Prose>
        <Prose>
          The first time a device is searched it may still be indexing. You see what is indexed so far
          with &quot;Indexing N of M sessions&quot;, and the results fill in as it goes. After that,
          the index follows the agents&apos; history, so a conversation you just had shows up in the
          next search.
        </Prose>
      </Section>

      <Section id="results" title="Reading a result">
        <Prose>
          A result shows the conversation&apos;s title (the agent&apos;s own, otherwise your first
          prompt), the matching text with your words emphasized, how long ago it was active, its size
          on disk, the agent, and the workspace it opens in. A conversation you{" "}
          <DocLink href="/docs/coding-agents#pinned-threads">pinned</DocLink> shows the pin&apos;s name
          with a pin mark. One that is running in a terminal on that device is marked Running.
        </Prose>
      </Section>

      <Section id="opening" title="Opening a result">
        <Prose>
          Click a result, or select it with the arrow keys and press Return. If the conversation is
          already running, Spaces takes you to its terminal, wherever it is. Otherwise Spaces resumes
          it in a new terminal. The workspace is the one you pinned it in, if it is pinned; otherwise
          the workspace whose folder contains the conversation&apos;s folder; otherwise the default
          workspace of the project that folder belongs to, including when its worktree has since been
          deleted; otherwise the home workspace.
        </Prose>
        <Prose>
          Claude Code and opencode can only resume from the folder the conversation ran in. If that
          folder is gone, the result says &quot;Folder no longer exists, can&apos;t resume&quot; and
          shows the conversation&apos;s id, which you can copy and mention in a new session to give
          the agent context. The other agents resume in the conversation&apos;s folder when it
          exists and in the workspace&apos;s folder when it does not. A resume that fails shows its
          message on the result.
        </Prose>
      </Section>

      <Section id="mac" title="On the Mac">
        <Prose>
          Open the Sessions row in the sidebar, below Prompts. Choose the device and, optionally, the
          agents and a project, then type in the search field. Results are one list, newest match
          first, and each row names the project and workspace it opens in. The arrow keys move the
          selection and Return opens it. The pane opens on the device you searched last, or this Mac the first time. If that device
          is offline the pane says so and shows no results.
        </Prose>
      </Section>

      <Section id="iphone" title="On iPhone">
        <Prose>
          On the Agents tab, tap the magnifier to open Search Sessions. A Device row and an Agents row
          sit under the search field; the sheet opens on the device you searched last, or the one you
          are using. Tap a result to resume it or jump to it, and the sheet closes onto its terminal.
          Touch and hold a result to copy its conversation id. An offline device shows &quot;is
          offline&quot; in place of results.
        </Prose>
      </Section>
    </DocsShell>
  );
}
