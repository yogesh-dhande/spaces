import { describe, expect, it, vi } from "vitest";
import { SpacesBridgeError, WorkspaceFileListResult } from "../src/bridge/types";
import { ContextMenu, ContextMenuRequest } from "../src/app/contextMenu";
import { EditorSidebar, EditorSidebarBridge, EditorSidebarCallbacks } from "../src/app/editorSidebar";
import { FolderPicker } from "../src/app/folderPicker";
import { WorkspaceFileListCache } from "../src/app/workspaceFileListCache";

// jsdom has no scrollIntoView; the Files tree's FilesTreeHandle.setSelected calls it on every
// selection change (see setSelectedPath's tests below).
Element.prototype.scrollIntoView = function scrollIntoView(): void {};

function makeResult(paths: string[], truncated = false): WorkspaceFileListResult {
  return { paths, truncated, submodules: [], emptyDirectories: [] };
}

/** Builds a real `WorkspaceFileListCache` over a `vi.fn()` bridge stub — exercises the real
 *  cache/sidebar integration rather than mocking the cache class away. */
function makeCache(workspaceFileList = vi.fn().mockResolvedValue(makeResult([]))): {
  cache: WorkspaceFileListCache;
  bridge: ReturnType<typeof vi.fn>;
} {
  const cache = new WorkspaceFileListCache({ workspaceFileList });
  return { cache, bridge: workspaceFileList };
}

function makeCallbacks(): EditorSidebarCallbacks {
  return { onModeChange: vi.fn(), isUnopenable: () => false, onEntryMoved: vi.fn() };
}

/** The narrowed bridge slice EditorSidebar needs for the Files tree's pointer-menu mutations; none
 *  of the tests below exercise those mutations directly (see filesTreeMenu.test.ts for that), so
 *  every method just rejects, matching the "not used" convention `test/root.test.ts` uses for
 *  bridge methods a given test doesn't care about. */
function makeBridge(): EditorSidebarBridge {
  return {
    workspaceFileWrite: vi.fn().mockRejectedValue(new Error("not used")),
    workspaceFileCreateDirectory: vi.fn().mockRejectedValue(new Error("not used")),
    workspaceFileRename: vi.fn().mockRejectedValue(new Error("not used")),
    workspaceFileDelete: vi.fn().mockRejectedValue(new Error("not used")),
    openInSystemViewer: vi.fn().mockRejectedValue(new Error("not used")),
  };
}

/** A real `FolderPicker` on a throwaway host: the sidebar only threads it through to the Files
 *  tree, and the Move to… flow itself is covered in filesTreeMenu.test.ts. */
function makeFolderPicker(): FolderPicker {
  return new FolderPicker(document.createElement("div"));
}

function makeContextMenu(): ContextMenu {
  return { show: vi.fn(), hide: vi.fn(), isOpen: () => false };
}

/** A context menu that records what it was asked to show, so a test can pick an item by label the
 *  way the real menu's `activate()` does. */
function makeRecordingContextMenu(): ContextMenu & { calls: ContextMenuRequest[] } {
  const calls: ContextMenuRequest[] = [];
  return { calls, show: (request) => calls.push(request), hide: vi.fn(), isOpen: () => false };
}

function makeChangesListEl(): HTMLElement {
  const el = document.createElement("div");
  el.className = "changes-list-host";
  return el;
}

/** Files/Changes header buttons in DOM order (Files first, then Changes — see the constructor's
 *  append order). */
function headerButtons(sidebar: EditorSidebar): [HTMLButtonElement, HTMLButtonElement] {
  const [filesBtn, changesBtn] = [...sidebar.el.querySelectorAll("button")] as HTMLButtonElement[];
  return [filesBtn!, changesBtn!];
}

