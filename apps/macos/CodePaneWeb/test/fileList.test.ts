import { describe, expect, it, vi } from "vitest";
import { DiffFileEntry } from "../src/bridge/types";
import { FileListCallbacks, renderFileList } from "../src/app/fileList";

function makeCallbacks(): FileListCallbacks {
  return { onSelect: vi.fn() };
}

function makeFile(overrides: Partial<DiffFileEntry> = {}): DiffFileEntry {
  return {
    path: "src/main.ts",
    status: "modified",
    isBinary: false,
    truncated: false,
    ...overrides,
  };
}

/** Reads a rendered row's `+N`/`-N` stat text (see `renderFileList`'s `.p`/`.m` spans) — the only
 *  observable surface for `countChanges`, which is not itself exported. */
function statText(container: HTMLElement, path: string): { additions: string; deletions: string } {
  const row = [...container.querySelectorAll(".row")].find((el) => el.querySelector(".fn")?.textContent === path);
  if (!row) throw new Error(`no row for ${path}`);
  const p = row.querySelector(".p");
  const m = row.querySelector(".m");
  if (!p || !m) throw new Error(`row for ${path} has no stat spans`);
  return { additions: p.textContent ?? "", deletions: m.textContent ?? "" };
}

describe("fileList — countChanges (round-1 Fix 2)", () => {
  it("counts hunk lines whose content itself starts with ++ or -- once inside a hunk", () => {
    const container = document.createElement("div");
    const patch = [
      "--- a/src/main.ts",
      "+++ b/src/main.ts",
      "@@ -1,2 +1,2 @@",
      " context line",
      "+++x",
      "---y",
    ].join("\n");
    const file = makeFile({ patch });

    renderFileList(container, [file], undefined, makeCallbacks());

    // `++x`/`--y` are real hunk content: their patch-line representation is `+++x`/`---y` (a leading
    // +/- marker plus content that itself starts with `+`/`-`). Both must be counted, not skipped as
    // if they were `+++`/`---` file-header preamble.
    expect(statText(container, "src/main.ts")).toEqual({ additions: "+1", deletions: " -1" });
  });

  it("does not count the +++ b/... / --- a/... file-header preamble lines before the first hunk", () => {
    const container = document.createElement("div");
    const patch = [
      "--- a/src/main.ts",
      "+++ b/src/main.ts",
      "@@ -1,1 +1,2 @@",
      " context line",
      "+added line",
    ].join("\n");
    const file = makeFile({ patch });

    renderFileList(container, [file], undefined, makeCallbacks());

    expect(statText(container, "src/main.ts")).toEqual({ additions: "+1", deletions: " -0" });
  });

  it("reports no changes for a file with no patch", () => {
    const container = document.createElement("div");
    const file = makeFile({ patch: undefined });

    renderFileList(container, [file], undefined, makeCallbacks());

    expect(statText(container, "src/main.ts")).toEqual({ additions: "+0", deletions: " -0" });
  });
});

describe("fileList — renderFileList (existing behavior)", () => {
  it("renders an empty-state row when there are no files", () => {
    const container = document.createElement("div");

    renderFileList(container, [], undefined, makeCallbacks());

    expect(container.querySelector(".empty")?.textContent).toBe("No changes");
  });

  it("marks the selected row and invokes onSelect with the clicked file's path", () => {
    const container = document.createElement("div");
    const callbacks = makeCallbacks();
    const files = [makeFile({ path: "a.ts" }), makeFile({ path: "b.ts" })];

    renderFileList(container, files, "b.ts", callbacks);

    const rows = [...container.querySelectorAll(".row")];
    expect(rows[0]!.className).not.toContain(" on");
    expect(rows[1]!.className).toContain(" on");

    (rows[0] as HTMLElement).click();
    expect(callbacks.onSelect).toHaveBeenCalledWith("a.ts");
  });

  it("omits the stat span for binary and truncated files", () => {
    const container = document.createElement("div");
    const files = [makeFile({ path: "bin.png", isBinary: true }), makeFile({ path: "big.log", truncated: true })];

    renderFileList(container, files, undefined, makeCallbacks());

    for (const row of container.querySelectorAll(".row")) {
      expect(row.querySelector(".st")).toBeNull();
    }
  });
});
