import { describe, expect, it } from "vitest";
import { DiffFileEntry, SpacesReviewComment } from "../src/bridge/types";
import {
  AnchoredComment,
  anchoredLineNumber,
  canonicalizeContextAnchor,
  extractDiffLines,
  formatReviewCommentsText,
  fromAnnotationSide,
  reanchorComments,
  selectDefaultAgentId,
  toAnnotationSide,
} from "../src/app/reviewComments";

/** Wraps a raw comment as an `AnchoredComment` with no position shift — the common case for tests
 *  below that only care about the formatter/tray-label logic, not re-anchoring itself (that's
 *  `reanchorComments`'s own describe block above). */
function anchoredAt(comment: SpacesReviewComment, lineNumber: number): AnchoredComment {
  return { comment, position: { lineNumber, outdated: false } };
}

const PATCH = `diff --git a/src/foo.ts b/src/foo.ts
index 1111111..2222222 100644
--- a/src/foo.ts
+++ b/src/foo.ts
@@ -10,5 +10,6 @@ function compute() {
 const a = 1;
-const b = oldHelper();
+const b = newHelper();
+const c = 3;
 const d = 4;
 return a + b;
`;

function file(overrides: Partial<DiffFileEntry> = {}): DiffFileEntry {
  return { path: "src/foo.ts", status: "modified", patch: PATCH, isBinary: false, truncated: false, ...overrides };
}

// The default lineNumber (12) deliberately does not match PATCH's actual line for lineText (which
// is really at new-side line 11) — most tests below want a "the line moved" fixture out of the
// box; the exact-match test constructs its own comment with the correct lineNumber instead.
function comment(overrides: Partial<SpacesReviewComment> = {}): SpacesReviewComment {
  return {
    id: "c1",
    filePath: "src/foo.ts",
    side: "new",
    lineNumber: 12,
    lineText: "const b = newHelper();",
    body: "Why rename this?",
    createdAt: "2026-08-20T00:00:00.000Z",
    revision: 0,
    ...overrides,
  };
}

describe("extractDiffLines", () => {
  it("records both sides of a context line and only the relevant side for +/- lines", () => {
    const lines = extractDiffLines(PATCH);
    expect(lines).toContainEqual({ side: "old", lineNumber: 10, text: "const a = 1;" });
    expect(lines).toContainEqual({ side: "new", lineNumber: 10, text: "const a = 1;" });
    expect(lines).toContainEqual({ side: "old", lineNumber: 11, text: "const b = oldHelper();" });
    expect(lines).toContainEqual({ side: "new", lineNumber: 11, text: "const b = newHelper();" });
    expect(lines).toContainEqual({ side: "new", lineNumber: 12, text: "const c = 3;" });
    // The deleted line's old-side successor keeps the old-side numbering, unaffected by the
    // insertion on the new side.
    expect(lines).toContainEqual({ side: "old", lineNumber: 12, text: "const d = 4;" });
  });

  it("returns nothing for a patch with no hunks", () => {
    expect(extractDiffLines("")).toEqual([]);
  });
});