describe("EditorSidebar", () => {
  it("shows the Files tab active but does NOT fetch the workspace listing when constructed on 'files' (Finding 1)", () => {
    const { cache, bridge } = makeCache(vi.fn().mockResolvedValue(makeResult(["a.ts", "b.ts"])));
    const sidebar = new EditorSidebar(
      makeChangesListEl(),
      cache,
      makeBridge(),
      makeContextMenu(),
      makeFolderPicker(),
      { sidebarMode: "files", selectedPath: undefined, changesAvailable: true, isLocalWorkspace: true },
      vi.fn(),
      makeCallbacks(),
    );

    const [filesBtn, changesBtn] = headerButtons(sidebar);
    expect(filesBtn.className).toContain("on");
    expect(changesBtn.className).not.toContain("on");
    // A diff-only pane constructs this same sidebar even though it never shows it; the constructor
    // must not pay for a workspaceFileList RPC on the daemon's shared per-workspace git queue for it.
    expect(bridge).not.toHaveBeenCalled();
    expect(sidebar.el.querySelector(".empty")?.textContent).toBe("No files");
  });

  it("fetches the workspace listing on the first reattach() after construction (root.ts's first-show call)", async () => {
    const { cache, bridge } = makeCache(vi.fn().mockResolvedValue(makeResult(["a.ts", "b.ts"])));
    const sidebar = new EditorSidebar(
      makeChangesListEl(),
      cache,
      makeBridge(),
      makeContextMenu(),
      makeFolderPicker(),
      { sidebarMode: "files", selectedPath: undefined, changesAvailable: true, isLocalWorkspace: true },
      vi.fn(),
      makeCallbacks(),
    );

    expect(bridge).not.toHaveBeenCalled();
    sidebar.reattach();
    expect(bridge).toHaveBeenCalledTimes(1);

    await vi.waitFor(() => expect(sidebar.el.querySelectorAll(".row")).toHaveLength(2));
    const fnTexts = [...sidebar.el.querySelectorAll(".row .fn")].map((el) => el.textContent);
    expect(fnTexts).toEqual(["a.ts", "b.ts"]);
  });

  it("fetches the workspace listing when the Changes tab is switched to Files (setMode is also a first-show point)", async () => {
    const { cache, bridge } = makeCache(vi.fn().mockResolvedValue(makeResult(["a.ts"])));
    const sidebar = new EditorSidebar(
      makeChangesListEl(),
      cache,
      makeBridge(),
      makeContextMenu(),
      makeFolderPicker(),
      { sidebarMode: "changes", selectedPath: undefined, changesAvailable: true, isLocalWorkspace: true },
      vi.fn(),
      makeCallbacks(),
    );

    expect(bridge).not.toHaveBeenCalled();
    const [filesBtn] = headerButtons(sidebar);
    filesBtn.click();
    expect(bridge).toHaveBeenCalledTimes(1);

    await vi.waitFor(() => expect(sidebar.el.querySelectorAll(".row")).toHaveLength(1));
  });

  it("reparents changesListEl into its list host when constructed on 'changes', without fetching", () => {
    const { cache, bridge } = makeCache();
    const changesListEl = makeChangesListEl();
    const sidebar = new EditorSidebar(
      changesListEl,
      cache,
      makeBridge(),
      makeContextMenu(),
      makeFolderPicker(),
      { sidebarMode: "changes", selectedPath: undefined, changesAvailable: true, isLocalWorkspace: true },
      vi.fn(),
      makeCallbacks(),
    );

    const [filesBtn, changesBtn] = headerButtons(sidebar);
    expect(changesBtn.className).toContain("on");
    expect(filesBtn.className).not.toContain("on");
    expect(sidebar.el.contains(changesListEl)).toBe(true);
    expect(bridge).not.toHaveBeenCalled();
  });

  it("clicking the inactive tab switches mode, calls onModeChange, and reparents changesListEl", () => {
    const { cache } = makeCache(vi.fn().mockResolvedValue(makeResult([])));
    const changesListEl = makeChangesListEl();
    const callbacks = makeCallbacks();
    const sidebar = new EditorSidebar(
      changesListEl,
      cache,
      makeBridge(),
      makeContextMenu(),
      makeFolderPicker(),
      { sidebarMode: "files", selectedPath: undefined, changesAvailable: true, isLocalWorkspace: true },
      vi.fn(),
      callbacks,
    );

    expect(sidebar.el.contains(changesListEl)).toBe(false);
    const [filesBtn, changesBtn] = headerButtons(sidebar);

    changesBtn.click();
    expect(callbacks.onModeChange).toHaveBeenCalledWith("changes");
    expect(sidebar.el.contains(changesListEl)).toBe(true);
    expect(changesBtn.className).toContain("on");
    expect(filesBtn.className).not.toContain("on");

    filesBtn.click();
    expect(callbacks.onModeChange).toHaveBeenCalledWith("files");
    expect(sidebar.el.contains(changesListEl)).toBe(false);
    expect(filesBtn.className).toContain("on");
  });

  it("clicking the already-active tab is a no-op and does not call onModeChange", () => {
    const { cache } = makeCache(vi.fn().mockResolvedValue(makeResult([])));
    const callbacks = makeCallbacks();
    const sidebar = new EditorSidebar(
      makeChangesListEl(),
      cache,
      makeBridge(),
      makeContextMenu(),
      makeFolderPicker(),
      { sidebarMode: "files", selectedPath: undefined, changesAvailable: true, isLocalWorkspace: true },
      vi.fn(),
      callbacks,
    );

    const [filesBtn] = headerButtons(sidebar);
    filesBtn.click();

    expect(callbacks.onModeChange).not.toHaveBeenCalled();
  });

  it("clicking a file row in the Files tree invokes onSelectFile with its full path", async () => {
    const { cache } = makeCache(vi.fn().mockResolvedValue(makeResult(["a.ts", "dir/b.ts"])));
    const onSelectFile = vi.fn();
    const sidebar = new EditorSidebar(
      makeChangesListEl(),
      cache,
      makeBridge(),
      makeContextMenu(),
      makeFolderPicker(),
      { sidebarMode: "files", selectedPath: undefined, changesAvailable: true, isLocalWorkspace: true },
      onSelectFile,
      makeCallbacks(),
    );
    sidebar.reattach(); // first show: triggers the listing fetch

    await vi.waitFor(() => expect(sidebar.el.querySelectorAll(".row")).toHaveLength(1)); // "dir" starts collapsed
    (sidebar.el.querySelector(".dirrow") as HTMLElement).click(); // expand "dir" to reach its row

    const row = sidebar.el.querySelector('.row[data-path="dir/b.ts"]') as HTMLElement;
    row.click();

    expect(onSelectFile).toHaveBeenCalledWith("dir/b.ts");
  });

  it("setSelectedPath re-renders the Files tree so the given path's row gets the on class", async () => {
    const { cache } = makeCache(vi.fn().mockResolvedValue(makeResult(["a.ts", "b.ts"])));
    const sidebar = new EditorSidebar(
      makeChangesListEl(),
      cache,
      makeBridge(),
      makeContextMenu(),
      makeFolderPicker(),
      { sidebarMode: "files", selectedPath: undefined, changesAvailable: true, isLocalWorkspace: true },
      vi.fn(),
      makeCallbacks(),
    );
    sidebar.reattach(); // first show: triggers the listing fetch

    await vi.waitFor(() => expect(sidebar.el.querySelectorAll(".row")).toHaveLength(2));
    expect(sidebar.el.querySelector(".row.on")).toBeNull();

    sidebar.setSelectedPath("b.ts");

    const onRow = sidebar.el.querySelector(".row.on") as HTMLElement;
    expect(onRow.getAttribute("data-path")).toBe("b.ts");
  });

  it("setSelectedPath while on the Changes tab does not throw and leaves the Changes list undisturbed", () => {
    const { cache } = makeCache(vi.fn().mockResolvedValue(makeResult([])));
    const changesListEl = makeChangesListEl();
    changesListEl.textContent = "changes content";
    const sidebar = new EditorSidebar(
      changesListEl,
      cache,
      makeBridge(),
      makeContextMenu(),
      makeFolderPicker(),
      { sidebarMode: "changes", selectedPath: undefined, changesAvailable: true, isLocalWorkspace: true },
      vi.fn(),
      makeCallbacks(),
    );

    expect(() => sidebar.setSelectedPath("b.ts")).not.toThrow();
    expect(sidebar.el.contains(changesListEl)).toBe(true);
    expect(changesListEl.textContent).toBe("changes content");
  });

  it("refreshFilesListing() on the Files tab calls the cache's getFresh() again, revalidating in the background", async () => {
    const bridgeFn = vi.fn();
    bridgeFn.mockResolvedValueOnce(makeResult(["a.ts"]));
    bridgeFn.mockResolvedValueOnce(makeResult(["a.ts", "b.ts"]));
    const { cache } = makeCache(bridgeFn);
    const getFreshSpy = vi.spyOn(cache, "getFresh");
    const sidebar = new EditorSidebar(
      makeChangesListEl(),
      cache,
      makeBridge(),
      makeContextMenu(),
      makeFolderPicker(),
      { sidebarMode: "files", selectedPath: undefined, changesAvailable: true, isLocalWorkspace: true },
      vi.fn(),
      makeCallbacks(),
    );
    sidebar.reattach(); // first show: triggers the initial listing fetch

    await vi.waitFor(() => expect(sidebar.el.querySelectorAll(".row")).toHaveLength(1));
    expect(getFreshSpy).toHaveBeenCalledTimes(1);
    expect(bridgeFn).toHaveBeenCalledTimes(1);

    sidebar.refreshFilesListing();

    expect(getFreshSpy).toHaveBeenCalledTimes(2);
    // getFresh() revalidates in the background even without an explicit invalidate() —
    // renderList() runs on every Files-tab "show", which refreshFilesListing() is one path into.
    expect(bridgeFn).toHaveBeenCalledTimes(2);
    await vi.waitFor(() => expect(sidebar.el.querySelectorAll(".row")).toHaveLength(2));
  });

  it("reattach() on the Files tab with a cached listing revalidates in the background and re-renders on arrival (Finding 1)", async () => {
    const bridgeFn = vi.fn();
    bridgeFn.mockResolvedValueOnce(makeResult(["a.ts"]));
    const { promise: freshPromise, resolve: resolveFresh } = (() => {
      let resolveFn!: (value: WorkspaceFileListResult) => void;
      const p = new Promise<WorkspaceFileListResult>((res) => {
        resolveFn = res;
      });
      return { promise: p, resolve: resolveFn };
    })();
    bridgeFn.mockReturnValueOnce(freshPromise);
    const { cache } = makeCache(bridgeFn);
    const sidebar = new EditorSidebar(
      makeChangesListEl(),
      cache,
      makeBridge(),
      makeContextMenu(),
      makeFolderPicker(),
      { sidebarMode: "files", selectedPath: undefined, changesAvailable: true, isLocalWorkspace: true },
      vi.fn(),
      makeCallbacks(),
    );
    sidebar.reattach(); // first show: this is the "cached listing" this test's SECOND reattach() revalidates

    await vi.waitFor(() => expect(sidebar.el.querySelectorAll(".row")).toHaveLength(1));

    // reattach() is the diff→editor re-entry path (the other "show" point that triggers a fetch,
    // alongside a tab click) — a non-git workspace or a pane that never fetched a diff has no diff-signature
    // push to invalidate the cache, so this revalidation is the only thing that keeps it fresh.
    sidebar.reattach();
    expect(bridgeFn).toHaveBeenCalledTimes(2);
    // Stays on the stale row until the revalidation resolves — no blanking while it's in flight.
    expect([...sidebar.el.querySelectorAll(".row .fn")].map((el) => el.textContent)).toEqual(["a.ts"]);

    resolveFresh(makeResult(["a.ts", "b.ts"]));
    await vi.waitFor(() => expect(sidebar.el.querySelectorAll(".row")).toHaveLength(2));
    const fnTexts = [...sidebar.el.querySelectorAll(".row .fn")].map((el) => el.textContent);
    expect(fnTexts).toEqual(["a.ts", "b.ts"]);
  });

  it("refreshFilesListing() reflects a fresh listing once the cache is invalidated first", async () => {
    const bridgeFn = vi.fn();
    bridgeFn.mockResolvedValueOnce(makeResult(["a.ts"]));
    bridgeFn.mockResolvedValueOnce(makeResult(["b.ts", "c.ts"]));
    const { cache } = makeCache(bridgeFn);
    const sidebar = new EditorSidebar(
      makeChangesListEl(),
      cache,
      makeBridge(),
      makeContextMenu(),
      makeFolderPicker(),
      { sidebarMode: "files", selectedPath: undefined, changesAvailable: true, isLocalWorkspace: true },
      vi.fn(),
      makeCallbacks(),
    );
    sidebar.reattach(); // first show: triggers the initial listing fetch

    await vi.waitFor(() => expect(sidebar.el.querySelectorAll(".row")).toHaveLength(1));

    cache.invalidate();
    sidebar.refreshFilesListing();

    await vi.waitFor(() => expect(sidebar.el.querySelectorAll(".row")).toHaveLength(2));
    const fnTexts = [...sidebar.el.querySelectorAll(".row .fn")].map((el) => el.textContent);
    expect(fnTexts).toEqual(["b.ts", "c.ts"]);
  });

  it("refreshFilesListing() on the Changes tab is a no-op — cache.get() is not called", () => {
    const { cache, bridge } = makeCache(vi.fn().mockResolvedValue(makeResult(["a.ts"])));
    const getSpy = vi.spyOn(cache, "get");
    const sidebar = new EditorSidebar(
      makeChangesListEl(),
      cache,
      makeBridge(),
      makeContextMenu(),
      makeFolderPicker(),
      { sidebarMode: "changes", selectedPath: undefined, changesAvailable: true, isLocalWorkspace: true },
      vi.fn(),
      makeCallbacks(),
    );

    expect(getSpy).not.toHaveBeenCalled();
    sidebar.refreshFilesListing();
    expect(getSpy).not.toHaveBeenCalled();
    expect(bridge).not.toHaveBeenCalled();
  });

  it("a failed listing fetch on the Files tab does not throw or surface an unhandled rejection", async () => {
    const bridgeFn = vi.fn().mockRejectedValue(new Error("network down"));
    const { cache } = makeCache(bridgeFn);
    const sidebar = new EditorSidebar(
      makeChangesListEl(),
      cache,
      makeBridge(),
      makeContextMenu(),
      makeFolderPicker(),
      { sidebarMode: "files", selectedPath: undefined, changesAvailable: true, isLocalWorkspace: true },
      vi.fn(),
      makeCallbacks(),
    );
    sidebar.reattach(); // first show: triggers the listing fetch

    await vi.waitFor(() => expect(bridgeFn).toHaveBeenCalledTimes(1));
    // Let the fetch's .catch() run before asserting the tree is left untouched, not crashed.
    await vi.waitFor(() => expect(sidebar.el.querySelector(".empty")?.textContent).toBe("No files"));
  });

  it("switching to Changes while a Files fetch is pending does not reveal the truncation note once that stale fetch resolves truncated (Finding 2)", async () => {
    const { promise: pendingFetch, resolve: resolveFetch } = (() => {
      let resolveFn!: (value: WorkspaceFileListResult) => void;
      const p = new Promise<WorkspaceFileListResult>((res) => {
        resolveFn = res;
      });
      return { promise: p, resolve: resolveFn };
    })();
    const bridgeFn = vi.fn().mockReturnValue(pendingFetch);
    const { cache } = makeCache(bridgeFn);
    const sidebar = new EditorSidebar(
      makeChangesListEl(),
      cache,
      makeBridge(),
      makeContextMenu(),
      makeFolderPicker(),
      { sidebarMode: "files", selectedPath: undefined, changesAvailable: true, isLocalWorkspace: true },
      vi.fn(),
      makeCallbacks(),
    );
    sidebar.reattach(); // first show: starts the Files fetch this test leaves pending

    const [, changesBtn] = headerButtons(sidebar);
    changesBtn.click(); // leaves Files while its fetch is still in flight

    resolveFetch(makeResult(["a.ts"], /* truncated */ true));
    await new Promise((resolve) => setTimeout(resolve, 0)); // let the stale fetch's .then() run

    const note = sidebar.el.querySelector(".editor-sidebar-note") as HTMLElement;
    expect(note.hidden).toBe(true);
    expect(sidebar.el.contains(sidebar.el.querySelector(".changes-list-host"))).toBe(true);
  });

  it("paints the truncation note from cached state immediately when switching back to Files, before a pending revalidation resolves (Fix 2)", async () => {
    const bridgeFn = vi.fn();
    bridgeFn.mockResolvedValueOnce(makeResult(["a.ts"], /* truncated */ true));
    const { promise: pendingRevalidation, resolve: resolveRevalidation } = (() => {
      let resolveFn!: (value: WorkspaceFileListResult) => void;
      const p = new Promise<WorkspaceFileListResult>((res) => {
        resolveFn = res;
      });
      return { promise: p, resolve: resolveFn };
    })();
    bridgeFn.mockReturnValueOnce(pendingRevalidation);
    const { cache } = makeCache(bridgeFn);
    const sidebar = new EditorSidebar(
      makeChangesListEl(),
      cache,
      makeBridge(),
      makeContextMenu(),
      makeFolderPicker(),
      { sidebarMode: "files", selectedPath: undefined, changesAvailable: true, isLocalWorkspace: true },
      vi.fn(),
      makeCallbacks(),
    );
    sidebar.reattach(); // first show: resolves truncated, note becomes visible

    const note = sidebar.el.querySelector(".editor-sidebar-note") as HTMLElement;
    await vi.waitFor(() => expect(note.hidden).toBe(false));

    const [filesBtn, changesBtn] = headerButtons(sidebar);
    changesBtn.click();
    expect(note.hidden).toBe(true);

    // Switching back to Files starts a new (still-pending) revalidation, but the note must paint
    // from the cached truncated state immediately, not wait for that fetch to resolve.
    filesBtn.click();
    expect(note.hidden).toBe(false);

    resolveRevalidation(makeResult(["a.ts"], /* truncated */ true));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(note.hidden).toBe(false);
  });

  it("keeps the truncation note visible from cached state when switching back to Files while a revalidation is pending and then rejects", async () => {
    const bridgeFn = vi.fn();
    bridgeFn.mockResolvedValueOnce(makeResult(["a.ts"], /* truncated */ true));
    bridgeFn.mockRejectedValueOnce(new Error("network down"));
    const { cache } = makeCache(bridgeFn);
    const sidebar = new EditorSidebar(
      makeChangesListEl(),
      cache,
      makeBridge(),
      makeContextMenu(),
      makeFolderPicker(),
      { sidebarMode: "files", selectedPath: undefined, changesAvailable: true, isLocalWorkspace: true },
      vi.fn(),
      makeCallbacks(),
    );
    sidebar.reattach();

    const note = sidebar.el.querySelector(".editor-sidebar-note") as HTMLElement;
    await vi.waitFor(() => expect(note.hidden).toBe(false));

    const [filesBtn, changesBtn] = headerButtons(sidebar);
    changesBtn.click();
    expect(note.hidden).toBe(true);

    filesBtn.click();
    expect(note.hidden).toBe(false);

    await vi.waitFor(() => expect(bridgeFn).toHaveBeenCalledTimes(2));
    await new Promise((resolve) => setTimeout(resolve, 0)); // let the rejection's .catch() run
    expect(note.hidden).toBe(false);
  });

  it("seeds from another consumer's cache snapshot at construction, then keeps painting through its own revalidation (cross-consumer stale paint)", async () => {
    const bridgeFn = vi.fn();
    bridgeFn.mockResolvedValueOnce(makeResult(["a.ts", "b.ts"], /* truncated */ true)); // another consumer's fetch
    const { promise: pendingRevalidation, resolve: resolveRevalidation } = (() => {
      let resolveFn!: (value: WorkspaceFileListResult) => void;
      const p = new Promise<WorkspaceFileListResult>((res) => {
        resolveFn = res;
      });
      return { promise: p, resolve: resolveFn };
    })();
    bridgeFn.mockReturnValueOnce(pendingRevalidation); // this sidebar's own reattach()-time getFresh(), left pending
    const { cache } = makeCache(bridgeFn);

    // Simulates another consumer (e.g. the ⌘P overlay in Diff mode) having already populated the
    // shared cache before this sidebar ever exists.
    await cache.get();

    const sidebar = new EditorSidebar(
      makeChangesListEl(),
      cache,
      makeBridge(),
      makeContextMenu(),
      makeFolderPicker(),
      { sidebarMode: "files", selectedPath: undefined, changesAvailable: true, isLocalWorkspace: true },
      vi.fn(),
      makeCallbacks(),
    );

    // Painted synchronously at construction from the cache's snapshot — this instance has never
    // fetched a listing itself, but the shared cache already holds one. Construction still never
    // fetches on its own: the count below is just the OTHER consumer's call.
    expect(bridgeFn).toHaveBeenCalledTimes(1);
    let fnTexts = [...sidebar.el.querySelectorAll(".row .fn")].map((el) => el.textContent);
    expect(fnTexts).toEqual(["a.ts", "b.ts"]);
    const note = sidebar.el.querySelector(".editor-sidebar-note") as HTMLElement;
    expect(note.hidden).toBe(false);

    sidebar.reattach(); // first Files "show": kicks this sidebar's own (still-pending) revalidation
    expect(bridgeFn).toHaveBeenCalledTimes(2);
    // Stays painted from the seeded snapshot while that revalidation is in flight.
    fnTexts = [...sidebar.el.querySelectorAll(".row .fn")].map((el) => el.textContent);
    expect(fnTexts).toEqual(["a.ts", "b.ts"]);
    expect(note.hidden).toBe(false);

    resolveRevalidation(makeResult(["a.ts", "b.ts"], /* truncated */ true));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(note.hidden).toBe(false);
  });

  it("carries the Files tree alone and keeps Changes unreachable when changes are unavailable", () => {
    const { cache } = makeCache(vi.fn().mockResolvedValue(makeResult(["a.ts"])));
    const callbacks = makeCallbacks();
    const changesListEl = makeChangesListEl();
    const sidebar = new EditorSidebar(
      changesListEl,
      cache,
      makeBridge(),
      makeContextMenu(),
      makeFolderPicker(),
      { sidebarMode: "changes", selectedPath: undefined, changesAvailable: false, isLocalWorkspace: true },
      vi.fn(),
      callbacks,
    );

    // Saved state naming the Changes tab is coerced to Files, the segmented toggle is not rendered
    // at all, and the changed-files list stays out of this sidebar.
    expect(sidebar.getMode()).toBe("files");
    expect(sidebar.el.querySelector(".editor-sidebar-hdr")).toBeNull();
    expect(sidebar.el.contains(changesListEl)).toBe(false);

    // The Changes button lives on that unrendered header, so nothing in the pane can click it; the
    // guard inside setMode is what makes the tab unreachable rather than merely unclickable.
    (sidebar as unknown as { changesBtn: HTMLButtonElement }).changesBtn.click();
    expect(sidebar.getMode()).toBe("files");
    expect(callbacks.onModeChange).not.toHaveBeenCalled();
    expect(sidebar.el.contains(changesListEl)).toBe(false);
  });
});

