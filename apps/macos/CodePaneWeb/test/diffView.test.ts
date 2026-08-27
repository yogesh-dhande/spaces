import { beforeEach, describe, expect, it, vi } from "vitest";
import { CodeView } from "@pierre/diffs";
import * as PierreDiffs from "@pierre/diffs";
import { DiffView } from "../src/app/diffView";
import type { DiffCommentHooks } from "../src/app/diffView";
import type { AnchoredComment } from "../src/app/reviewComments";
import { DiffFileEntry, SpacesReviewComment } from "../src/bridge/types";

type FakeCodeViewItem = {
  type: string;
  version: number | undefined;
  annotations: unknown;
  file?: { contents: string; cacheKey?: string };
};

type FakeCodeViewInput = {
  id: string;
  type: string;
  version: number | undefined;
  annotations?: unknown;
  file?: { contents: string; cacheKey?: string };
};

// `@pierre/diffs`' real `CodeView.syncItemRecord` (`dist/components/CodeView.js`) short-circuits
// `if (item.version === nextItem.version) return false` for BOTH `setItems` and `updateItem` — a
// reused record's fields (including `annotations`) are adopted only when `version` actually
// changes; there is no independent value-diffing of `annotations`. Model that short-circuit here
// so a test against this fake fails exactly the way the real library does when `diffView.ts`
// forgets to bump an item's version. The no-op fakes in root.test.ts/editorView.test.ts don't
// track item state at all, so they can't catch this class of bug.
const control = vi.hoisted(() => ({
  items: new Map<string, FakeCodeViewItem>(),
  scrollCalls: [] as Array<unknown>,
  // Records every `setSelectedLines` call made against the most recently constructed `FakeCodeView`
  // — used by the "clears the stuck gutter selection" tests below (see defect 1's doc comment on
  // `DiffView.requestNewComment`). `null` is exactly what a selection-clear call passes.
  setSelectedLinesCalls: [] as Array<unknown>,
  // The options object each `FakeCodeView` was constructed with — lets a test reach in and invoke
  // `onGutterUtilityClick` directly, the same way the real library's `InteractionManager` would on a
  // gutter pointerup.
  lastOptions: undefined as Record<string, unknown> | undefined,
  // The most recently constructed `FakeCodeView` instance — lets a test call `setSelectedLines`
  // directly on it to simulate the library's own post-hook re-assert (see the "keeps the selection
  // cleared" test below).
  lastInstance: undefined as { setSelectedLines(selection: unknown): void } | undefined,
  setItemsCalls: [] as Array<ReadonlyArray<FakeCodeViewInput>>,
  addItemCalls: [] as FakeCodeViewInput[],
}));

vi.mock("@pierre/diffs", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@pierre/diffs")>();
  function syncItem(items: Map<string, FakeCodeViewItem>, next: {
    id: string;
    type: string;
    version: number | undefined;
    annotations?: unknown;
    file?: { contents: string; cacheKey?: string };
  }): boolean {
    const existing = items.get(next.id);
    if (existing && existing.version === next.version) return false;
    items.set(next.id, { type: next.type, version: next.version, annotations: next.annotations, file: next.file });
    return true;
  }
  class FakeCodeView {
    private readonly items = new Map<string, FakeCodeViewItem>();

    constructor(options: Record<string, unknown>) {
      // A real CodeView owns its item records. Keeping these per fake instance prevents a
      // deferred attach poll from a prior view from mutating the next test's renderer model.
      control.items = this.items;
      control.lastOptions = options;
      control.lastInstance = this;
    }
    setup(): void {}
    setOptions(): void {}
    getScrollTop(): number {
      return 0;
    }
    scrollTo(input: unknown): void {
      control.scrollCalls.push(input);
    }
    cleanUp(): void {}
    getEditor(): object {
      return {};
    }
    setSelectedLines(selection: unknown): void {
      control.setSelectedLinesCalls.push(selection);
    }
    clearSelectedLines(): void {
      control.setSelectedLinesCalls.push(null);
    }
    setItems(items: ReadonlyArray<FakeCodeViewInput>): void {
      control.setItemsCalls.push(items);
      const nextIds = new Set(items.map((item) => item.id));
      for (const id of [...this.items.keys()]) {
        if (!nextIds.has(id)) this.items.delete(id);
      }
      for (const next of items) syncItem(this.items, next);
    }
    addItem(item: FakeCodeViewInput): void {
      control.addItemCalls.push(item);
      if (this.items.has(item.id)) throw new Error(`Duplicate item ${item.id}`);
      syncItem(this.items, item);
    }
    updateItem(input: {
      id: string;
      type: string;
      version: number | undefined;
      annotations?: unknown;
      file?: { contents: string; cacheKey?: string };
    }): boolean {
      const existing = this.items.get(input.id);
      if (!existing) return false;
      // Pierre keeps a concrete renderer instance per item type. `updateItem` can update a
      // renderer's data, but it cannot turn a placeholder File renderer into a FileDiff renderer.
      if (existing.type !== input.type) throw new Error(`Cannot update ${existing.type} item as ${input.type}`);
      return syncItem(this.items, input);
    }
  }
  return { ...actual, CodeView: FakeCodeView };
});

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
  return { path: "src/foo.ts", status: "modified", patch: PATCH, isBinary: false, ...overrides };
}

