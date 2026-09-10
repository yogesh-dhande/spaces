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

/** The nested-submodule shape the daemon sends: a pointer entry, then every entry nested under it
 *  (a nested submodule's own pointer included), in that order. */
function nestedSubmoduleFiles(): DiffFileEntry[] {
  return [
    makeFile({
      path: "sbc_hal",
      patch: undefined,
      isSubmodule: true,
      submodule: { oldCommit: "a".repeat(40), newCommit: "b".repeat(40), dirty: true, unmerged: false, checkedOut: true },
    }),
    makeFile({
      path: "sbc_hal/.bumpversion.cfg",
      submodulePath: "sbc_hal",
      patch: ["@@ -1,2 +1,2 @@", "-current_version = 1.4.2", "+current_version = 1.4.3"].join("\n"),
    }),
  ];
}

describe("fileList: submodule pointer rows (PR D, nested submodules)", () => {
  it("renders the pointer as a directory row chipped 'submodule' before its metadata arrives, and its commit after", () => {
    const container = document.createElement("div");
    renderFileList(container, [makeFile({ path: "sbc_hal", patch: undefined, patchState: "queued", isSubmodule: true })], undefined, makeCallbacks());

    const dirrow = container.querySelector<HTMLElement>(`.dirrow[data-path="sbc_hal"]`)!;
    expect(dirrow.querySelector(".dirlabel")?.textContent).toBe("sbc_hal");
    expect(dirrow.querySelector(".submodule-badge")?.textContent).toBe("submodule");
    // A gitlink has no patch bytes, so neither a transfer spinner nor a +/- stat ever belongs here.
    expect(dirrow.querySelector(".transfer")).toBeNull();
    expect(dirrow.querySelector(".st")).toBeNull();
    // The pointer is no longer a leaf row at all.
    expect(container.querySelector(`.row[data-path="sbc_hal"]`)).toBeNull();

    expect(
      updateFileListRow(
        container,
        makeFile({
          path: "sbc_hal",
          patch: undefined,
          patchState: "ready",
          isSubmodule: true,
          submodule: { oldCommit: "a".repeat(40), newCommit: "b".repeat(40), dirty: true, unmerged: false, checkedOut: true },
        }),
      ),
    ).toBe("updated");

    expect(dirrow.querySelectorAll(".submodule-badge")).toHaveLength(1);
    expect(dirrow.querySelector(".submodule-badge")?.textContent).toBe("bbbbbbb");
  });

  it("titles the chip with the whole pointer label the diff's placeholder row shows", () => {
    const container = document.createElement("div");
    renderFileList(container, nestedSubmoduleFiles(), undefined, makeCallbacks());

    const chip = container.querySelector(`.dirrow[data-path="sbc_hal"] .submodule-badge`)!;
    expect(chip.getAttribute("title")).toBe("Submodule aaaaaaa → bbbbbbb (dirty)");
    expect(chip.getAttribute("aria-label")).toBe("Submodule pointer for sbc_hal");
  });

  it("shows the old side's commit for a submodule the comparison removed", () => {
    const container = document.createElement("div");
    renderFileList(
      container,
      [
        makeFile({
          path: "sbc_hal",
          status: "deleted",
          patch: undefined,
          submodule: { oldCommit: "c".repeat(40), dirty: false, unmerged: false, checkedOut: true },
        }),
      ],
      undefined,
      makeCallbacks(),
    );

    expect(container.querySelector(`.dirrow[data-path="sbc_hal"] .submodule-badge`)?.textContent).toBe("ccccccc");
  });

  it("marks a pointer with no checkout behind it orange, and gives it no disclosure of its own", () => {
    const container = document.createElement("div");
    renderFileList(
      container,
      [
        makeFile({
          path: "documentation",
          patch: undefined,
          // `dirty` is reported independently of `checkedOut`, so the tooltip must carry both.
          submodule: { oldCommit: "d".repeat(40), newCommit: "e".repeat(40), dirty: true, unmerged: false, checkedOut: false },
        }),
      ],
      undefined,
      makeCallbacks(),
    );

    const dirrow = container.querySelector<HTMLElement>(`.dirrow[data-path="documentation"]`)!;
    const chip = dirrow.querySelector(".submodule-badge")!;
    expect(chip.classList.contains("not-checked-out")).toBe(true);
    expect(chip.getAttribute("title")).toBe("Submodule ddddddd → eeeeeee (dirty), not checked out");
    // Nothing is nested under it, so the row is not a toggle: no triangle, no button semantics.
    expect(dirrow.querySelector(".tri")).toBeNull();
    expect(dirrow.getAttribute("role")).toBeNull();
    expect(dirrow.hasAttribute("aria-expanded")).toBe(false);
  });

  it("clicking the folder row toggles the submodule's files without selecting the pointer", () => {
    const container = document.createElement("div");
    const callbacks = makeCallbacks();
    renderFileList(container, nestedSubmoduleFiles(), undefined, callbacks);

    const dirrow = container.querySelector<HTMLElement>(`.dirrow[data-path="sbc_hal"]`)!;
    const childrenEl = dirrow.parentElement!.querySelector<HTMLElement>(".dir-children")!;
    expect(childrenEl.style.display).toBe("");

    dirrow.click();
    expect(childrenEl.style.display).toBe("none");
    dirrow.click();
    expect(childrenEl.style.display).toBe("");
    expect(callbacks.onSelect).not.toHaveBeenCalled();
  });

  it("collapses the submodule folder on a row click, persisting the drop and selecting nothing", () => {
    const container = document.createElement("div");
    const callbacks: FileListCallbacks = { onSelect: vi.fn(), onExpandedPathsChange: vi.fn() };
    renderFileList(container, nestedSubmoduleFiles(), undefined, callbacks, ["sbc_hal"]);

    const dirrow = container.querySelector<HTMLElement>(`.dirrow[data-path="sbc_hal"]`)!;
    const childrenEl = dirrow.parentElement!.querySelector<HTMLElement>(".dir-children")!;
    expect(dirrow.getAttribute("aria-expanded")).toBe("true");

    dirrow.click();

    // The one rule: the row is the disclosure, the chip is the selection. A click anywhere on the
    // row other than the chip must behave exactly like a plain folder's row click.
    expect(childrenEl.style.display).toBe("none");
    expect(dirrow.getAttribute("aria-expanded")).toBe("false");
    expect(callbacks.onExpandedPathsChange).toHaveBeenLastCalledWith([]);
    expect(callbacks.onSelect).not.toHaveBeenCalled();
  });

  it("collapses on a triangle click even while the pointer path is the selected path", () => {
    const container = document.createElement("div");
    const callbacks: FileListCallbacks = { onSelect: vi.fn(), onExpandedPathsChange: vi.fn() };
    // Selected AND expanded: the selected-path reveal must not put the expansion back, and the
    // highlight must not turn the row into a second way of selecting the pointer.
    renderFileList(container, nestedSubmoduleFiles(), "sbc_hal", callbacks, ["sbc_hal"]);

    const dirrow = container.querySelector<HTMLElement>(`.dirrow[data-path="sbc_hal"]`)!;
    expect(dirrow.classList.contains("on")).toBe(true);
    const childrenEl = dirrow.parentElement!.querySelector<HTMLElement>(".dir-children")!;

    dirrow.querySelector<HTMLElement>(".tri")!.click();

    expect(childrenEl.style.display).toBe("none");
    expect(dirrow.getAttribute("aria-expanded")).toBe("false");
    expect(callbacks.onExpandedPathsChange).toHaveBeenLastCalledWith([]);
    expect(callbacks.onSelect).not.toHaveBeenCalled();
  });

  it("clicking the chip selects the pointer path and leaves the folder open", () => {
    const container = document.createElement("div");
    const callbacks = makeCallbacks();
    renderFileList(container, nestedSubmoduleFiles(), undefined, callbacks);

    const dirrow = container.querySelector<HTMLElement>(`.dirrow[data-path="sbc_hal"]`)!;
    const childrenEl = dirrow.parentElement!.querySelector<HTMLElement>(".dir-children")!;
    dirrow.querySelector<HTMLElement>(".submodule-badge")!.click();

    expect(callbacks.onSelect).toHaveBeenCalledWith("sbc_hal");
    expect(childrenEl.style.display).toBe("");
  });

  it("activating the chip from the keyboard selects the pointer instead of toggling the folder", () => {
    const container = document.createElement("div");
    const callbacks = makeCallbacks();
    renderFileList(container, nestedSubmoduleFiles(), undefined, callbacks);

    const dirrow = container.querySelector<HTMLElement>(`.dirrow[data-path="sbc_hal"]`)!;
    const childrenEl = dirrow.parentElement!.querySelector<HTMLElement>(".dir-children")!;
    const chip = dirrow.querySelector<HTMLElement>(".submodule-badge")!;

    // The chip sits inside the folder row, whose own Enter/Space handler toggles the disclosure and
    // calls preventDefault. Left to bubble, that handler would swallow the button's activation: the
    // folder would close and the pointer would never be selected.
    const enter = new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true });
    chip.dispatchEvent(enter);

    expect(enter.defaultPrevented).toBe(false);
    expect(childrenEl.style.display).toBe("");
    expect(callbacks.onSelect).not.toHaveBeenCalled();

    // jsdom does not synthesize a button's click from a key press, so the browser's own follow-up is
    // dispatched here: it must still reach the chip's selection handler and still leave the folder open.
    chip.click();
    expect(callbacks.onSelect).toHaveBeenCalledWith("sbc_hal");
    expect(childrenEl.style.display).toBe("");
  });

  it("marks the submodule row selected when the pointer path is the selection", () => {
    const container = document.createElement("div");
    renderFileList(container, nestedSubmoduleFiles(), "sbc_hal", makeCallbacks());

    expect(container.querySelector(`.dirrow[data-path="sbc_hal"]`)!.classList.contains("on")).toBe(true);
  });

  it("nests the submodule's own files under the pointer row with their full data-path and stat counts", () => {
    const container = document.createElement("div");
    renderFileList(container, nestedSubmoduleFiles(), undefined, makeCallbacks());

    const dirrow = container.querySelector<HTMLElement>(`.dirrow[data-path="sbc_hal"]`)!;
    const nested = dirrow.parentElement!.querySelector<HTMLElement>(`.row[data-path="sbc_hal/.bumpversion.cfg"]`)!;
    expect(nested.querySelector(".fn")?.textContent).toBe(".bumpversion.cfg");
    expect(statText(container, "sbc_hal/.bumpversion.cfg")).toEqual({ additions: "+1", deletions: " -1" });
  });

  it("renders a removed pointer as a childless chip row beside the plain folder holding the superproject files", () => {
    const container = document.createElement("div");
    renderFileList(
      container,
      [
        makeFile({
          path: "A",
          status: "deleted",
          patch: undefined,
          isSubmodule: true,
          submodule: { oldCommit: "a".repeat(40), dirty: false, unmerged: false, checkedOut: false },
        }),
        // A superproject file at the same prefix: no `submodulePath`, so it is not the submodule's.
        makeFile({ path: "A/foo", patch: "@@ -1,1 +1,1 @@\n-old\n+new\n" }),
      ],
      undefined,
      makeCallbacks(),
    );

    const rows = [...container.querySelectorAll<HTMLElement>(".dirrow")];
    expect(rows).toHaveLength(2);
    const pointerRow = container.querySelector<HTMLElement>(`.dirrow[data-path="A"]`)!;
    expect(pointerRow.querySelector(".submodule-badge")?.textContent).toBe("aaaaaaa");
    expect(pointerRow.querySelector(".tri")).toBeNull();
    expect(pointerRow.getAttribute("role")).toBeNull();

    const plainRow = rows.find((row) => row !== pointerRow)!;
    expect(plainRow.querySelector(".dirlabel")?.textContent).toBe("A");
    expect(plainRow.querySelector(".submodule-badge")).toBeNull();
    expect(plainRow.querySelector(".tri")).not.toBeNull();
    // The superproject file is in the plain folder, not under the pointer that no longer has a checkout.
    expect(plainRow.parentElement!.querySelector(`.row[data-path="A/foo"]`)).not.toBeNull();
    expect(pointerRow.parentElement!.querySelector(".row")).toBeNull();

    // Two rows for one path, so their identifiers have to differ.
    expect(pointerRow.id).toBe(`code-pane-change-${encodeURIComponent("A")}`);
    expect(plainRow.id).toBe(`code-pane-diff-directory-${encodeURIComponent("A")}`);
  });

  it("identifies a submodule row as a change entry, not as a plain directory", () => {
    const container = document.createElement("div");
    renderFileList(container, nestedSubmoduleFiles(), undefined, makeCallbacks());

    const dirrow = container.querySelector<HTMLElement>(`.dirrow[data-path="sbc_hal"]`)!;
    expect(dirrow.id).toBe(`code-pane-change-${encodeURIComponent("sbc_hal")}`);
  });

  it("reports a pointer nested inside a collapsed submodule as hidden, then chips it when that folder opens", () => {
    const container = document.createElement("div");
    const nestedPointer = makeFile({
      path: "sbc_hal/api_commands",
      patch: undefined,
      isSubmodule: true,
      submodulePath: "sbc_hal",
    });
    // An empty expanded-paths array is meaningful persisted state: every directory starts collapsed.
    renderFileList(container, [...nestedSubmoduleFiles(), nestedPointer], undefined, makeCallbacks(), []);

    const resolved: DiffFileEntry = {
      ...nestedPointer,
      submodule: { newCommit: "f".repeat(40), dirty: false, unmerged: false, checkedOut: true },
    };
    expect(updateFileListRow(container, resolved)).toBe("hidden");

    container.querySelector<HTMLElement>(`.dirrow[data-path="sbc_hal"]`)!.click();
    expect(container.querySelector(`.dirrow[data-path="sbc_hal/api_commands"] .submodule-badge`)?.textContent).toBe("fffffff");
  });

  it("reveals a restored selection that is itself a nested pointer, by expanding the submodule above it", () => {
    const container = document.createElement("div");
    const files = [
      ...nestedSubmoduleFiles(),
      makeFile({ path: "sbc_hal/api_commands", patch: undefined, isSubmodule: true, submodulePath: "sbc_hal" }),
    ];

    // Everything collapsed, and the selection is a pointer path, which names a directory row rather
    // than a file row: its enclosing submodule still has to open for that row to be on screen.
    renderFileList(container, files, "sbc_hal/api_commands", makeCallbacks(), []);

    const outer = container.querySelector<HTMLElement>(`.dirrow[data-path="sbc_hal"]`)!;
    expect(outer.parentElement!.querySelector<HTMLElement>(".dir-children")!.style.display).toBe("");
    const nested = container.querySelector<HTMLElement>(`.dirrow[data-path="sbc_hal/api_commands"]`)!;
    expect(nested.classList.contains("on")).toBe(true);
  });

  it("expands both submodule folders for a restored selection nested two submodules deep", () => {
    const container = document.createElement("div");
    const files = [
      ...nestedSubmoduleFiles(),
      makeFile({ path: "sbc_hal/api_commands", patch: undefined, isSubmodule: true, submodulePath: "sbc_hal" }),
      makeFile({ path: "sbc_hal/api_commands/uart.c", submodulePath: "sbc_hal/api_commands", patch: "@@ -1,1 +1,1 @@\n-old\n+new\n" }),
    ];

    renderFileList(container, files, "sbc_hal/api_commands/uart.c", makeCallbacks(), []);

    const row = container.querySelector<HTMLElement>(`.row[data-path="sbc_hal/api_commands/uart.c"]`)!;
    expect(row.className).toContain("on");
    for (const path of ["sbc_hal", "sbc_hal/api_commands"]) {
      const group = container.querySelector<HTMLElement>(`.dirrow[data-path="${path}"]`)!.parentElement!;
      expect(group.querySelector<HTMLElement>(".dir-children")!.style.display).toBe("");
    }
  });
});