describe("reanchorComments", () => {
  it("keeps an exact match (same file/side/lineNumber/text) in place", () => {
    // "const b = newHelper();" sits at new-side line 11 in PATCH (see extractDiffLines's own
    // assertions above) — an exact (lineNumber, text) match, unlike the default `comment()`
    // fixture used elsewhere in this file, which deliberately points at the wrong line number to
    // exercise the nearest-match search instead.
    const exact = comment({ lineNumber: 11 });
    const [anchored] = reanchorComments([exact], [file()]);
    expect(anchored!.position).toEqual({ lineNumber: 11, outdated: false });
  });

  it("floats to the nearest same-side line whose text still matches, when the line number shifted", () => {
    const shifted = comment({ lineNumber: 99 }); // wrong line number, but lineText still matches line 11
    const [anchored] = reanchorComments([shifted], [file()]);
    expect(anchored!.position).toEqual({ lineNumber: 11, outdated: false });
  });

  it("marks a comment outdated (file-level pin) when its line text no longer appears on its side", () => {
    const gone = comment({ lineText: "this text was never in the diff" });
    const [anchored] = reanchorComments([gone], [file()]);
    expect(anchored!.position).toEqual({ lineNumber: 0, outdated: true });
  });

  it("has no position at all when the comment's file is no longer in the diff", () => {
    const [anchored] = reanchorComments([comment({ filePath: "src/gone.ts" })], [file()]);
    expect(anchored!.position).toBeUndefined();
  });

  it("breaks a distance tie toward the smaller line number", () => {
    // New-side lines: 1 "other", 2 "dup", 3 "other2", 4 "dup" — two lines with text "dup"
    // equidistant (1 line away) from a comment originally anchored to line 3 ("other2", no
    // longer a match), so the tie-break rule alone decides between them.
    const duplicatePatch = `diff --git a/src/dup.ts b/src/dup.ts
index 1111111..2222222 100644
--- a/src/dup.ts
+++ b/src/dup.ts
@@ -1,1 +1,4 @@
+other
+dup
+other2
+dup
`;
    const dupFile = file({ path: "src/dup.ts", patch: duplicatePatch });
    const dupComment = comment({ filePath: "src/dup.ts", lineNumber: 3, lineText: "dup" });
    const [anchored] = reanchorComments([dupComment], [dupFile]);
    expect(anchored!.position!.lineNumber).toBe(2);
  });
});

describe("selectDefaultAgentId", () => {
  it("auto-selects the only running agent when there is exactly one", () => {
    expect(selectDefaultAgentId([{ id: "a1", label: "L1", sessionId: "s1" }], undefined)).toBe("a1");
  });

  it("selects nothing when zero agents run", () => {
    expect(selectDefaultAgentId([], undefined)).toBeUndefined();
  });

  it("selects nothing when more than one agent runs and none was previously picked", () => {
    const agents = [
      { id: "a1", label: "L1", sessionId: "s1" },
      { id: "a2", label: "L2", sessionId: "s2" },
    ];
    expect(selectDefaultAgentId(agents, undefined)).toBeUndefined();
  });

  it("keeps a manually picked agent selected as long as it is still present", () => {
    const agents = [
      { id: "a1", label: "L1", sessionId: "s1" },
      { id: "a2", label: "L2", sessionId: "s2" },
    ];
    expect(selectDefaultAgentId(agents, "a2")).toBe("a2");
  });

  it("re-runs the auto-default rule when the previously selected agent disappears", () => {
    // Only one agent remains after the previously selected one exited: falls back to auto-select.
    expect(selectDefaultAgentId([{ id: "a1", label: "L1", sessionId: "s1" }], "a2")).toBe("a1");
  });
});

describe("anchoredLineNumber", () => {
  it("uses the re-anchored position's line number when the anchor moved", () => {
    const moved = comment({ lineNumber: 12 });
    expect(anchoredLineNumber(anchoredAt(moved, 11))).toBe(11);
  });

  it("falls back to the comment's original lineNumber when the position is outdated", () => {
    const c = comment({ lineNumber: 12 });
    expect(anchoredLineNumber({ comment: c, position: { lineNumber: 0, outdated: true } })).toBe(12);
  });

  it("falls back to the comment's original lineNumber when there is no position at all", () => {
    const c = comment({ lineNumber: 12 });
    expect(anchoredLineNumber({ comment: c, position: undefined })).toBe(12);
  });
});