function comment(overrides: Partial<SpacesReviewComment> = {}): SpacesReviewComment {
  return {
    id: "c1",
    filePath: "src/foo.ts",
    side: "new",
    lineNumber: 11,
    lineText: "const b = newHelper();",
    body: "",
    createdAt: "2026-01-01T00:00:00.000Z",
    revision: 0,
    ...overrides,
  };
}

function anchoredAt(c: SpacesReviewComment): AnchoredComment {
  return { comment: c, position: { lineNumber: c.lineNumber, outdated: false } };
}

function makeHooks(): DiffCommentHooks {
  return {
    renderCard: () => document.createElement("div"),
    onRequestNewComment: () => {},
  };
}

beforeEach(() => {
  control.items.clear();
  control.scrollCalls = [];
  control.setSelectedLinesCalls = [];
  control.lastOptions = undefined;
  control.lastInstance = undefined;
  control.setItemsCalls = [];
  control.addItemCalls = [];
});

describe("DiffView.setComments", () => {
  it("surfaces a newly added comment's annotation in the CodeView item", () => {
    const diffView = new DiffView(document.createElement("div"), "unified", makeHooks());
    diffView.setFiles([file()], false);

    diffView.setComments([anchoredAt(comment())]);

    const item = control.items.get("src/foo.ts");
    const annotations = item?.annotations as Array<{ metadata: AnchoredComment }> | undefined;
    expect(annotations?.[0]?.metadata.comment.id).toBe("c1");
  });

  it("clears an item's annotation once its comment is removed", () => {
    const diffView = new DiffView(document.createElement("div"), "unified", makeHooks());
    diffView.setFiles([file()], false);
    diffView.setComments([anchoredAt(comment())]);
    expect(control.items.get("src/foo.ts")?.annotations).toBeDefined();

    diffView.setComments([]);

    expect(control.items.get("src/foo.ts")?.annotations).toBeUndefined();
  });

  it("does not bump an unrelated file's item version when only another file's comments change", () => {
    const diffView = new DiffView(document.createElement("div"), "unified", makeHooks());
    diffView.setFiles([file(), file({ path: "src/bar.ts" })], false);
    const unrelatedVersionBefore = control.items.get("src/bar.ts")?.version;

    diffView.setComments([anchoredAt(comment())]); // only src/foo.ts gets a comment

    expect(control.items.get("src/bar.ts")?.version).toBe(unrelatedVersionBefore);
  });

  // Regression for a version-reseed collision: `setFiles` reseeds every file's `itemVersions` entry
  // to `generation`, while `setComments` bumped a changed file's entry to `(itemVersions.get(path)
  // ?? generation) + 1` — a value one greater than the CURRENT `generation`, not one drawn from
  // `generation` itself. After exactly one `setComments` bump, the next `setFiles` call increments
  // `generation` by 1 and reseeds to that value, which is the exact same number `setComments` already
  // issued. `CodeView.syncItemRecord`'s `if (item.version === nextItem.version) return false` then
  // silently drops the reseeded file's fresh content. The fix makes every version assignment — both
  // the `setFiles` reseed and the `setComments` per-file bump — draw a fresh increment of the single
  // `generation` counter, so no issued version can ever repeat.
  it("issues a version for a reseeded file that differs from the version setComments already assigned it (regression: reseed collision)", () => {
    const diffView = new DiffView(document.createElement("div"), "unified", makeHooks());
    diffView.setFiles([file()], false);

    diffView.setComments([anchoredAt(comment())]); // bumps src/foo.ts's own itemVersions entry
    const versionAfterCommentBump = control.items.get("src/foo.ts")?.version;
    expect(versionAfterCommentBump).toBeDefined();

    // A live refresh that reseeds the same file (e.g. a `diffSignature` event), preserving scroll.
    diffView.setFiles([file()], true);

    // If the reseeded version collided with `versionAfterCommentBump`, the fake's `syncItemRecord`
    // short-circuit (modeling the real library) would drop the update and leave the stored version
    // unchanged — exactly the bug this guards against.
    expect(control.items.get("src/foo.ts")?.version).not.toBe(versionAfterCommentBump);
  });
});

