import type { Metadata } from "next";
import { DocsShell } from "../components/docs-shell";
import { DocLink } from "../components/doc-link";
import { Prose, Section } from "../components/section";

export const metadata: Metadata = {
  title: "Prompts",
  description:
    "Save prompts you reuse and copy one into any terminal from the Mac, the command palette, or your iPhone.",
};

export default function PromptsDocsPage() {
  return (
    <DocsShell
      title="Prompts"
      description="Prompts keeps the instructions you give coding agents again and again, so you can copy one into any terminal instead of retyping it."
      pagePath="/docs/prompts"
    >
      <Section id="saved" title="What a saved prompt is">
        <Prose>
          A saved prompt is a title and some text, up to 100 KB. Both are required. Prompts belong to
          you, not to a project or workspace, so every prompt is available from every terminal.
        </Prose>
        <Prose>
          Each device keeps its own prompts, and the Mac and iPhone show them as one list across every
          device you can reach. A device that is offline or incompatible has its prompts hidden until
          it is back (see <DocLink href="/docs/troubleshooting">Troubleshooting</DocLink>). Prompts are
          listed most recently copied first, and a new prompt counts as just copied. Saving an edit does
          not move a prompt.
        </Prose>
      </Section>

      <Section id="mac" title="On the Mac">
        <Prose>
          Open the Prompts row in the sidebar, under Resources; it shows how many prompts you have. The
          table lists each prompt&apos;s title, a one-line preview, how long ago it was used, and a Copy
          button. With more than one device paired it also names the device (this Mac reads &quot;This
          Mac&quot;). Search matches the title and the text.
        </Prose>
        <Prose>
          Click a row to edit it in place: its title becomes editable and the full text opens below.
          Discard and Save appear once you change something, and the editor says &quot;Edited · not
          saved&quot;. Copy on the open row copies what is in the editor, saved or not, without saving
          it, and reads &quot;Copy edited&quot; while there are unsaved changes. Click the row again
          or press Esc to close it. New prompt starts an empty one; with more than one device
          paired, you choose which device keeps it, starting with this Mac. Delete asks first.
        </Prose>
        <Prose>
          Moving to another prompt, or to another sidebar row, with unsaved edits asks whether to
          Save, Discard, or Cancel. If you leave the pane another way, such as the command palette,
          your draft is kept until you come back. Quitting Spaces drops it.
        </Prose>
      </Section>

      <Section id="palette" title="From the command palette">
        <Prose>
          Open the <DocLink href="/docs/window-management#command-palette">command palette</DocLink> and
          start typing. Matching prompts are listed after the terminals, and choosing one copies it,
          closes the palette, and shows a Copied confirmation. Press <code>⌘V</code> in the terminal
          you were in to paste.
        </Prose>
      </Section>

      <Section id="iphone" title="On iPhone">
        <Prose>
          In a terminal, tap the Prompts key beside the composer. A sheet lists your prompts with a
          search field; tap Copy on one to put it on the clipboard and close the sheet, then paste into
          the session. Tap a row to open the prompt and edit it, swipe a row to delete it, and tap the
          plus in the sheet&apos;s navigation bar to write a new one. As on the Mac, leaving a prompt
          with unsaved edits asks Save, Discard, or Cancel.
        </Prose>
      </Section>

      <Section id="edits" title="Editing from two places">
        <Prose>
          If two devices edit the same prompt, the last save wins. A prompt you are editing keeps your
          unsaved text when it changes elsewhere; a prompt you have not touched updates to the new text.
        </Prose>
      </Section>
    </DocsShell>
  );
}
