import { beforeEach, describe, expect, it, vi } from "vitest";
import { CodeView } from "@pierre/diffs";
import { DiffView } from "../src/app/diffView";
import type { DiffCommentHooks } from "../src/app/diffView";
import type { AnchoredComment } from "../src/app/reviewComments";
import { DiffFileEntry, SpacesReviewComment } from "../src/bridge/types";

type FakeCodeViewItem = { type: string; version: number | undefined; annotations: unknown };

// `@pierre/diffs`' real `CodeView.syncItemRecord` (`dist/components/CodeView.js`) short-circuits
// `if (item.version === nextItem.version) return false` for BOTH `setItems` and `updateItem` — a
// reused record's fields (including `annotations`) are adopted only when `version` actually
// changes; there is no independent value-diffing of `annotations`. Model that short-circuit here
// so a test against this fake fails exactly the way the real library does when `diffView.ts`
// forgets to bump an item's version. The no-op fakes in root.test.ts/editorView.test.ts don't
// track item state at all, so they can't catch this class of bug.
const control = vi.hoisted(() => ({
  items: new Map<string, FakeCodeViewItem>(),
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
}));

vi.mock("@pierre/diffs", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@pierre/diffs")>();
  function syncItem(next: { id: string; type: string; version: number | undefined; annotations?: unknown }): boolean {
    const existing = control.items.get(next.id);
    if (existing && existing.version === next.version) return false;
    control.items.set(next.id, { type: next.type, version: next.version, annotations: next.annotations });
    return true;
  }
  class FakeCodeView {
    constructor(options: Record<string, unknown>) {
      control.lastOptions = options;
      control.lastInstance = this;
    }
    setup(): void {}
    setOptions(): void {}
    getScrollTop(): number {
      return 0;
    }
    scrollTo(): void {}
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
    setItems(items: ReadonlyArray<{ id: string; type: string; version: number | undefined; annotations?: unknown }>): void {
      const nextIds = new Set(items.map((item) => item.id));
      for (const id of [...control.items.keys()]) {
        if (!nextIds.has(id)) control.items.delete(id);
      }
      for (const next of items) syncItem(next);
    }
    updateItem(input: { id: string; type: string; version: number | undefined; annotations?: unknown }): boolean {
      if (!control.items.has(input.id)) return false;
      return syncItem(input);
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
  return { path: "src/foo.ts", status: "modified", patch: PATCH, isBinary: false, truncated: false, ...overrides };
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
  control.setSelectedLinesCalls = [];
  control.lastOptions = undefined;
  control.lastInstance = undefined;
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