describe("DiffView progressive patch replacement", () => {
  it("keeps the current logical scroll and focus through a queued preserve-scroll refresh until its patch re-renders", () => {
    const host = document.createElement("div");
    document.body.appendChild(host);
    const diffView = new DiffView(host, "unified", makeHooks());
    const current = file({ path: "src/current.ts", patchState: "ready" });
    const queuedReplacement = file({ path: current.path, patch: undefined, patchState: "queued" });
    diffView.setFiles([current], false);

    const root = host.querySelector<HTMLElement>("#code-pane-diff-scroll")!;
    const visibleLine = document.createElement("div");
    visibleLine.dataset.line = "11";
    visibleLine.dataset.diffPath = current.path;
    visibleLine.dataset.diffSide = "new";
    Object.defineProperty(root, "getBoundingClientRect", { value: () => ({ top: 0 }) });
    Object.defineProperty(visibleLine, "getBoundingClientRect", { value: () => ({ bottom: 1 }) });
    root.appendChild(visibleLine);
    (control.lastOptions?.onLineClick as ((range: { start: number; side: string }, context: { type: string; item: { id: string } }) => void) | undefined)?.(
      { start: 12, side: "additions" },
      { type: "diff", item: { id: current.path } },
    );
    control.scrollCalls = [];
    control.setSelectedLinesCalls = [];

    // The live manifest arrives before any replacement patch. Pierre removes the old rendered
    // line at this point, so only a captured logical location can survive until this path streams.
    diffView.setFiles([queuedReplacement], true);
    visibleLine.remove();
    expect(diffView.durableScrollPosition()).toEqual({ path: current.path, line: 11, side: "new" });
    expect(diffView.focusedPosition()).toEqual({ path: current.path, line: 12, side: "new" });

    diffView.updateFile(file({ path: current.path, patchState: "ready" }));
    const onPostRender = control.lastOptions?.onPostRender as
      | ((node: HTMLElement, context: { item: { id: string } }) => void)
      | undefined;
    onPostRender?.(document.createElement("div"), { item: { id: current.path } });

    expect(control.scrollCalls).toContainEqual({
      type: "line",
      id: current.path,
      lineNumber: 11,
      side: "additions",
      behavior: "instant",
    });
    expect(control.setSelectedLinesCalls).toContainEqual({
      id: current.path,
      range: { start: 12, end: 12, side: "additions", endSide: "additions" },
    });
    host.remove();
  });

  it("leaves queued patches out of CodeView and appends each completed patch once", () => {
    const diffView = new DiffView(document.createElement("div"), "unified", makeHooks());
    const first = file({ path: "src/first.ts", patch: undefined, patchState: "queued" });
    const second = file({ path: "src/second.ts", patch: undefined, patchState: "queued" });
    diffView.setFiles([first, second], false);

    expect(control.items.size).toBe(0);
    diffView.updateFile(file({ path: first.path, patchState: "ready" }));

    expect(control.addItemCalls).toHaveLength(1);
    expect(control.addItemCalls[0]?.id).toBe(first.path);
    expect(control.items.size).toBe(1);
  });

  it("appends a completed patch and can later replace its renderer type", () => {
    const diffView = new DiffView(document.createElement("div"), "unified", makeHooks());
    const queued = file({ patch: undefined, patchState: "queued" });
    diffView.setFiles([queued], false);
    expect(control.items.get(queued.path)).toBeUndefined();

    expect(() => diffView.updateFile(file({ patchState: "ready" }))).not.toThrow();
    expect(control.items.get(queued.path)?.type).toBe("diff");

    expect(() => diffView.updateFile(file({ isBinary: true, patch: undefined, patchState: "ready" }))).not.toThrow();
    expect(control.items.get(queued.path)?.type).toBe("file");
  });

  it("processes only the streamed file while appending it beside an unchanged patch", () => {
    const diffView = new DiffView(document.createElement("div"), "unified", makeHooks());
    const queued = file({ patch: undefined, patchState: "queued" });
    const unchanged = file({ path: "src/unchanged.ts", patchState: "ready" });
    diffView.setFiles([queued, unchanged], false);
    const unchangedItem = control.setItemsCalls.at(-1)?.[0];
    const unchangedVersion = control.items.get(unchanged.path)?.version;
    const processFileSpy = vi.spyOn(PierreDiffs, "processFile").mockClear();

    diffView.updateFile(file({ patchState: "ready" }));

    expect(processFileSpy).toHaveBeenCalledTimes(1);
    expect(control.addItemCalls.at(-1)?.id).toBe(queued.path);
    expect(control.setItemsCalls).toHaveLength(1);
    expect(control.items.get(unchanged.path)).toMatchObject({ version: unchangedVersion });
    expect(unchangedItem).toBeDefined();
    expect(control.items.get(unchanged.path)?.version).toBe(unchangedVersion);
    processFileSpy.mockRestore();
  });

  it("repairs manifest order once after a priority stream appends completed files out of order", () => {
    const diffView = new DiffView(document.createElement("div"), "unified", makeHooks());
    const first = file({ path: "src/1.ts", patch: undefined, patchState: "queued" });
    const second = file({ path: "src/2.ts", patch: undefined, patchState: "queued" });
    const selected = file({ path: "src/50.ts", patch: undefined, patchState: "queued" });
    diffView.setFiles([first, second, selected], false);
    diffView.updateFile(file({ path: first.path, patchState: "ready" }));
    diffView.updateFile(file({ path: selected.path, patchState: "ready" }));
    diffView.updateFile(file({ path: second.path, patchState: "ready" }));

    diffView.finalizeStreamOrder();

    expect(control.setItemsCalls.at(-1)?.map((item) => item.id)).toEqual([first.path, second.path, selected.path]);
  });

  it("keeps the current visible line in view while reconciling priority stream order", () => {
    const host = document.createElement("div");
    document.body.appendChild(host);
    const diffView = new DiffView(host, "unified", makeHooks());
    const first = file({ path: "src/1.ts", patch: undefined, patchState: "queued" });
    const selected = file({ path: "src/50.ts", patch: undefined, patchState: "queued" });
    diffView.setFiles([first, selected], false);
    diffView.updateFile(file({ path: selected.path, patchState: "ready" }));
    diffView.updateFile(file({ path: first.path, patchState: "ready" }));
    const visibleLine = document.createElement("div");
    visibleLine.dataset.line = "3";
    visibleLine.dataset.diffPath = selected.path;
    visibleLine.dataset.diffSide = "new";
    host.querySelector("#code-pane-diff-scroll")!.appendChild(visibleLine);

    diffView.finalizeStreamOrder();

    expect(control.scrollCalls.at(-1)).toEqual({
      type: "line",
      id: selected.path,
      lineNumber: 3,
      side: "additions",
      behavior: "instant",
    });
    host.remove();
  });
});

