import { CodePaneAgentSummary, DiffFileEntry, ReviewCommentSide, SpacesReviewComment } from "../bridge/types";

/**
 * Pure logic for the diff-mode comment surface: line-content extraction from a raw unified-diff
 * patch, re-anchoring drafts against a live diff refresh, assigned-agent auto-default selection,
 * and the send-text formatter. Kept DOM-free and bridge-free (mirrors `state.ts`'s
 * `codePaneReducer` pattern) so it is unit-testable without mocking `@pierre/diffs` or the
 * bridge — see `test/reviewComments.test.ts`. `commentsController.ts` is the DOM/bridge layer
 * that calls into this module.
 */

export interface DiffLineRecord {
  side: ReviewCommentSide;
  lineNumber: number;
  text: string;
}

const HUNK_HEADER = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/;

/**
 * Parses a git unified diff patch into one record per rendered line per side. Used both to
 * capture a comment's `lineText` at creation time and, in `reanchorComments`, to search for the
 * nearest matching line after the diff changes underneath a draft.
 *
 * A custom parser rather than reading `@pierre/diffs`' own `FileDiffMetadata` (`hunks` /
 * `deletionLines` / `additionLines`): that structure indexes lines for the library's own
 * rendering needs (partial-diff expansion, collapsed-context offsets), which does not map
 * cleanly back onto plain "side + line number + text" without reverse-engineering internals this
 * bundle has no other reason to depend on. Operating directly on the raw patch text `root.ts`
 * already holds keeps this fully independent of the rendering library.
 */
export function extractDiffLines(patch: string): DiffLineRecord[] {
  const records: DiffLineRecord[] = [];
  let oldLine = 0;
  let newLine = 0;
  let inHunk = false;
  for (const raw of patch.split("\n")) {
    const hunkMatch = HUNK_HEADER.exec(raw);
    if (hunkMatch) {
      oldLine = Number(hunkMatch[1]);
      newLine = Number(hunkMatch[2]);
      inHunk = true;
      continue;
    }
    if (!inHunk) continue; // still inside the "diff --git"/"index"/"---"/"+++" preamble
    if (raw.startsWith("\\")) continue; // "\ No newline at end of file"
    const marker = raw[0];
    const text = raw.slice(1);
    if (marker === " ") {
      records.push({ side: "old", lineNumber: oldLine, text });
      records.push({ side: "new", lineNumber: newLine, text });
      oldLine += 1;
      newLine += 1;
    } else if (marker === "-") {
      records.push({ side: "old", lineNumber: oldLine, text });
      oldLine += 1;
    } else if (marker === "+") {
      records.push({ side: "new", lineNumber: newLine, text });
      newLine += 1;
    }
  }
  return records;
}

export interface CommentPosition {
  lineNumber: number;
  /** True when there is no real line to anchor to anymore (the file is present but `lineText`
   *  no longer matches anything on `comment.side`) — rendered as a file-level pin (`lineNumber: 0`
   *  in `@pierre/diffs`' annotation convention) rather than against a specific line. */
  outdated: boolean;
}

export interface AnchoredComment {
  comment: SpacesReviewComment;
  /** `undefined` when `comment.filePath` itself is no longer in the diff — there is no diff item
   *  left to attach an annotation to, so this comment renders in the batch tray only. */
  position: CommentPosition | undefined;
}

/**
 * Re-anchors every draft against the current file set: exact match (same file/side/lineNumber
 * still has the same text) stays put; otherwise the nearest same-side line in the same file whose
 * text still matches `lineText` wins (nearest by absolute distance from the original line number,
 * ties broken toward the smaller line number for determinism); otherwise the comment is outdated
 * (file present, content gone) or, if the file itself is gone, has no position at all.
 *
 * Deliberately does not re-fetch drafts from the bridge — see `commentsController.ts`'s doc
 * comment on why comments are held in memory and only re-anchored, not re-listed, on every
 * refresh.
 */
export function reanchorComments(
  comments: readonly SpacesReviewComment[],
  files: readonly DiffFileEntry[],
): AnchoredComment[] {
  const fileByPath = new Map(files.map((f) => [f.path, f]));
  return comments.map((comment): AnchoredComment => {
    const file = fileByPath.get(comment.filePath);
    if (!file) return { comment, position: undefined };

    const sideLines = extractDiffLines(file.patch ?? "").filter((line) => line.side === comment.side);
    const exact = sideLines.find((line) => line.lineNumber === comment.lineNumber && line.text === comment.lineText);
    if (exact) return { comment, position: { lineNumber: exact.lineNumber, outdated: false } };

    const candidates = sideLines.filter((line) => line.text === comment.lineText);
    if (candidates.length > 0) {
      const nearest = candidates.reduce((best, candidate) => {
        const bestDelta = Math.abs(best.lineNumber - comment.lineNumber);
        const candidateDelta = Math.abs(candidate.lineNumber - comment.lineNumber);
        if (candidateDelta < bestDelta) return candidate;
        if (candidateDelta === bestDelta && candidate.lineNumber < best.lineNumber) return candidate;
        return best;
      });
      return { comment, position: { lineNumber: nearest.lineNumber, outdated: false } };
    }

    return { comment, position: { lineNumber: 0, outdated: true } };
  });
}

/**
 * Auto-default rule for the assigned-agent selection, applied both at initial load and whenever
 * `spaces:agents` reports a changed running-agent set: a manual (or previously auto-picked) agent
 * stays selected as long as it is still present, regardless of what else changed in the set;
 * otherwise the same rule that runs at startup applies again — exactly one running agent is
 * auto-selected, any other count (zero, or more than one with none chosen) leaves selection
 * `undefined` so the toolbar shows the picker (or the no-agent disabled state).
 */