describe("EditorSidebar: the Files tree's New file write", () => {
  // `editor` is the one write purpose that resolves through symlinks, which is exactly wrong for a
  // path the user just named in the tree: it would create the file at a dangling link's target, or
  // under a symlinked prefix, instead of at the row's own path. `createFile` makes the daemon resolve
  // the path directly, the same rule the create-directory/rename/delete commands follow.
  it("writes through the createFile purpose so the daemon refuses a symlinked path instead of following it", async () => {
    const { cache } = makeCache(vi.fn().mockResolvedValue(makeResult(["a.ts"])));
    const bridge = makeBridge();
    bridge.workspaceFileWrite = vi.fn().mockResolvedValue({ ok: true, sha256: "sha-new" });
    const menu = makeRecordingContextMenu();
    const sidebar = new EditorSidebar(
      makeChangesListEl(),
      cache,
      bridge,
      menu,
      makeFolderPicker(),
      { sidebarMode: "files", selectedPath: undefined, changesAvailable: true, isLocalWorkspace: true },
      vi.fn(),
      makeCallbacks(),
    );
    sidebar.reattach();
    await vi.waitFor(() => expect(sidebar.el.querySelectorAll(".row")).toHaveLength(1));

    const tree = sidebar.el.querySelector(".editor-sidebar-list")!.firstElementChild as HTMLElement;
    tree.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true }));
    menu.calls[0]!.items.find((item) => item.label === "New file")!.onSelect();

    const field = sidebar.el.querySelector("input.inline-name") as HTMLInputElement;
    field.value = "created.ts";
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    await vi.waitFor(() =>
      expect(bridge.workspaceFileWrite).toHaveBeenCalledWith("created.ts", "", { baseSHA256: undefined, purpose: "createFile" }),
    );
  });

  // The device refuses a create onto an existing path (an empty file at that path included, which a
  // compare-and-swap create would otherwise adopt as an already-landed write). The refusal has to reach
  // the user in place, under the row, with the field still open to correct the name.
  it("shows the device's conflict under the row and keeps the field open when the path already exists", async () => {
    const { cache } = makeCache(vi.fn().mockResolvedValue(makeResult(["taken.ts"])));
    const bridge = makeBridge();
    bridge.workspaceFileWrite = vi.fn().mockRejectedValue(new SpacesBridgeError("conflict", "'taken.ts' already exists."));
    const menu = makeRecordingContextMenu();
    const sidebar = new EditorSidebar(
      makeChangesListEl(),
      cache,
      bridge,
      menu,
      makeFolderPicker(),
      { sidebarMode: "files", selectedPath: undefined, changesAvailable: true, isLocalWorkspace: true },
      vi.fn(),
      makeCallbacks(),
    );
    sidebar.reattach();
    await vi.waitFor(() => expect(sidebar.el.querySelectorAll(".row")).toHaveLength(1));

    const tree = sidebar.el.querySelector(".editor-sidebar-list")!.firstElementChild as HTMLElement;
    tree.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true }));
    menu.calls[0]!.items.find((item) => item.label === "New file")!.onSelect();

    const field = sidebar.el.querySelector("input.inline-name") as HTMLInputElement;
    field.value = "taken.ts";
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));

    await vi.waitFor(() => expect(sidebar.el.querySelector(".inline-error")).not.toBeNull());
    expect(sidebar.el.querySelector(".inline-error")?.textContent).toBe("'taken.ts' already exists.");
    expect(sidebar.el.querySelector("input.inline-name")).toBe(field);
    expect(field.disabled).toBe(false);
  });
});