describe("DiffView inline edit", () => {
  it("removes a recovery-only editor item without rebuilding unchanged diff items", () => {
    const diffView = new DiffView(document.createElement("div"), "unified", makeHooks());
    const unchanged = file({ path: "src/unchanged.ts" });
    diffView.setFiles([unchanged], false);
    const unchangedItem = control.setItemsCalls.at(-1)?.[0];

    diffView.beginEdit("src/omitted.ts", "unsaved recovery\n", true);
    expect(control.setItemsCalls.at(-1)?.[1]).toBe(unchangedItem);

    diffView.endEdit("src/omitted.ts");

    expect(control.setItemsCalls.at(-1)?.[0]).toBe(unchangedItem);
  });

  it("keeps a detached dirty edit as a reachable Save/Cancel surface when the refreshed manifest no longer names its path", () => {
    const diffView = new DiffView(document.createElement("div"), "unified", makeHooks());
    diffView.setFiles([], true);

    diffView.beginEdit("src/omitted.ts", "unsaved recovery\n", true);

    expect(control.items.get("src/omitted.ts")).toMatchObject({
      type: "file",
      file: { contents: "unsaved recovery\n" },
    });
    const header = (control.lastOptions?.renderHeaderMetadata as ((file: { name: string }) => HTMLElement | undefined) | undefined)?.({
      name: "src/omitted.ts",
    });
    expect(header?.textContent).toContain("Unsaved changes");
    expect(header?.querySelector("#code-pane-diff-edit-save")).not.toBeNull();
    expect(header?.querySelector("#code-pane-diff-edit-cancel")).not.toBeNull();
  });

  it("keeps a dirty editor reachable when a diff refresh fails", () => {
    const host = document.createElement("div");
    document.body.appendChild(host);
    const diffView = new DiffView(host, "unified", makeHooks());
    diffView.setFiles([file()], false);
    diffView.beginEdit("src/foo.ts", "unsaved recovery\n", true);

    diffView.setError("Unable to load this workspace's diff.");

    const root = host.querySelector<HTMLElement>("#code-pane-diff-scroll")!;
    const error = host.querySelector<HTMLElement>(".empty-state")!;
    expect(error.textContent).toBe("Unable to load this workspace's diff.");
    expect(error.style.display).toBe("flex");
    expect(root.style.display).not.toBe("none");
    expect(control.items.get("src/foo.ts")).toMatchObject({
      type: "file",
      file: { contents: "unsaved recovery\n" },
    });
    const header = (control.lastOptions?.renderHeaderMetadata as ((file: { name: string }) => HTMLElement | undefined) | undefined)?.({
      name: "src/foo.ts",
    });
    expect(header?.textContent).toContain("Unsaved changes");
    expect(header?.querySelector("#code-pane-diff-edit-save")).not.toBeNull();
    expect(header?.querySelector("#code-pane-diff-edit-cancel")).not.toBeNull();

    host.remove();
  });

  it("keeps a dirty editor reachable while a diff refresh is loading", () => {
    const host = document.createElement("div");
    document.body.appendChild(host);
    const diffView = new DiffView(host, "unified", makeHooks());
    diffView.setFiles([file(), file({ path: "src/stale.ts" })], false);
    diffView.beginEdit("src/foo.ts", "unsaved recovery\n", true);

    diffView.setLoading();

    const root = host.querySelector<HTMLElement>("#code-pane-diff-scroll")!;
    const loading = host.querySelector<HTMLElement>(".empty-state")!;
    expect(loading.textContent).toBe("Loading diff…");
    expect(loading.style.display).toBe("flex");
    expect(root.style.display).not.toBe("none");
    expect(control.items.get("src/foo.ts")).toMatchObject({
      type: "file",
      file: { contents: "unsaved recovery\n" },
    });
    const header = (control.lastOptions?.renderHeaderMetadata as ((file: { name: string }) => HTMLElement | undefined) | undefined)?.({
      name: "src/foo.ts",
    });
    expect(header?.textContent).toContain("Unsaved changes");
    expect(header?.querySelector("#code-pane-diff-edit-save")).not.toBeNull();
    expect(header?.querySelector("#code-pane-diff-edit-cancel")).not.toBeNull();

    expect(control.items.has("src/stale.ts")).toBe(false);
    // A successful replacement adopts the real manifest without dropping the active editor, and a
    // later durable failure promotes it back to the same recovery surface.
    diffView.setFiles([file()], false);
    expect(loading.style.display).toBe("none");
    expect(control.items.get("src/foo.ts")).toMatchObject({ file: { contents: "unsaved recovery\n" } });
    diffView.setError("Unable to load this workspace's diff.");
    expect(loading.textContent).toBe("Unable to load this workspace's diff.");
    expect(root.style.display).not.toBe("none");
    expect(control.items.get("src/foo.ts")).toMatchObject({ file: { contents: "unsaved recovery\n" } });
    host.remove();
  });

  it("keeps Save and Cancel available while waiting to discard edits and open another file", () => {
    const onDiscardAndOpenDiffEdit = vi.fn();
    const diffView = new DiffView(document.createElement("div"), "unified", {
      ...makeHooks(),
      onDiscardAndOpenDiffEdit,
    });
    diffView.setFiles([file()], false);
    diffView.beginEdit("src/foo.ts", "unsaved\n", true);
    diffView.requestOpenAfterDiscard("src/bar.ts");

    const header = (control.lastOptions?.renderHeaderMetadata as ((file: { name: string }) => HTMLElement | undefined) | undefined)?.({
      name: "src/foo.ts",
    })!;
    expect(header.querySelector("#code-pane-diff-edit-save")).not.toBeNull();
    expect(header.querySelector("#code-pane-diff-edit-cancel")).not.toBeNull();
    const discard = [...header.querySelectorAll<HTMLButtonElement>("button")].find((button) => button.textContent === "Discard edits and open")!;
    discard.click();
    expect(onDiscardAndOpenDiffEdit).toHaveBeenCalledWith("src/foo.ts", "src/bar.ts");
  });

  it("uses the supplied workspace content for the editable right-side item instead of the patch's partial new side", () => {
    const diffView = new DiffView(document.createElement("div"), "unified", makeHooks());
    diffView.setFiles([file()], false);

    diffView.beginEdit("src/foo.ts", "const diskOnly = true;\n");

    expect(control.items.get("src/foo.ts")).toMatchObject({
      type: "file",
      file: { contents: "const diskOnly = true;\n" },
    });
  });

  it("ends the prior clean edit before opening a different file, leaving one editable item", () => {
    const diffView = new DiffView(document.createElement("div"), "unified", makeHooks());
    diffView.setFiles([file(), file({ path: "src/bar.ts" })], false);
    diffView.beginEdit("src/foo.ts", "foo disk\n");

    diffView.beginEdit("src/bar.ts", "bar disk\n");

    expect(control.items.get("src/foo.ts")?.type).toBe("diff");
    expect(control.items.get("src/bar.ts")).toMatchObject({ type: "file", file: { contents: "bar disk\n" } });
  });

  it("keeps a clean external adoption clean while replacing the editor document", () => {
    const diffView = new DiffView(document.createElement("div"), "unified", makeHooks());
    diffView.setFiles([file()], false);
    diffView.beginEdit("src/foo.ts", "before\n");

    diffView.replaceEditContent("src/foo.ts", "adopted from disk\n", false);

    const header = (control.lastOptions?.renderHeaderMetadata as ((file: { name: string }) => HTMLElement | undefined) | undefined)?.({
      name: "src/foo.ts",
    });
    expect(control.items.get("src/foo.ts")).toMatchObject({ file: { contents: "adopted from disk\n" } });
    expect(header?.textContent).toContain("Editing");
    expect(header?.querySelector<HTMLButtonElement>("#code-pane-diff-edit-save")?.disabled).toBe(true);
  });

  it("replaces a dirty inline editor with a read-only disk-versus-buffer comparison until an explicit conflict action", () => {
    const onDiffEditChange = vi.fn();
    const onResolveDiffEdit = vi.fn();
    const hooks = { ...makeHooks(), onDiffEditChange, onResolveDiffEdit };
    const diffView = new DiffView(document.createElement("div"), "unified", hooks);
    diffView.setFiles([file()], false);
    diffView.beginEdit("src/foo.ts", "const value = mine;\n", true);

    diffView.setEditConflict("src/foo.ts", { kind: "changed", diskContent: "const value = disk;\n" });

    // A `diff` item is Pierre's non-editable comparison surface, while the regular inline edit is
    // a `file` item. The old disk version is supplied as the old side and the frozen buffer as the
    // new side, so the user can decide without accidentally changing either version.
    expect(control.items.get("src/foo.ts")?.type).toBe("diff");
    const header = (control.lastOptions?.renderHeaderMetadata as ((file: { name: string }) => HTMLElement | undefined) | undefined)?.({
      name: "src/foo.ts",
    });
    expect(header?.textContent).toContain("Workspace changed");
    expect(header?.querySelector("#code-pane-diff-edit-save")).toBeNull();
    expect(header?.querySelector("#code-pane-diff-edit-cancel")).toBeNull();
    const actions = [...((header?.querySelectorAll("button") ?? []) as NodeListOf<HTMLButtonElement>)];
    expect(actions.map((button) => button.textContent)).toEqual(["Take disk", "Keep mine"]);
    actions[0]!.click();
    actions[1]!.click();
    expect(onResolveDiffEdit).toHaveBeenNthCalledWith(1, "src/foo.ts", "takeDisk");
    expect(onResolveDiffEdit).toHaveBeenNthCalledWith(2, "src/foo.ts", "keepMine");

    // A stale editor callback cannot mutate the frozen buffer after conflict entry.
    (control.lastOptions?.onItemEditChange as ((item: { id: string; type: string }, file: { contents: string }) => void) | undefined)?.(
      { id: "src/foo.ts", type: "file" },
      { contents: "must not replace mine\n" },
    );
    expect(onDiffEditChange).not.toHaveBeenCalled();
  });

  it("offers an explicit close-without-saving resolution when the conflicted file was deleted", () => {
    const onResolveDiffEdit = vi.fn();
    const diffView = new DiffView(document.createElement("div"), "unified", { ...makeHooks(), onResolveDiffEdit });
    diffView.setFiles([file()], false);
    diffView.beginEdit("src/foo.ts", "const value = mine;\n", true);
    diffView.setEditConflict("src/foo.ts", { kind: "deleted" });

    const header = (control.lastOptions?.renderHeaderMetadata as ((file: { name: string }) => HTMLElement | undefined) | undefined)?.({
      name: "src/foo.ts",
    });
    const close = [...(header?.querySelectorAll<HTMLButtonElement>("button") ?? [])].find(
      (button) => button.textContent === "Close without saving",
    )!;
    close.click();
    expect(onResolveDiffEdit).toHaveBeenCalledWith("src/foo.ts", "closeWithoutSaving");
  });

  it("uses header metadata only while editing so queued, binary, and ordinary files keep Pierre's filename header", () => {
    const diffView = new DiffView(document.createElement("div"), "unified", makeHooks());
    diffView.setFiles(
      [
        file(),
        file({ path: "queued.ts", patch: undefined, patchState: "queued" }),
        file({ path: "binary.bin", isBinary: true, patch: undefined, patchState: "ready" }),
      ],
      false,
    );

    // `renderCustomHeader` replaces the library's complete filename header even when it returns
    // undefined. The metadata slot augments the normal header instead, and remains empty outside
    // the active editor.
    expect(control.lastOptions?.renderCustomHeader).toBeUndefined();
    const renderHeaderMetadata = control.lastOptions?.renderHeaderMetadata as
      | ((file: { name: string }) => HTMLElement | undefined)
      | undefined;
    expect(renderHeaderMetadata?.({ name: "src/foo.ts" })).toBeUndefined();
    expect(renderHeaderMetadata?.({ name: "queued.ts" })).toBeUndefined();
    expect(renderHeaderMetadata?.({ name: "binary.bin" })).toBeUndefined();

    diffView.beginEdit("src/foo.ts", "editor contents\n");
    expect(renderHeaderMetadata?.({ name: "src/foo.ts" })?.textContent).toContain("Editing");
  });
});

