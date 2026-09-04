import { parsePatch } from "diff";

/**
 * Pure logic for "open in Editor at the clicked diff line": resolving which rendered diff row a
 * context-menu (or click) event landed on, and mapping that row's diff-side line number to the
 * line the Editor pane should land the caret on. Kept free of DOM event wiring and of
 * `EditorView`/`root.ts` so the mapping rule can be unit tested without a rendered diff or a real
 * `CodeView`.
 */

export interface DiffLineTarget {
  /** Workspace-relative path stamped by `DiffView.decorateRenderedLines` — the file this row
   *  belongs to, current (new) side. */
  path: string;
  /** Which side of the diff the clicked row renders as, per `decorateRenderedLines`: `"old"` for a
   *  deletion (and, in split layout, an old-side context row); `"new"` for everything else. */
  side: "old" | "new";
  /** The line number rendered in that row's gutter, on the side named by `side`. */
  line: number;
}

/**
 * Reads the diff-line stamps (`dataset.diffPath`/`diffSide` plus the line as `dataset.line` on a
 * content row or `dataset.diffLine` on its gutter cell) off the nearest stamped element in
 * `composedPath` — `DiffView.decorateRenderedLines` stamps every rendered row and its line-number
 * cell, but a `contextmenu` target inside pierre's shadow DOM can be a descendant of either (an
 * inline token span, say), so this walks outward from the actual click target rather than assuming
 * it landed on the stamped element itself. `composedPath` must come from `event.composedPath()`: pierre renders
 * inside shadow roots, and a plain `event.target` stops at the outermost one.
 */
export function resolveDiffLineTarget(composedPath: readonly EventTarget[]): DiffLineTarget | undefined {
  for (const target of composedPath) {
    if (!(target instanceof HTMLElement)) continue;
    const { diffPath, diffSide, diffLine } = target.dataset;
    const line = diffLine ?? target.dataset.line;
    if (diffPath === undefined || diffSide === undefined || line === undefined) continue;
    if (diffSide !== "old" && diffSide !== "new") continue;
    const lineNumber = Number(line);
    if (!Number.isInteger(lineNumber) || lineNumber <= 0) continue;
    return { path: diffPath, side: diffSide, line: lineNumber };
  }
  return undefined;
}

/**
 * Maps a clicked diff-row line number to the line Editor mode should land the caret on.
 *
 * New-side rows (additions and ordinary context) show the new file's own line number, so they map
 * to themselves unchanged.
 *
 * Old-side rows only ever name a line that exists on the old side: a deletion, or (in split
 * layout) an old-side context row sharing the deletion block's column. Neither always has a
 * same-numbered line on the new side, so this walks the row's hunk to find one: starting from the
 * row's own position, it advances past the contiguous run of `-` lines that position belongs to
 * (a length-one run for a context row, since a context row is not itself a `-` line) and reports
 * the new-side line number the file has at that position, the nearest kept line after the
 * deletion. That position exists whenever the hunk keeps a line right after the run, or a later
 * hunk proves the file goes on past this one.
 *
 * When the run instead ends the last hunk, whether the file continues depends on the hunk's shape.
 * A hunk that carries context (git's default) would have shown trailing context if any line
 * followed the deletion, so its absence means the deletion reached the end of the file and the last
 * kept line is the answer. A pure-deletion hunk with no context at all (`diff.context=0`, new-side
 * count 0) says nothing about what follows, so the post-deletion position is reported as is; when
 * the file does end there, the editor clamps the line to the document's end itself.
 *
 * Accepted gap: Git configured with BOTH `diff.context=0` and a positive `diff.interHunkContext`
 * can merge neighbouring changes into a last hunk that carries context yet ends in a deletion the
 * file continues past (`+X`, ` A`, `-B` with lines after B). That hunk is indistinguishable here
 * from one whose deletion reaches the end of the file, so the caret lands on the line before the
 * deletion instead of the one after it. The daemon leaves both settings to the user's Git config;
 * pinning them for the pane's diffs was judged not worth a daemon change for a two-non-default
 * settings combination whose only effect is a caret one line off.
 */
export function editorLineForDiffLine(patch: string, side: "old" | "new", line: number): number {
  if (side === "new") return line;

  const [structured] = parsePatch(patch);
  if (structured === undefined) throw new Error(`editorLineForDiffLine: patch has no hunks for old-side line ${line}`);

  for (const [hunkIndex, hunk] of structured.hunks.entries()) {
    const isPureDeletion = hunk.newLines === 0;
    const isLastHunk = hunkIndex === structured.hunks.length - 1;
    let oldLine = hunk.oldStart;
    // Git writes a hunk that keeps nothing on the new side with the line BEFORE the deletion as its
    // new-side start (`+1,0`: removed after new line 1), but `parsePatch` already normalizes a
    // zero-count start up by one, so `newStart` is the position right after the deletion here just
    // as it is the first kept line for every other hunk.
    let newLine = hunk.newStart;
    for (let i = 0; i < hunk.lines.length; i += 1) {
      const text = hunk.lines[i]!;
      if (text.startsWith("-")) {
        if (oldLine === line) {
          let end = i;
          while (end < hunk.lines.length && hunk.lines[end]!.startsWith("-")) end += 1;
          // A "\ No newline at end of file" marker can sit between the run and the kept line that
          // follows it (an unterminated last line replaced by another); it carries no line, so it
          // must not read as the run ending the hunk.
          while (end < hunk.lines.length && hunk.lines[end]!.startsWith("\\")) end += 1;
          const next = hunk.lines[end];
          // Deletions never advance `newLine`, so it already names the position right after the
          // run: the kept line there (context or addition), or, when the run ends the hunk, the
          // line the file continues with. See the doc comment for when that position is known to
          // exist and when the last kept line (one behind it) is reported instead.
          if (next !== undefined && (next.startsWith(" ") || next.startsWith("+"))) return newLine;
          if (!isLastHunk || isPureDeletion) return newLine;
          return Math.max(1, newLine - 1);
        }
        oldLine += 1;
      } else if (text.startsWith("+")) {
        newLine += 1;
      } else if (text.startsWith(" ")) {
        if (oldLine === line) return newLine;
        oldLine += 1;
        newLine += 1;
      }
      // Any other prefix (e.g. "\ No newline at end of file") carries no line number; skip it.
    }
  }
  throw new Error(`editorLineForDiffLine: old-side line ${line} not found in patch`);
}