describe("formatReviewCommentsText", () => {
  it("formats a single addition-side comment", () => {
    const text = formatReviewCommentsText([anchoredAt(comment(), 12)]);
    expect(text).toBe(
      "Code review comments:\n\nsrc/foo.ts:12\n> const b = newHelper();\nWhy rename this?\n",
    );
  });

  it("suffixes a removed-line (old-side) comment", () => {
    const removed = comment({ side: "old", lineNumber: 11, lineText: "const b = oldHelper();", body: "Keep this?" });
    const text = formatReviewCommentsText([anchoredAt(removed, 11)]);
    expect(text).toBe(
      "Code review comments:\n\nsrc/foo.ts:11 (removed line)\n> const b = oldHelper();\nKeep this?\n",
    );
  });

  it("joins multiple comments with a blank line between blocks", () => {
    const c1 = comment({ id: "c1", lineNumber: 12, body: "First." });
    const c2 = comment({ id: "c2", filePath: "src/bar.ts", side: "old", lineNumber: 7, lineText: "oldHelper()", body: "Second." });
    const text = formatReviewCommentsText([anchoredAt(c1, 12), anchoredAt(c2, 7)]);
    expect(text).toBe(
      "Code review comments:\n\n" +
        "src/foo.ts:12\n> const b = newHelper();\nFirst.\n\n" +
        "src/bar.ts:7 (removed line)\n> oldHelper()\nSecond.\n",
    );
  });

  it("emits the re-anchored line number, not the comment's original one, when the anchor moved", () => {
    // comment()'s default lineNumber (12) does not match where "const b = newHelper();" actually
    // sits (new-side line 11) — a moved-anchor fixture, matching this file's `comment()` doc
    // comment on why the default is deliberately wrong.
    const moved = comment(); // lineNumber: 12, but the true anchor (via reanchorComments) is 11
    const [anchored] = reanchorComments([moved], [file()]);
    const text = formatReviewCommentsText([anchored!]);
    expect(text).toContain("src/foo.ts:11\n");
    expect(text).not.toContain("src/foo.ts:12\n");
  });

  it("emits the original lineNumber when the position is outdated", () => {
    const gone = comment({ lineNumber: 12, lineText: "this text was never in the diff" });
    const [anchored] = reanchorComments([gone], [file()]);
    expect(anchored!.position).toEqual({ lineNumber: 0, outdated: true });
    const text = formatReviewCommentsText([anchored!]);
    expect(text).toContain("src/foo.ts:12\n");
  });
});

describe("canonicalizeContextAnchor (round-14 Fix 3)", () => {
  // Two hunks: the first hunk inserts a line (net +1), so the second hunk's old-side line numbers
  // already trail its new-side numbers before any content inside it is even considered — exactly
  // the "earlier hunk changed the line count" fixture this helper needs to canonicalize correctly.
  const MULTI_HUNK_PATCH = `diff --git a/src/multi.ts b/src/multi.ts
index 1111111..2222222 100644
--- a/src/multi.ts
+++ b/src/multi.ts
@@ -1,2 +1,3 @@
 context1
+added1
 context2
@@ -10,3 +11,3 @@
 context3
-deletedLine
 context4
`;

  it("canonicalizes a context line's old-side click to its new-side (side, lineNumber)", () => {
    // "context3" sits at old-side line 10 but new-side line 11 (see the fixture's doc comment).
    expect(canonicalizeContextAnchor(MULTI_HUNK_PATCH, "old", 10)).toEqual({ side: "new", lineNumber: 11 });
  });

  it("leaves a real deletion clicked on the old side unchanged", () => {
    // "deletedLine" (old-side line 11) has no new-side counterpart — a genuine removal.
    expect(canonicalizeContextAnchor(MULTI_HUNK_PATCH, "old", 11)).toEqual({ side: "old", lineNumber: 11 });
  });

  it("leaves a click already on the new side unchanged", () => {
    expect(canonicalizeContextAnchor(MULTI_HUNK_PATCH, "new", 11)).toEqual({ side: "new", lineNumber: 11 });
  });

  it("never labels a canonicalized context-line comment as a removed line", () => {
    const canonical = canonicalizeContextAnchor(MULTI_HUNK_PATCH, "old", 10);
    const c = comment({
      filePath: "src/multi.ts",
      side: canonical.side,
      lineNumber: canonical.lineNumber,
      lineText: "context3",
      body: "Still true after the refactor?",
    });
    const text = formatReviewCommentsText([anchoredAt(c, canonical.lineNumber)]);
    expect(text).toContain("src/multi.ts:11\n");
    expect(text).not.toContain("(removed line)");
  });
});

describe("toAnnotationSide / fromAnnotationSide", () => {
  it("round-trips both sides", () => {
    expect(toAnnotationSide("old")).toBe("deletions");
    expect(toAnnotationSide("new")).toBe("additions");
    expect(fromAnnotationSide("deletions")).toBe("old");
    expect(fromAnnotationSide("additions")).toBe("new");
  });
});