describe("DiffView visible recovery position", () => {
  it("pairs the visible source line with its rendered file path rather than sidebar selection state", () => {
    const host = document.createElement("div");
    document.body.appendChild(host);
    const diffView = new DiffView(host, "unified", makeHooks());
    const root = host.querySelector<HTMLElement>("#code-pane-diff-scroll")!;
    const line = document.createElement("div");
    line.dataset.line = "42";
    line.dataset.diffPath = "src/visible.ts";
    line.dataset.diffSide = "old";
    root.appendChild(line);

    expect(diffView.visiblePosition()).toEqual({ path: "src/visible.ts", line: 42, side: "old" });
    host.remove();
  });

  it("does not report a rendered line after its scroll root is detached", () => {
    const host = document.createElement("div");
    document.body.appendChild(host);
    const diffView = new DiffView(host, "unified", makeHooks());
    const root = host.querySelector<HTMLElement>("#code-pane-diff-scroll")!;
    const line = document.createElement("div");
    line.dataset.line = "42";
    line.dataset.diffPath = "src/visible.ts";
    line.dataset.diffSide = "old";
    root.appendChild(line);

    expect(diffView.visiblePosition()).toEqual({ path: "src/visible.ts", line: 42, side: "old" });
    host.remove();
    expect(diffView.visiblePosition()).toBeNull();
  });

  it("waits for the persisted target's textual patch post-render before restoring its line and focus", () => {
    const diffView = new DiffView(document.createElement("div"), "unified", makeHooks());
    const queued = file({ path: "src/delayed.ts", patch: undefined, patchState: "queued" });
    diffView.setFiles([queued], false);

    diffView.restorePosition(queued.path, 11, "old", queued.path, 12, "old");
    expect(control.scrollCalls).toEqual([]);
    expect(control.setSelectedLinesCalls).toEqual([]);

    diffView.updateFile(file({ path: queued.path, patchState: "ready" }));
    expect(control.scrollCalls).toEqual([]);

    const onPostRender = control.lastOptions?.onPostRender as
      | ((node: HTMLElement, context: { item: { id: string } }) => void)
      | undefined;
    onPostRender?.(document.createElement("div"), { item: { id: queued.path } });

    expect(control.scrollCalls).toContainEqual({
      type: "line",
      id: queued.path,
      lineNumber: 11,
      side: "deletions",
      behavior: "instant",
    });
    expect(control.setSelectedLinesCalls).toContainEqual({
      id: queued.path,
      range: { start: 12, end: 12, side: "deletions", endSide: "deletions" },
    });
  });

  it("does not infer the additions side from an incomplete recovered position", () => {
    const ready = file({ path: "src/incomplete.ts", patchState: "ready" });
    const diffView = new DiffView(document.createElement("div"), "unified", makeHooks());
    diffView.setFiles([ready], false);

    diffView.restorePosition(ready.path, 7, null, ready.path, 8, null);

    expect(control.scrollCalls).toEqual([]);
    expect(control.setSelectedLinesCalls).toEqual([]);
  });
});

