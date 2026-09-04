import { describe, expect, it, vi } from "vitest";
import { DiffFileEntry } from "../src/bridge/types";
import { FileListCallbacks, renderFileList, updateFileListRow } from "../src/app/fileList";

function makeCallbacks(): FileListCallbacks {
  return { onSelect: vi.fn() };
}

function makeFile(overrides: Partial<DiffFileEntry> = {}): DiffFileEntry {
  return {
    path: "src/main.ts",
    status: "modified",
    isBinary: false,
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

  it("does not invent a +0/-0 stat before a streamed patch arrives", () => {
    const container = document.createElement("div");
    const file = makeFile({ patch: undefined });

    renderFileList(container, [file], undefined, makeCallbacks());

    expect(container.querySelector('[data-path="src/main.ts"] .st')).toBeNull();
  });
});

describe("fileList — renderFileList (existing behavior)", () => {
  it("updates one streamed row in place without rebuilding a large manifest tree", () => {
    const container = document.createElement("div");
    const files = Array.from({ length: 500 }, (_, index) => makeFile({ path: `src/File${index}.ts`, patchState: "queued" }));
    renderFileList(container, files, "src/File250.ts", makeCallbacks());
    const unchanged = container.querySelector<HTMLElement>('[data-path="src/File499.ts"]')!;
    const target = container.querySelector<HTMLElement>('[data-path="src/File250.ts"]')!;

    expect(updateFileListRow(container, makeFile({ path: "src/File250.ts", patchState: "ready", patch: "@@ -1 +1 @@\n-old\n+new" }))).toBe("updated");

    expect(container.querySelector('[data-path="src/File499.ts"]')).toBe(unchanged);
    expect(container.querySelector('[data-path="src/File250.ts"]')).toBe(target);
    expect(target.querySelector(".transfer")).toBeNull();
    expect(statText(container, "src/File250.ts")).toEqual({ additions: "+1", deletions: " -1" });
  });

  it("uses the manifest row index instead of scanning sidebar rows for each patch", () => {
    const container = document.createElement("div");
    const files = Array.from({ length: 500 }, (_, index) => makeFile({ path: `src/File${index}.ts`, patchState: "queued" }));
    renderFileList(container, files, undefined, makeCallbacks());
    const queryAll = vi.spyOn(container, "querySelectorAll").mockImplementation(() => {
      throw new Error("streamed row update scanned the sidebar");
    });

    expect(updateFileListRow(container, makeFile({ path: "src/File250.ts", patchState: "streaming" }))).toBe("updated");

    queryAll.mockRestore();
  });

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

  it("omits the stat span for binary files", () => {
    const container = document.createElement("div");
    const files = [makeFile({ path: "bin.png", isBinary: true })];

    renderFileList(container, files, undefined, makeCallbacks());

    for (const row of container.querySelectorAll(".row")) {
      expect(row.querySelector(".st")).toBeNull();
    }
  });

  it("shows a submodule badge instead of the stat span for a gitlink entry", () => {
    const container = document.createElement("div");
    const files = [
      makeFile({
        path: "sbc_hal",
        patch: undefined,
        submodule: { oldCommit: "a".repeat(40), newCommit: "b".repeat(40), dirty: true, unmerged: false },
      }),
    ];

    renderFileList(container, files, undefined, makeCallbacks());

    const row = container.querySelector(`.row[data-path="sbc_hal"]`)!;
    expect(row.querySelector(".submodule-badge")?.textContent).toBe("submodule");
    expect(row.querySelector(".st")).toBeNull();
    expect(row.querySelector(".transfer")).toBeNull();
  });

  it("badges a gitlink row from the manifest flag alone, before its pointer metadata arrives", () => {
    const container = document.createElement("div");
    const files = [makeFile({ path: "sbc_hal", patch: undefined, patchState: "queued", isSubmodule: true })];

    renderFileList(container, files, undefined, makeCallbacks());

    const row = container.querySelector(`.row[data-path="sbc_hal"]`)!;
    expect(row.querySelector(".submodule-badge")?.textContent).toBe("submodule");
    expect(row.querySelector(".transfer")).toBeNull();
    expect(row.querySelector(".st")).toBeNull();
  });

  it("keeps exactly one badge on a submodule row across patch-state updates", () => {
    const container = document.createElement("div");
    renderFileList(
      container,
      [makeFile({ path: "sbc_hal", patch: undefined, patchState: "queued", isSubmodule: true })],
      undefined,
      makeCallbacks(),
    );

    expect(updateFileListRow(container, makeFile({ path: "sbc_hal", patch: undefined, patchState: "streaming", isSubmodule: true }))).toBe("updated");
    expect(
      updateFileListRow(
        container,
        makeFile({
          path: "sbc_hal",
          patch: undefined,
          patchState: "ready",
          isSubmodule: true,
          submodule: { oldCommit: "a".repeat(40), newCommit: "b".repeat(40), dirty: true, unmerged: false },
        }),
      ),
    ).toBe("updated");

    const row = container.querySelector(`.row[data-path="sbc_hal"]`)!;
    expect(row.querySelectorAll(".submodule-badge")).toHaveLength(1);
    expect(row.querySelector(".fn")?.textContent).toBe("sbc_hal");
  });

  it("keeps data-path and the row identifier on a submodule row", () => {
    const container = document.createElement("div");
    const files = [makeFile({ path: "sbc_hal", patch: undefined, submodule: { dirty: false, unmerged: false } })];

    renderFileList(container, files, undefined, makeCallbacks());

    const row = container.querySelector<HTMLElement>(`.row[data-path="sbc_hal"]`)!;
    expect(row.id).toBe(`code-pane-change-${encodeURIComponent("sbc_hal")}`);
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

  it("does not materialize descendants for a persisted collapsed directory until it is expanded", () => {
    const container = document.createElement("div");
    const callbacks = makeCallbacks();
    callbacks.onExpandedPathsChange = vi.fn();
    const files = Array.from({ length: 1_000 }, (_, index) => makeFile({ path: `src/File${index}.ts` }));

    renderFileList(container, files, undefined, callbacks, []);

    const dirrow = container.querySelector(".dirrow") as HTMLElement;
    expect(dirrow.getAttribute("aria-expanded")).toBe("false");
    expect(container.querySelectorAll(".row")).toHaveLength(0);

    dirrow.click();

    expect(dirrow.getAttribute("aria-expanded")).toBe("true");
    expect(container.querySelectorAll(".row")).toHaveLength(files.length);
    expect(callbacks.onExpandedPathsChange).toHaveBeenCalledWith(["src"]);
  });

  it("reveals a selected file's ancestor while leaving unrelated persisted-collapsed directories lazy", () => {
    const container = document.createElement("div");
    const files = [makeFile({ path: "macos/Foo.swift" }), makeFile({ path: "ios/Bar.swift" })];

    renderFileList(container, files, "macos/Foo.swift", makeCallbacks(), []);

    const dirrows = [...container.querySelectorAll(".dirrow")] as HTMLElement[];
    const macosRow = dirrows.find((row) => row.querySelector(".dirlabel")?.textContent === "macos")!;
    const iosRow = dirrows.find((row) => row.querySelector(".dirlabel")?.textContent === "ios")!;
    expect(macosRow.getAttribute("aria-expanded")).toBe("true");
    expect(container.querySelector('.row[data-path="macos/Foo.swift"]')?.className).toContain(" on");
    expect(iosRow.getAttribute("aria-expanded")).toBe("false");
    expect(container.querySelector('.row[data-path="ios/Bar.swift"]')).toBeNull();
  });

  it("updates a hidden manifest row without replacing the tree, then materializes its final state", () => {
    const container = document.createElement("div");
    const files = [makeFile({ path: "src/hidden.ts", patchState: "queued" })];
    renderFileList(container, files, undefined, makeCallbacks(), []);
    const group = container.querySelector(".dir-group");
    const dirrow = container.querySelector(".dirrow") as HTMLElement;

    expect(updateFileListRow(container, makeFile({
      path: "src/hidden.ts",
      patchState: "ready",
      patch: "@@ -1 +1 @@\n-old\n+new",
    }))).toBe("hidden");
    expect(container.querySelector(".dir-group")).toBe(group);
    expect(container.querySelectorAll(".row")).toHaveLength(0);

    dirrow.click();

    expect(container.querySelector(".dir-group")).toBe(group);
    expect(statText(container, "src/hidden.ts")).toEqual({ additions: "+1", deletions: " -1" });
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
