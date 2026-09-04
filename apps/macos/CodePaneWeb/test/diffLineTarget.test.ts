import { describe, expect, it } from "vitest";
import { editorLineForDiffLine, resolveDiffLineTarget } from "../src/app/diffLineTarget";

function stampedRow(path: string, side: "old" | "new", line: number): HTMLElement {
  const row = document.createElement("div");
  row.dataset.diffPath = path;
  row.dataset.diffSide = side;
  row.dataset.line = String(line);
  return row;
}

describe("resolveDiffLineTarget", () => {
  it("reads the stamps off the nearest stamped element in the composed path", () => {
    const row = stampedRow("src/a.ts", "new", 12);
    const tokenSpan = document.createElement("span");
    row.appendChild(tokenSpan);

    expect(resolveDiffLineTarget([tokenSpan, row, document.body])).toEqual({
      path: "src/a.ts",
      side: "new",
      line: 12,
    });
  });

  it("returns undefined when no element in the composed path is stamped", () => {
    const plain = document.createElement("div");
    plain.appendChild(document.createElement("span"));

    expect(resolveDiffLineTarget([document.createElement("span"), plain, document.body, document])).toBeUndefined();
  });
});

describe("editorLineForDiffLine", () => {
  it("maps a new-side addition to its own line number", () => {
    const patch = ["@@ -1,2 +1,3 @@", " line1", "+added", " line2", " line3"].join("\n");
    expect(editorLineForDiffLine(patch, "new", 2)).toBe(2);
  });

  it("maps a new-side context line to its own line number", () => {
    const patch = ["@@ -1,2 +1,3 @@", " line1", "+added", " line2", " line3"].join("\n");
    expect(editorLineForDiffLine(patch, "new", 4)).toBe(4);
  });

  it("maps a split-layout old-side context line to its own new-side line number", () => {
    // old line2 sits at new line3 once the leading addition has shifted everything below it down.
    const patch = ["@@ -1,4 +1,5 @@", " line1", "+added", " line2", " line3", " line4"].join("\n");
    expect(editorLineForDiffLine(patch, "old", 2)).toBe(3);
  });

  it("maps a deletion mid-hunk to the kept line right after the deleted run", () => {
    const patch = ["@@ -1,4 +1,3 @@", " line1", "-line2", " line3", " line4"].join("\n");
    expect(editorLineForDiffLine(patch, "old", 2)).toBe(2); // line3, shifted up by the deletion
  });

  it("maps a deletion run that ends a hunk to the line the file continues with when a later hunk follows", () => {
    // Hunk1's deletion run reaches the end of hunk1's own lines, but a later hunk proves the file
    // goes on, so the nearest kept line after the deletion is new line 2 (old line 4), not line 1.
    const patch = [
      "@@ -1,3 +1,1 @@",
      " line1",
      "-line2",
      "-line3",
      "@@ -10,2 +8,2 @@",
      " line10",
      " line11",
    ].join("\n");
    expect(editorLineForDiffLine(patch, "old", 2)).toBe(2);
  });

  it("maps a zero-context deletion to the line after it, using git's line-before start", () => {
    // With `diff.context=0` a pure deletion hunk names the line before the deletion as its
    // new-side start: `+1,0` here means lines were removed after new line 1, so the file's next
    // line is 2, whether or not a later hunk follows (the editor clamps if the file ends there).
    const withLaterHunk = ["@@ -2,2 +1,0 @@", "-line2", "-line3", "@@ -6,1 +4,0 @@", "-line6"].join("\n");
    expect(editorLineForDiffLine(withLaterHunk, "old", 2)).toBe(2);
    expect(editorLineForDiffLine(withLaterHunk, "old", 6)).toBe(5);
    const alone = ["@@ -2,2 +1,0 @@", "-line2", "-line3"].join("\n");
    expect(editorLineForDiffLine(alone, "old", 3)).toBe(2);
  });

  it("maps a deletion run reaching the true end of the file to the file's last kept line", () => {
    const patch = ["@@ -3,3 +3,1 @@", " line3", "-line4", "-line5"].join("\n");
    expect(editorLineForDiffLine(patch, "old", 4)).toBe(3); // line3, the file's last remaining line
  });

  it("maps a deletion in a file emptied by the change to line 1", () => {
    const patch = ["@@ -1,2 +0,0 @@", "-line1", "-line2"].join("\n");
    expect(editorLineForDiffLine(patch, "old", 2)).toBe(1);
  });

  it("looks past a no-newline marker between the deleted run and the line that replaces it", () => {
    // Replacing the unterminated last line of a two-line file: the marker between `-` and `+`
    // carries no line, so the removed line still maps to its replacement, line 2.
    const patch = [
      "@@ -1,2 +1,2 @@",
      " line1",
      "-line2",
      "\\ No newline at end of file",
      "+line2b",
      "\\ No newline at end of file",
    ].join("\n");
    expect(editorLineForDiffLine(patch, "old", 2)).toBe(2);
  });

  it("resolves each hunk's old-side line against that hunk's own offsets", () => {
    const patch = [
      "@@ -1,2 +1,3 @@",
      " line1",
      "+added",
      " line2",
      "@@ -10,3 +11,2 @@",
      " line10",
      "-line11",
      " line12",
    ].join("\n");
    expect(editorLineForDiffLine(patch, "old", 11)).toBe(12); // line12, in hunk2's own numbering
  });
});