describe("DiffView.setComments forceCardRender", () => {
  // Regression for `CommentsController.refreshCardsOnly()`: it deliberately passes the SAME comment
  // objects and anchors through `setComments` to force each commented file's card DOM to re-render
  // agent-dependent state (the Send button's label/disabled state), even though nothing about the
  // comments or their positions changed. The `annotationListEquals` short-circuit that skips
  // unnecessary re-renders would otherwise skip exactly this case. `forceCardRender: true` bypasses
  // that check.
  it("bumps the version and updates the CodeView item when forceCardRender is true, even though the comment list is unchanged", () => {
    const diffView = new DiffView(document.createElement("div"), "unified", makeHooks());
    diffView.setFiles([file()], false);
    const list = [anchoredAt(comment())];
    diffView.setComments(list);
    const versionAfterFirstComments = control.items.get("src/foo.ts")?.version;

    const updateItemSpy = vi.spyOn(CodeView.prototype, "updateItem");
    updateItemSpy.mockClear();

    diffView.setComments(list, true); // same objects, same anchors, forced

    expect(updateItemSpy).toHaveBeenCalled();
    expect(control.items.get("src/foo.ts")?.version).not.toBe(versionAfterFirstComments);
    updateItemSpy.mockRestore();
  });

  it("skips updateItem when the same comment list is passed again without forceCardRender (optimization preserved)", () => {
    const diffView = new DiffView(document.createElement("div"), "unified", makeHooks());
    diffView.setFiles([file()], false);
    const list = [anchoredAt(comment())];
    diffView.setComments(list);

    const updateItemSpy = vi.spyOn(CodeView.prototype, "updateItem");
    updateItemSpy.mockClear();

    diffView.setComments(list); // same objects, same anchors, no force

    expect(updateItemSpy).not.toHaveBeenCalled();
    updateItemSpy.mockRestore();
  });
});

