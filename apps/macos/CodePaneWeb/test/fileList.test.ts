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
 *  observable surface for `countChanges`, which is not itself exported. Looked up by `data-path`
 *  (the row's full path) rather than the `.fn` span's text, since a nested file's `.fn` shows only
 *  its basename (see fileTree.ts's `buildFileTree`). */
function statText(container: HTMLElement, path: string): { additions: string; deletions: string } {
  const row = container.querySelector(`.row[data-path="${path}"]`);
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

describe("fileList — directory tree (docs mockup 'G — Tree with compacted chains')", () => {
  it("renders a compacted directory chain as one dirrow, and its files by basename only", () => {
    const container = document.createElement("div");
    const files = [
      makeFile({ path: "apps/ios/Sources/ViewerResync.swift" }),
      makeFile({ path: "apps/ios/Sources/MobileRootView.swift" }),
    ];

    renderFileList(container, files, undefined, makeCallbacks());

    const dirrows = [...container.querySelectorAll(".dirrow")];
    expect(dirrows).toHaveLength(1); // apps -> ios -> Sources each have one child, so all three compact into one row
    expect(dirrows[0]!.querySelector(".dirlabel")?.textContent).toBe("apps/ios/Sources");

    const fnTexts = [...container.querySelectorAll(".row .fn")].map((el) => el.textContent);
    expect(fnTexts).toEqual(["ViewerResync.swift", "MobileRootView.swift"]);
  });

  it("keeps a directory with a single file as its own row (no compaction into a file)", () => {
    const container = document.createElement("div");
    renderFileList(container, [makeFile({ path: "src/main.ts" })], undefined, makeCallbacks());

    expect(container.querySelector(".dirrow .dirlabel")?.textContent).toBe("src");
    expect(container.querySelector(".row .fn")?.textContent).toBe("main.ts");
  });

  it("sets data-path and a title tooltip to the full path on a nested file row, even though its visible text is the basename", () => {
    const container = document.createElement("div");
    renderFileList(container, [makeFile({ path: "apps/macos/Foo.swift" })], undefined, makeCallbacks());

    const row = container.querySelector(".row")!;
    expect(row.getAttribute("data-path")).toBe("apps/macos/Foo.swift");
    expect(row.querySelector(".fn")?.getAttribute("title")).toBe("apps/macos/Foo.swift");
  });

  it("clicking a nested file row still invokes onSelect with its full path (click-to-open-diff behavior)", () => {
    const container = document.createElement("div");
    const callbacks = makeCallbacks();
    renderFileList(container, [makeFile({ path: "apps/macos/Foo.swift" })], undefined, callbacks);

    (container.querySelector(".row") as HTMLElement).click();

    expect(callbacks.onSelect).toHaveBeenCalledWith("apps/macos/Foo.swift");
  });

  it("collapses and re-expands a directory's rows on clicking its dirrow, flipping the disclosure triangle", () => {
    const container = document.createElement("div");
    renderFileList(container, [makeFile({ path: "apps/macos/Foo.swift" })], undefined, makeCallbacks());

    const dirrow = container.querySelector(".dirrow") as HTMLElement;
    const dirChildren = container.querySelector(".dir-children") as HTMLElement;
    expect(dirrow.querySelector(".tri")?.textContent).toBe("▾"); // default expanded
    expect(dirChildren.style.display).not.toBe("none");

    dirrow.click();
    expect(dirrow.querySelector(".tri")?.textContent).toBe("▸");
    expect(dirChildren.style.display).toBe("none");
    expect(dirrow.getAttribute("aria-expanded")).toBe("false");

    dirrow.click();
    expect(dirrow.querySelector(".tri")?.textContent).toBe("▾");
    expect(dirChildren.style.display).not.toBe("none");
    expect(dirrow.getAttribute("aria-expanded")).toBe("true");
  });

  it("exposes rows as focusable buttons and toggles a directory from the keyboard", () => {
    const container = document.createElement("div");
    renderFileList(container, [makeFile({ path: "apps/macos/Foo.swift" })], undefined, makeCallbacks());

    const dirrow = container.querySelector(".dirrow") as HTMLElement;
    const dirChildren = container.querySelector(".dir-children") as HTMLElement;
    expect(dirrow.getAttribute("role")).toBe("button");
    expect(dirrow.tabIndex).toBe(0);

    dirrow.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
    expect(dirChildren.style.display).toBe("none");
    expect(dirrow.getAttribute("aria-expanded")).toBe("false");

    dirrow.dispatchEvent(new KeyboardEvent("keydown", { key: " ", bubbles: true, cancelable: true }));
    expect(dirChildren.style.display).not.toBe("none");
    expect(dirrow.getAttribute("aria-expanded")).toBe("true");

    // A non-activation key must not toggle.
    dirrow.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true, cancelable: true }));
    expect(dirrow.getAttribute("aria-expanded")).toBe("true");

    // A held key's auto-repeated keydowns must not oscillate the disclosure.
    dirrow.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", repeat: true, bubbles: true, cancelable: true }));
    expect(dirrow.getAttribute("aria-expanded")).toBe("true");
  });

  it("selects a file row with Enter from the keyboard", () => {
    const container = document.createElement("div");
    const callbacks = makeCallbacks();
    renderFileList(container, [makeFile({ path: "apps/macos/Foo.swift" })], undefined, callbacks);

    const row = container.querySelector('.row[data-path="apps/macos/Foo.swift"]') as HTMLElement;
    expect(row.getAttribute("role")).toBe("button");
    expect(row.tabIndex).toBe(0);

    row.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
    expect(callbacks.onSelect).toHaveBeenCalledWith("apps/macos/Foo.swift");
  });

  it("renders root-level files directly with no wrapping directory row, alongside a nested directory's files", () => {
    const container = document.createElement("div");
    const files = [makeFile({ path: "README.md" }), makeFile({ path: "apps/macos/Foo.swift" })];

    renderFileList(container, files, undefined, makeCallbacks());

    expect(container.querySelectorAll(".dirrow")).toHaveLength(1);
    const fnTexts = [...container.querySelectorAll(".row .fn")].map((el) => el.textContent);
    expect(fnTexts).toEqual(["README.md", "Foo.swift"]);
  });
});