// Rename and Move to… both land on `workspaceFileRename`, and both move bytes the Editor may hold
// open. root.ts answers `onEntryMoved` by retargeting the Editor onto the destination, so the
// report has to be made once the device has actually moved the entry and never before.
describe("EditorSidebar: reporting a confirmed move", () => {
  async function renameFirstRow(
    bridge: EditorSidebarBridge,
    callbacks: EditorSidebarCallbacks,
    newName: string,
  ): Promise<EditorSidebar> {
    const { cache } = makeCache(vi.fn().mockResolvedValue(makeResult(["a.ts"])));
    const menu = makeRecordingContextMenu();
    const sidebar = new EditorSidebar(
      makeChangesListEl(),
      cache,
      bridge,
      menu,
      makeFolderPicker(),
      { sidebarMode: "files", selectedPath: undefined, changesAvailable: true, isLocalWorkspace: true },
      vi.fn(),
      callbacks,
    );
    sidebar.reattach();
    await vi.waitFor(() => expect(sidebar.el.querySelectorAll(".row")).toHaveLength(1));

    const row = sidebar.el.querySelector(".row") as HTMLElement;
    row.dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true }));
    menu.calls[0]!.items.find((item) => item.label === "Rename")!.onSelect();
    const field = sidebar.el.querySelector("input.inline-name") as HTMLInputElement;
    field.value = newName;
    field.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
    return sidebar;
  }

  it("reports the source and destination once the device confirms the rename", async () => {
    const bridge = makeBridge();
    bridge.workspaceFileRename = vi.fn().mockResolvedValue(undefined);
    const callbacks = makeCallbacks();
    await renameFirstRow(bridge, callbacks, "b.ts");

    await vi.waitFor(() => expect(callbacks.onEntryMoved).toHaveBeenCalledWith("a.ts", "b.ts"));
  });

  it("reports nothing when the device refuses the rename, and shows the refusal under the row", async () => {
    const bridge = makeBridge();
    bridge.workspaceFileRename = vi
      .fn()
      .mockRejectedValue(new SpacesBridgeError("invalidArgument", "Path is or contains a git submodule; move or delete it with git."));
    const callbacks = makeCallbacks();
    const sidebar = await renameFirstRow(bridge, callbacks, "b.ts");

    await vi.waitFor(() => expect(sidebar.el.querySelector(".inline-error")).not.toBeNull());
    expect(sidebar.el.querySelector(".inline-error")?.textContent).toBe(
      "Path is or contains a git submodule; move or delete it with git.",
    );
    expect(callbacks.onEntryMoved).not.toHaveBeenCalled();
  });

  it("re-keys the tree's expansion onto a moved directory's destination and reports it for persistence", async () => {
    const { cache } = makeCache(vi.fn().mockResolvedValue(makeResult(["src/b.ts", "src/util/a.ts", "other/c.ts"])));
    const onTreeStateChange = vi.fn();
    const sidebar = new EditorSidebar(
      makeChangesListEl(),
      cache,
      makeBridge(),
      makeContextMenu(),
      makeFolderPicker(),
      {
        sidebarMode: "files",
        selectedPath: undefined,
        expandedPaths: ["src", "src/util", "other"],
        changesAvailable: true,
        isLocalWorkspace: true,
      },
      vi.fn(),
      { ...makeCallbacks(), onTreeStateChange },
    );
    sidebar.reattach();
    await vi.waitFor(() => expect(sidebar.el.querySelectorAll(".dirrow").length).toBeGreaterThan(0));

    sidebar.retargetExpandedPaths("src", "lib");

    // The moved directory's own entry and every descendant's follow it; an unrelated directory's
    // expansion is untouched. Compared as a set, since the tree's own insertion order is not part
    // of what expansion means.
    const [reported] = onTreeStateChange.mock.calls.at(-1)! as [{ expandedPaths: readonly string[]; selectedPath: string | undefined }];
    expect([...reported.expandedPaths].sort()).toEqual(["lib", "lib/util", "other"]);
    expect(reported.selectedPath).toBeUndefined();
  });
});