describe("DiffView gutter-utility click", () => {
  // Regression: `@pierre/diffs`' `InteractionManager` sets its own `selectedRange` on a
  // gutter-utility pointerdown and never clears it in this configuration (line-selection mode is
  // off) — see `dist/managers/InteractionManager.js`'s `handleDocumentPointerUp` "gutterSelecting"
  // case. Left unhandled, the clicked line stays highlighted forever and a later gutter click
  // re-anchors to that stale selection instead of the newly clicked line — reported as "the line
  // stays highlighted... and I cannot add any other comments in that file." `DiffView.
  // requestNewComment` must clear the selection itself once the draft is created. The clear is
  // deferred to a microtask (see that method's doc comment), so these assertions run after a
  // microtask flush.
  it("clears the gutter selection after requesting a new comment", async () => {
    const hooks = makeHooks();
    const diffView = new DiffView(document.createElement("div"), "unified", hooks);
    diffView.setFiles([file()], false);

    const onGutterUtilityClick = control.lastOptions?.onGutterUtilityClick as
      | ((range: { start: number; end: number; side: "additions" | "deletions" }, context: unknown) => void)
      | undefined;
    expect(onGutterUtilityClick).toBeDefined();

    onGutterUtilityClick!({ start: 11, end: 11, side: "additions" }, { type: "diff", item: { id: "src/foo.ts" } });
    await Promise.resolve(); // flush the queued microtask clear

    expect(control.setSelectedLinesCalls).toEqual([null]);
  });

  it("requests a new comment before clearing the selection", async () => {
    const hooks = makeHooks();
    const onRequestNewComment = vi.fn();
    hooks.onRequestNewComment = onRequestNewComment;
    const diffView = new DiffView(document.createElement("div"), "unified", hooks);
    diffView.setFiles([file()], false);

    const onGutterUtilityClick = control.lastOptions?.onGutterUtilityClick as
      | ((range: { start: number; end: number; side: "additions" | "deletions" }, context: unknown) => void)
      | undefined;
    onGutterUtilityClick!({ start: 11, end: 11, side: "additions" }, { type: "diff", item: { id: "src/foo.ts" } });
    await Promise.resolve(); // flush the queued microtask clear

    expect(onRequestNewComment).toHaveBeenCalledTimes(1);
    expect(control.setSelectedLinesCalls).toEqual([null]);
  });

  // Regression: the library doesn't just leave the old selection alone after our hook runs — it
  // actively re-asserts it. `InteractionManager`'s "gutterSelecting" pointerup case calls our
  // `onGutterUtilityClick` hook and THEN, still in the same synchronous pointerup dispatch, calls
  // `notifySelectionCommitted`, which fires `CodeView`'s wrapped `onLineSelected` ->
  // `applySelectedLines` and re-sets the same selection. A clear issued synchronously from inside
  // our hook (the original, buggy implementation) runs BEFORE that re-assert and gets overwritten
  // by it, so the highlight never actually goes away. Queuing the clear as a microtask lets it run
  // after the whole pointerup dispatch — including the re-assert simulated here — has finished.
  it("keeps the selection cleared even when the library re-asserts it synchronously afterward", async () => {
    const hooks = makeHooks();
    const diffView = new DiffView(document.createElement("div"), "unified", hooks);
    diffView.setFiles([file()], false);

    const onGutterUtilityClick = control.lastOptions?.onGutterUtilityClick as
      | ((range: { start: number; end: number; side: "additions" | "deletions" }, context: unknown) => void)
      | undefined;
    const fakeCodeView = control.lastInstance;
    expect(onGutterUtilityClick).toBeDefined();
    expect(fakeCodeView).toBeDefined();

    onGutterUtilityClick!({ start: 11, end: 11, side: "additions" }, { type: "diff", item: { id: "src/foo.ts" } });
    // Simulate the library's own re-assert, which happens synchronously right after our hook
    // returns (still within the pointerup dispatch, before any queued microtask gets a turn).
    fakeCodeView!.setSelectedLines({ start: 11, end: 11, side: "additions" });
    expect(control.setSelectedLinesCalls.at(-1)).not.toBeNull(); // re-asserted, not yet cleared

    await Promise.resolve(); // flush the queued microtask clear, which runs after the re-assert

    expect(control.setSelectedLinesCalls.at(-1)).toBeNull();
  });
});