export function selectDefaultAgentId(
  agents: readonly CodePaneAgentSummary[],
  currentSelectedId: string | undefined,
): string | undefined {
  if (currentSelectedId !== undefined && agents.some((agent) => agent.id === currentSelectedId)) {
    return currentSelectedId;
  }
  return agents.length === 1 ? agents[0]!.id : undefined;
}

/**
 * The line number to show/send for an anchored comment: the re-anchored position when one exists
 * and is still current, falling back to the comment's original `lineNumber` otherwise. An outdated
 * position (the file is present but `lineText` no longer matches anywhere on `comment.side`) or a
 * missing one (the file itself is gone from the diff) has nothing better to point at than the
 * number captured at creation time — the quoted `lineText` is the real locator in that case, not
 * the number. Shared by `formatReviewCommentsText` and `commentsController.ts`'s batch tray row
 * label so the two never disagree about which number is "the" line for a given comment.
 */
export function anchoredLineNumber(ac: AnchoredComment): number {
  return ac.position && !ac.position.outdated ? ac.position.lineNumber : ac.comment.lineNumber;
}

/**
 * Formats one or more comments into the exact text sent to the agent's terminal session (used
 * identically for a single "Send to <label>" and for "Send batch"). Trailing newline included.
 *
 * Takes `AnchoredComment`s (not raw `SpacesReviewComment`s) so the line number sent to the agent
 * reflects where the comment's line actually is *now* (see `anchoredLineNumber`), rather than the
 * possibly-stale line number captured when the comment was first created — surrounding edits can
 * shift a diff's line numbers well before an agent reads this text.
 */
export function formatReviewCommentsText(comments: readonly AnchoredComment[]): string {
  const blocks = comments.map((ac) => {
    const comment = ac.comment;
    const suffix = comment.side === "old" ? " (removed line)" : "";
    return `${comment.filePath}:${anchoredLineNumber(ac)}${suffix}\n> ${comment.lineText}\n${comment.body}`;
  });
  return `Code review comments:\n\n${blocks.join("\n\n")}\n`;
}

/**
 * round-14 Fix 3: canonicalizes a gutter click's raw `(side, lineNumber)` before it becomes a
 * comment's stored anchor. A context line exists on both sides of a diff — split layout's gutter
 * reports a context row's click as `side: "old"` (the deletions column it happens to render in),
 * which would otherwise store an old-side anchor for a line that is not actually a deletion:
 * `formatReviewCommentsText` labels every old-side comment "(removed line)" regardless, wrongly
 * marking a still-present line as removed, and the old-side line number can drift from the
 * current file's own numbering whenever an earlier hunk changed the line count — pointing the
 * agent at the wrong coordinate entirely. The new-side coordinate is the one that matches the file
 * the agent will actually open when it looks at the comment, so a context-line click is
 * canonicalized to its new-side `(side, lineNumber)` before anything is stored; a genuine
 * deletion (no new-side counterpart) and an already-new-side click both pass through unchanged,
 * reserving "(removed line)" for real deletions only.
 *
 * Walks the patch with the same hunk-header/marker parsing `extractDiffLines` uses (rather than
 * calling it and trying to reverse-engineer which "old" record was context vs. deletion from its
 * side/lineNumber/text shape alone, which doesn't retain that distinction) and stops as soon as it
 * reaches the requested old-side line.
 */
export function canonicalizeContextAnchor(
  patch: string,
  side: ReviewCommentSide,
  lineNumber: number,
): { side: ReviewCommentSide; lineNumber: number } {
  if (side !== "old") return { side, lineNumber };

  let oldLine = 0;
  let newLine = 0;
  let inHunk = false;
  for (const raw of patch.split("\n")) {
    const hunkMatch = HUNK_HEADER.exec(raw);
    if (hunkMatch) {
      oldLine = Number(hunkMatch[1]);
      newLine = Number(hunkMatch[2]);
      inHunk = true;
      continue;
    }
    if (!inHunk) continue; // still inside the "diff --git"/"index"/"---"/"+++" preamble
    if (raw.startsWith("\\")) continue; // "\ No newline at end of file"
    const marker = raw[0];
    if (marker === " ") {
      if (oldLine === lineNumber) return { side: "new", lineNumber: newLine };
      oldLine += 1;
      newLine += 1;
    } else if (marker === "-") {
      if (oldLine === lineNumber) return { side, lineNumber }; // a real deletion — no new-side counterpart
      oldLine += 1;
    } else if (marker === "+") {
      newLine += 1;
    }
  }
  return { side, lineNumber }; // requested line never found on the old side — pass through unchanged
}

/** Maps this bridge's `"old"`/`"new"` vocabulary onto `@pierre/diffs`' `AnnotationSide`
 *  (`"deletions"`/`"additions"`) at the one boundary that needs it — `diffView.ts`'s annotation
 *  and gutter-click wiring. Typed as plain string literals here rather than importing
 *  `@pierre/diffs`' type name, so this pure logic module has no dependency on the rendering
 *  library. */
export function toAnnotationSide(side: ReviewCommentSide): "deletions" | "additions" {
  return side === "old" ? "deletions" : "additions";
}

export function fromAnnotationSide(side: "deletions" | "additions"): ReviewCommentSide {
  return side === "deletions" ? "old" : "new";
}
