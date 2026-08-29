import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { EditorView } from "../src/app/editorView";
import {
  FileSignatureEvent,
  SpacesBridge,
  SpacesBridgeError,
  WorkspaceFileReadResult,
  WorkspaceFileWriteResult,
} from "../src/bridge/types";

// EditorView's `open()` constructs a real `@pierre/diffs` CodeView on first
// success, which needs browser APIs jsdom doesn't provide (ResizeObserver,
// canvas). These tests are about editorView.ts's own request-routing and
// error-surfacing logic, not the diff-rendering library, so CodeView/Editor
// are replaced with no-op fakes; every other export (types, helpers) passes
// through untouched.
// Captures the options EditorView last constructed a (fake) CodeView with, so tests can invoke
// `onItemEditChange` directly to simulate a buffer edit without a real @pierre/diffs editor.
const capturedCodeViewOptions = vi.hoisted(() => ({ current: undefined as undefined | { onItemEditChange: (item: unknown, file: { contents: string }) => void } }));
// Controls FakeCodeView's editor-attach surface so the attach-heal poll (completeEditorAttach)
// can be tested: `editor` is what getEditor returns (undefined = attach still pending; the
// default `{}` = attach done, resolving the poll on its first frame), and `updateItemCalls`
// records every forced re-render the poll issues.
const fakeCodeViewControl = vi.hoisted(() => ({
  editor: {} as object | undefined,
  editorSelection: undefined as { start: { line: number }; end: { line: number }; direction: number } | undefined,
  updateItemCalls: [] as Array<{ id: string; version: number }>,
}));

vi.mock("@pierre/diffs", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@pierre/diffs")>();
  class FakeCodeView {
    constructor(options: { onItemEditChange: (item: unknown, file: { contents: string }) => void }) {
      capturedCodeViewOptions.current = options;
    }
    setup(): void {}
    setItems(): void {}
    cleanUp(): void {}
    getEditor(): object | undefined {
      if (fakeCodeViewControl.editor === undefined) return undefined;
      return fakeCodeViewControl.editorSelection === undefined
        ? fakeCodeViewControl.editor
        : { getState: () => ({ selections: [fakeCodeViewControl.editorSelection] }) };
    }
    updateItem(item: { id: string; version: number }): void {
      fakeCodeViewControl.updateItemCalls.push({ id: item.id, version: item.version });
    }
  }
  return { ...actual, CodeView: FakeCodeView };
});
vi.mock("@pierre/diffs/edit", () => ({
  Editor: class {},
}));

function makeBridge(overrides: Partial<SpacesBridge> = {}): SpacesBridge {
  return {
    workspaceDiffManifestChunk: vi.fn().mockRejectedValue(new Error("not used")),
    workspaceDiffFileChunk: vi.fn().mockRejectedValue(new Error("not used")),
    workspaceDiffFileChunkCancel: vi.fn().mockRejectedValue(new Error("not used")),
    workspaceDiffManifestRelease: vi.fn().mockRejectedValue(new Error("not used")),
    workspaceFileRead: vi.fn().mockRejectedValue(new Error("not used")),
    workspaceFileWrite: vi.fn().mockRejectedValue(new Error("not used")),
    workspaceFileList: vi.fn().mockRejectedValue(new SpacesBridgeError("unavailable", "File search is not available yet.")),
    // Not used by EditorView (ref search is diff-mode only) — stubbed so this satisfies
    // `SpacesBridge` without any of these tests needing to care about the compare menu.
    workspaceRefList: vi.fn().mockRejectedValue(new Error("not used")),
    subscribeDiffSignature: vi.fn(() => () => {}),
    subscribeFileListSignature: vi.fn(() => () => {}),
    subscribeFileSignature: vi.fn(() => () => {}),
    notifyWorkspaceStateChanged: vi.fn(),
    notifyRenderMetric: vi.fn(),
    // Not used by EditorView (comments are diff-mode only) — stubbed so this satisfies
    // `SpacesBridge` without any of these tests needing to care about the comment surface.
    reviewCommentList: vi.fn().mockRejectedValue(new Error("not used")),
    reviewCommentUpsert: vi.fn().mockRejectedValue(new Error("not used")),
    reviewCommentDelete: vi.fn().mockRejectedValue(new Error("not used")),
    reviewCommentsSend: vi.fn().mockRejectedValue(new Error("not used")),
    startWorkspaceCommand: vi.fn().mockRejectedValue(new Error("not used")),
    resumeWorkspaceCommandTracking: vi.fn().mockRejectedValue(new Error("not used")),
    ...overrides,
  };
}

/** Builds a bridge whose `subscribeFileSignature` captures the listener `EditorView` registers
 *  (replaced every time a new path is opened, mirroring the real bridge's one-subscription-at-a-time
 *  contract), so a test can drive `spaces:fileSignature` push events directly without a real
 *  `window.dispatchEvent` round trip. */
function makeFileSignatureCapturingBridge(overrides: Partial<SpacesBridge> = {}): {
  bridge: SpacesBridge;
  fireFileSignature: (event: FileSignatureEvent) => void;
} {
  let listener: ((event: FileSignatureEvent) => void) | undefined;
  const subscribeFileSignature = vi.fn((_path: string, l: (event: FileSignatureEvent) => void) => {
    listener = l;
    return () => {
      listener = undefined;
    };
  });
  const bridge = makeBridge({ subscribeFileSignature, ...overrides });
  return { bridge, fireFileSignature: (event) => listener?.(event) };
}

describe("EditorView — open() reads and opens a file directly", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
  });

  it("open() with a valid path reads it directly and opens it, with no error shown", async () => {
    const result: WorkspaceFileReadResult = { content: "export {}\n", sha256: "sha-1", size: 10 };
    const workspaceFileRead = vi.fn().mockResolvedValue(result);
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    view.open("src/app/root.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("src/app/root.ts", "editor"));

    expect(container.querySelector(".banner.error")).toBeNull();
    expect(container.querySelector(".editor-path")!.textContent).toBe("src/app/root.ts");
  });

  it("open() with a path the bridge rejects notFound shows the error banner", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockRejectedValue(new SpacesBridgeError("notFound", "No such file in the mock workspace: missing.ts"));
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    view.open("missing.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("missing.ts", "editor"));

    const errorBanner = await vi.waitFor(() => {
      const el = container.querySelector(".banner.error") as HTMLElement;
      expect(el).not.toBeNull();
      return el;
    });
    expect(errorBanner.style.display).toBe("flex");
    expect(errorBanner.textContent).toBe("No such file in the mock workspace: missing.ts");
  });
});

// The old third test in this block ("degrades workspaceFileList's unavailable rejection to a quiet
// hint, and Enter-open still works") is deliberately deleted, not adapted: it exercised the live
// search dropdown's degraded-search messaging, and that entire surface (search input, debounced
// `workspaceFileList` suggestions, the `.msg.hint`/`.msg.error` rows) moved out of `editorView.ts`
// with Design O — `workspaceFileList` is no longer called anywhere in this file. Coverage for how
// quick-open degrades when file search is unavailable belongs with `quickOpen.ts`, out of scope here.

// The old "EditorView — save conflict banner (Fix 3)" describe block (two tests: an ordinary
// hash-mismatch conflict latching a "File changed on disk — save disabled" banner, and a
// fileMissing conflict latching "File deleted on disk — save disabled") is deliberately deleted,
// not adapted: that permanent latch is exactly what this change replaces. A save-time CAS conflict
// now routes into the same `handleExternalChange` flow a live `spaces:fileSignature` push uses —
// see "EditorView — save() CAS conflict routes into external-change handling" below for its
// replacement coverage, and the "EditorView — external-change handling" block for the full
// clean-reload / auto-merge / conflict-compare-view contract this now follows.

describe("EditorView — save() catches a rejected write (round-8 Fix 2)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
    capturedCodeViewOptions.current = undefined;
  });

  /** Opens "src/app/root.ts" and marks it edited (via the captured fake CodeView's
   *  `onItemEditChange`, bypassing the real editor same as the conflict-banner tests above), leaving
   *  Save ready to click. */
  async function openAndEdit(bridge: SpacesBridge): Promise<{ saveBtn: HTMLButtonElement }> {
    const readResult: WorkspaceFileReadResult = { content: "export {}\n", sha256: "sha-1", size: 10 };
    (bridge.workspaceFileRead as ReturnType<typeof vi.fn>).mockResolvedValue(readResult);
    const view = new EditorView(container, bridge);

    view.open("src/app/root.ts");
    await vi.waitFor(() => expect(bridge.workspaceFileRead).toHaveBeenCalledWith("src/app/root.ts", "editor"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "export {}\nedited\n" });

    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    return { saveBtn };
  }

  it("a rejected write re-enables Save, shows a factual error banner (not a conflict), and does not latch save-blocked", async () => {
    const workspaceFileWrite = vi.fn().mockRejectedValue(new SpacesBridgeError("unavailable", "daemon not reachable"));
    const bridge = makeBridge({ workspaceFileWrite });
    const { saveBtn } = await openAndEdit(bridge);

    saveBtn.click();
    await vi.waitFor(() => expect(bridge.workspaceFileWrite).toHaveBeenCalledTimes(1));
    await vi.waitFor(() => expect(saveBtn.disabled).toBe(false)); // re-enabled: buffer is still dirty

    const errorBanner = container.querySelector(".banner.error") as HTMLElement;
    expect(errorBanner).not.toBeNull();
    expect(errorBanner.style.display).toBe("flex");
    expect(errorBanner.textContent).toBe("daemon not reachable");
    // Not classed (or rendered) as a real conflict: a transient save failure must not use the same
    // visual/latching state as a durable CAS rejection.
    expect(container.querySelector(".banner.conflict")).toBeNull();

    // No conflict latch: unlike a real conflict (which blocks every further save until the next
    // open()), a retry is not a no-op — it reaches the bridge again.
    workspaceFileWrite.mockResolvedValueOnce({ ok: true, sha256: "sha-2" });
    saveBtn.click();
    await vi.waitFor(() => expect(bridge.workspaceFileWrite).toHaveBeenCalledTimes(2));
  });

  it("a generic (non-SpacesBridgeError) rejection falls back to a generic message, mirroring open()'s own fallback", async () => {
    const workspaceFileWrite = vi.fn().mockRejectedValue(new Error("socket hung up"));
    const bridge = makeBridge({ workspaceFileWrite });
    const { saveBtn } = await openAndEdit(bridge);

    saveBtn.click();
    await vi.waitFor(() => expect(bridge.workspaceFileWrite).toHaveBeenCalledTimes(1));
    await vi.waitFor(() => expect(saveBtn.disabled).toBe(false));

    expect((container.querySelector(".banner.error") as HTMLElement).textContent).toBe("Failed to save file.");
  });

  it("a later successful save clears the error banner", async () => {
    const workspaceFileWrite = vi
      .fn()
      .mockRejectedValueOnce(new SpacesBridgeError("unavailable", "daemon not reachable"));
    const bridge = makeBridge({ workspaceFileWrite });
    const { saveBtn } = await openAndEdit(bridge);

    saveBtn.click();
    await vi.waitFor(() => expect(bridge.workspaceFileWrite).toHaveBeenCalledTimes(1));
    await vi.waitFor(() => expect(saveBtn.disabled).toBe(false));
    expect((container.querySelector(".banner.error") as HTMLElement).style.display).toBe("flex");

    workspaceFileWrite.mockResolvedValueOnce({ ok: true, sha256: "sha-2" });
    saveBtn.click();
    await vi.waitFor(() => expect(bridge.workspaceFileWrite).toHaveBeenCalledTimes(2));
    await vi.waitFor(() =>
      expect((container.querySelector(".banner.error") as HTMLElement).style.display).toBe("none"),
    );
  });

  it("a write rejection that resolves after opening a different file leaves the new file's state untouched", async () => {
    const bridge = makeBridge();
    (bridge.workspaceFileRead as ReturnType<typeof vi.fn>).mockImplementation((path: string) =>
      Promise.resolve(
        path === "a.ts"
          ? { content: "a content", sha256: "sha-a", size: 9 }
          : { content: "b content", sha256: "sha-b", size: 9 },
      ),
    );
    let rejectWrite!: (err: unknown) => void;
    const writePromise = new Promise<WorkspaceFileWriteResult>((_resolve, reject) => (rejectWrite = reject));
    (bridge.workspaceFileWrite as ReturnType<typeof vi.fn>).mockReturnValue(writePromise);
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(bridge.workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "a content edited" });

    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    saveBtn.click();
    await vi.waitFor(() =>
      expect(bridge.workspaceFileWrite).toHaveBeenCalledWith("a.ts", "a content edited", { baseSHA256: "sha-a" }),
    );

    // B is opened (and wins) while A's write is still in flight. A is still `dirty` (the save
    // hasn't resolved yet), so this goes through the discard gate (round-13 Fix 1) rather than
    // opening directly.
    view.open("b.ts");
    (container.querySelector(".banner.conflict button") as HTMLButtonElement).click();
    await vi.waitFor(() => expect(bridge.workspaceFileRead).toHaveBeenCalledWith("b.ts", "editor"));
    expect(saveBtn.disabled).toBe(true); // open()'s post-open state for B: nothing edited yet

    // A's write now fails. Same await-ordering guarantee as the sibling generation tests above:
    // save()'s own catch (registered on this promise back when it awaited it) fires before this
    // `.catch` continuation, so by the time this settles A's failure has already been dropped.
    rejectWrite(new SpacesBridgeError("unavailable", "daemon not reachable"));
    await writePromise.catch(() => {});

    expect(container.querySelector(".banner.error")).toBeNull();
    expect(saveBtn.disabled).toBe(true);
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({ path: "b.ts", baseSHA256: "sha-b", baseContent: "b content", content: "b content", dirty: false, conflict: false }),
    );
  });
});

describe("EditorView — CAS baseline from the write result (round-4 Fix 1)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
  });

  async function openAndSave(
    bridge: SpacesBridge,
  ): Promise<{ saveBtn: HTMLButtonElement }> {
    const readResult: WorkspaceFileReadResult = { content: "export {}\n", sha256: "sha-1", size: 10 };
    (bridge.workspaceFileRead as ReturnType<typeof vi.fn>).mockResolvedValue(readResult);
    const view = new EditorView(container, bridge);

    view.open("src/app/root.ts");
    await vi.waitFor(() => expect(bridge.workspaceFileRead).toHaveBeenCalledWith("src/app/root.ts", "editor"));

    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    saveBtn.disabled = false;
    saveBtn.click();
    await vi.waitFor(() => expect(bridge.workspaceFileWrite).toHaveBeenCalled());
    return { saveBtn };
  }

  it("adopts a successful write's own hash as the next save's baseSHA256, with no intervening file read", async () => {
    const workspaceFileWrite = vi
      .fn()
      .mockResolvedValueOnce({ ok: true, sha256: "write-sha-1" })
      .mockResolvedValueOnce({ ok: true, sha256: "write-sha-2" });
    const bridge = makeBridge({ workspaceFileWrite });

    const { saveBtn } = await openAndSave(bridge);
    expect(bridge.workspaceFileRead).toHaveBeenCalledTimes(1);
    expect(workspaceFileWrite).toHaveBeenNthCalledWith(1, "src/app/root.ts", "export {}\n", { baseSHA256: "sha-1" });

    // A second save (the user editing again after the first one landed) must use the WRITE's own
    // hash as its baseSHA256, proving the CAS baseline came from the write result and not a re-read.
    saveBtn.disabled = false;
    saveBtn.click();
    await vi.waitFor(() => expect(workspaceFileWrite).toHaveBeenCalledTimes(2));

    expect(workspaceFileWrite).toHaveBeenNthCalledWith(2, "src/app/root.ts", "export {}\n", { baseSHA256: "write-sha-1" });
    expect(bridge.workspaceFileRead).toHaveBeenCalledTimes(1);
  });
});

describe("EditorView — editorStateChanged push (round-5 hibernation fix)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
    capturedCodeViewOptions.current = undefined;
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("pushes immediately (not debounced) when a file opens", async () => {
    const result: WorkspaceFileReadResult = { content: "hello\n", sha256: "sha-1", size: 6 };
    const workspaceFileRead = vi.fn().mockResolvedValue(result);
    const notifyEditorStateChanged = vi.fn();
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge, { onStateChanged: notifyEditorStateChanged });

    view.open("a.ts");
    await vi.waitFor(() =>
      expect(notifyEditorStateChanged).toHaveBeenCalledWith({
        path: "a.ts",
        baseSHA256: "sha-1",
        baseContent: "hello\n",
        content: "hello\n",
        dirty: false,
        conflict: false,
      }),
    );
  });

  it("debounces the push on buffer edits, trailing ~500ms after the last edit", async () => {
    const result: WorkspaceFileReadResult = { content: "hello\n", sha256: "sha-1", size: 6 };
    const workspaceFileRead = vi.fn().mockResolvedValue(result);
    const notifyEditorStateChanged = vi.fn();
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge, { onStateChanged: notifyEditorStateChanged });

    view.open("a.ts");
    await vi.waitFor(() => expect(notifyEditorStateChanged).toHaveBeenCalledTimes(1)); // the open's immediate push
    notifyEditorStateChanged.mockClear();

    vi.useFakeTimers();
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "edited once" });
    expect(notifyEditorStateChanged).not.toHaveBeenCalled(); // debounced, not immediate

    vi.advanceTimersByTime(499);
    expect(notifyEditorStateChanged).not.toHaveBeenCalled();

    vi.advanceTimersByTime(1);
    expect(notifyEditorStateChanged).toHaveBeenCalledExactlyOnceWith({
      path: "a.ts",
      baseSHA256: "sha-1",
      baseContent: "hello\n",
      content: "edited once",
      dirty: true,
      conflict: false,
    });
  });

  it("pushes immediately (not debounced) when a save succeeds, with dirty back to false", async () => {
    const readResult: WorkspaceFileReadResult = { content: "hello\n", sha256: "sha-1", size: 6 };
    const workspaceFileRead = vi.fn().mockResolvedValue(readResult);
    const workspaceFileWrite = vi.fn().mockResolvedValue({ ok: true, sha256: "sha-2" });
    const notifyEditorStateChanged = vi.fn();
    const bridge = makeBridge({ workspaceFileRead, workspaceFileWrite });
    const view = new EditorView(container, bridge, { onStateChanged: notifyEditorStateChanged });

    view.open("a.ts");
    await vi.waitFor(() => expect(notifyEditorStateChanged).toHaveBeenCalledTimes(1));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "edited" });
    notifyEditorStateChanged.mockClear();

    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    saveBtn.disabled = false;
    saveBtn.click();
    await vi.waitFor(() =>
      expect(notifyEditorStateChanged).toHaveBeenCalledExactlyOnceWith({
        path: "a.ts",
        baseSHA256: "sha-2",
        baseContent: "edited",
        content: "edited",
        dirty: false,
        conflict: false,
      }),
    );
  });

  it("stays dirty when the user types again while the save is still in flight (round-7 Fix 1)", async () => {
    const readResult: WorkspaceFileReadResult = { content: "hello\n", sha256: "sha-1", size: 6 };
    const workspaceFileRead = vi.fn().mockResolvedValue(readResult);
    let resolveWrite: ((result: WorkspaceFileWriteResult) => void) | undefined;
    const workspaceFileWrite = vi.fn(() => new Promise<WorkspaceFileWriteResult>((resolve) => (resolveWrite = resolve)));
    const notifyEditorStateChanged = vi.fn();
    const bridge = makeBridge({ workspaceFileRead, workspaceFileWrite });
    const view = new EditorView(container, bridge, { onStateChanged: notifyEditorStateChanged });

    view.open("a.ts");
    await vi.waitFor(() => expect(notifyEditorStateChanged).toHaveBeenCalledTimes(1));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "edited" });
    notifyEditorStateChanged.mockClear();

    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    saveBtn.disabled = false;
    saveBtn.click();
    // The write is submitted with "edited" and is now in flight (held open by resolveWrite).
    await vi.waitFor(() => expect(workspaceFileWrite).toHaveBeenCalledWith("a.ts", "edited", { baseSHA256: "sha-1" }));

    // A keystroke lands before the write settles.
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "edited, then more" });

    resolveWrite!({ ok: true, sha256: "sha-2" });
    await vi.waitFor(() =>
      expect(notifyEditorStateChanged).toHaveBeenCalledExactlyOnceWith({
        path: "a.ts",
        baseSHA256: "sha-2", // the baseline adopted is the write's own hash, describing what IS on disk
        baseContent: "edited", // what was actually submitted/written
        content: "edited, then more", // the buffer the user is looking at, which disk does not hold
        dirty: true, // stays dirty: the buffer moved on past what this save actually wrote
        conflict: false,
      }),
    );
    expect(saveBtn.disabled).toBe(false);
  });
});

describe("EditorView — save() CAS conflict routes into external-change handling", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
    capturedCodeViewOptions.current = undefined;
  });

  /** Opens "a.ts" and edits its buffer to `edited`, leaving Save ready to click — same technique as
   *  the other describe blocks above. Each test supplies its own `workspaceFileRead` (its first
   *  resolution serves this open, its second serves `handleExternalChange`'s own fresh read after
   *  the save conflicts). */
  async function openAndEdit(bridge: SpacesBridge, edited: string): Promise<{ saveBtn: HTMLButtonElement }> {
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(bridge.workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: edited });

    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    return { saveBtn };
  }

  it("a save conflict that auto-merges cleanly (non-overlapping edits) shows the merge indicator, not the old changed-on-disk latch", async () => {
    const workspaceFileWrite = vi.fn().mockResolvedValue({ conflict: true, currentSHA256: "sha-remote" });
    // Base was "line1\nline2\n"; the buffer edits line1 only, while disk independently appends a
    // third line — non-overlapping, so diff3 auto-merges cleanly.
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "line1\nline2\n", sha256: "sha-1", size: 12 })
      .mockResolvedValueOnce({ content: "line1\nline2\nline3\n", sha256: "sha-remote", size: 18 });
    const bridge = makeBridge({ workspaceFileRead, workspaceFileWrite });
    const { saveBtn } = await openAndEdit(bridge, "line1 edited\nline2\n");

    saveBtn.click();
    await vi.waitFor(() => expect(workspaceFileWrite).toHaveBeenCalled());
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(2)); // handleExternalChange's own fresh read

    const merge = await vi.waitFor(() => {
      const el = container.querySelector(".banner.merge") as HTMLElement;
      expect(el.style.display).toBe("flex");
      return el;
    });
    expect(merge.textContent).toContain("Merged external changes");
    expect(container.querySelector(".banner.conflict")).toBeNull();
    expect(saveBtn.disabled).toBe(false); // still dirty against the new (disk) baseline
  });

  it("a save conflict with overlapping edits enters conflict state with a compare view, not the old latch text", async () => {
    const workspaceFileWrite = vi.fn().mockResolvedValue({ conflict: true, currentSHA256: "sha-remote" });
    // Both sides change the same single line differently — a genuine overlap.
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "hello\n", sha256: "sha-1", size: 6 })
      .mockResolvedValueOnce({ content: "goodbye\n", sha256: "sha-remote", size: 8 });
    const bridge = makeBridge({ workspaceFileRead, workspaceFileWrite });
    const { saveBtn } = await openAndEdit(bridge, "edited\n");

    saveBtn.click();
    await vi.waitFor(() => expect(workspaceFileWrite).toHaveBeenCalled());

    const conflictBanner = await vi.waitFor(() => {
      const el = container.querySelector(".banner.conflict") as HTMLElement;
      expect(el.style.display).toBe("flex");
      return el;
    });
    // Not the old permanent latch text — a factual "changed on disk" status plus resolution actions.
    expect(conflictBanner.textContent).not.toContain("save disabled");
    expect(conflictBanner.textContent).toContain("changed on disk");
    expect(conflictBanner.querySelector("button")!.textContent).toBe("Keep mine");
    expect([...conflictBanner.querySelectorAll("button")].map((b) => b.textContent)).toContain("Take disk");
    expect(saveBtn.disabled).toBe(true);
  });

  it("a save conflict where disk shows the file missing enters conflict state with deleted-on-disk wording", async () => {
    const workspaceFileWrite = vi.fn().mockResolvedValue({ conflict: true, fileMissing: true });
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "hello\n", sha256: "sha-1", size: 6 })
      .mockRejectedValueOnce(new SpacesBridgeError("notFound", "a.ts is gone"));
    const bridge = makeBridge({ workspaceFileRead, workspaceFileWrite });
    const { saveBtn } = await openAndEdit(bridge, "edited\n");

    saveBtn.click();
    await vi.waitFor(() => expect(workspaceFileWrite).toHaveBeenCalled());

    const conflictBanner = await vi.waitFor(() => {
      const el = container.querySelector(".banner.conflict") as HTMLElement;
      expect(el.style.display).toBe("flex");
      return el;
    });
    expect(conflictBanner.textContent).toContain("deleted on disk");
    expect(conflictBanner.querySelector("button")!.textContent).toBe("Keep mine");
    expect([...conflictBanner.querySelectorAll("button")].map((b) => b.textContent)).toContain("Close without saving");
    expect(saveBtn.disabled).toBe(true);
  });
});

describe("EditorView — restoreState (round-5 hibernation fix)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
  });

  // Round-3 codex Fix 2: a restored dirty buffer never replaces itself from disk (that part of
  // round-5's contract is unchanged — see the assertions on buffer/dirty state below), but it must
  // still fire `handleExternalChange` to reconcile against whatever happened on disk during
  // hibernation and re-arm the host's file-signature stream (only a `workspaceFileRead` re-arms it;
  // `subscribeToFileSignature` here is just a DOM listener).

  it("a dirty snapshot with disk unchanged issues a reconcile read but leaves the buffer, banner, and dirty state untouched", async () => {
    const workspaceFileRead = vi.fn().mockResolvedValue({ content: "original content", sha256: "sha-dirty", size: 16 });
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    await view.restoreState({
      path: "a.ts",
      baseSHA256: "sha-dirty",
      baseContent: "original content",
      content: "unsaved edits",
      dirty: true,
      conflict: false,
    });
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));

    expect(container.querySelector(".editor-path")!.textContent).toBe("a.ts");
    expect((container.querySelector("button.primary") as HTMLButtonElement).disabled).toBe(false);
    // Single shared `.banner` element (its class toggles between "conflict"/"merge"/"error" — see
    // editorView.ts) stays hidden either way; whichever selector currently matches its class must not
    // be showing.
    expect(container.querySelector(".banner.merge")).toBeNull();
    expect((container.querySelector(".banner.conflict") as HTMLElement).style.display).not.toBe("flex");
  });

  it("a dirty (non-conflict) snapshot with disk changed non-overlapping auto-merges, same as a live external-change event", async () => {
    // Base was "line1\nline2\n"; the restored buffer edited line1 only, while disk independently
    // appended a third line while the pane was hibernated — non-overlapping, so diff3 auto-merges.
    const workspaceFileRead = vi.fn().mockResolvedValue({ content: "line1\nline2\nline3\n", sha256: "sha-remote", size: 18 });
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    await view.restoreState({
      path: "a.ts",
      baseSHA256: "sha-1",
      baseContent: "line1\nline2\n",
      content: "line1 edited\nline2\n",
      dirty: true,
      conflict: false,
    });
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));

    const merge = await vi.waitFor(() => {
      const el = container.querySelector(".banner.merge") as HTMLElement;
      expect(el.style.display).toBe("flex");
      return el;
    });
    expect(merge.textContent).toContain("Merged external changes");
    expect(container.querySelector(".banner.conflict")).toBeNull();
    expect((container.querySelector("button.primary") as HTMLButtonElement).disabled).toBe(false); // still dirty against the new baseline
  });

  it("a restored conflict whose file is now deleted on disk updates the compare view to deleted-on-disk wording", async () => {
    const workspaceFileRead = vi.fn().mockRejectedValue(new SpacesBridgeError("notFound", "a.ts is gone"));
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    await view.restoreState({
      path: "a.ts",
      baseSHA256: "sha-1",
      baseContent: "hello\n",
      content: "edited\n",
      dirty: true,
      conflict: true,
    });
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));

    const conflictBanner = await vi.waitFor(() => {
      const el = container.querySelector(".banner.conflict") as HTMLElement;
      expect(el.style.display).toBe("flex");
      return el;
    });
    expect(conflictBanner.textContent).toContain("deleted on disk");
    expect([...conflictBanner.querySelectorAll("button")].map((b) => b.textContent)).toContain("Close without saving");
  });

  // round-16 Fix 1: the clean branch no longer routes through `open()` — it restores the snapshot
  // directly (same shape as the dirty branches) and reconciles via `handleExternalChange`, so these
  // three cases exercise `handleExternalChange`'s own decision instead of `open()`'s.

  it("a clean snapshot with disk changed reloads silently, adopting the fresh content as the new baseline", async () => {
    const result: WorkspaceFileReadResult = { content: "fresh from disk\n", sha256: "sha-fresh", size: 16 };
    const workspaceFileRead = vi.fn().mockResolvedValue(result);
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    await view.restoreState({
      path: "a.ts",
      baseSHA256: "sha-old",
      baseContent: "stale clean copy",
      content: "stale clean copy",
      dirty: false,
      conflict: false,
    });

    expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor");
    await vi.waitFor(() =>
      expect(view.collectStateForFlush()).toBe(
        JSON.stringify({
          path: "a.ts",
          baseSHA256: "sha-fresh",
          baseContent: "fresh from disk\n",
          content: "fresh from disk\n",
          dirty: false,
          conflict: false,
        }),
      ),
    );
    expect((container.querySelector("button.primary") as HTMLButtonElement).disabled).toBe(true);
  });

  it("a clean snapshot with disk unchanged shows the snapshot content, issues exactly one reconcile read, and pushes nothing", async () => {
    const workspaceFileRead = vi.fn().mockResolvedValue({ content: "unchanged\n", sha256: "sha-same", size: 10 });
    const notifyEditorStateChanged = vi.fn();
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge, { onStateChanged: notifyEditorStateChanged });

    await view.restoreState({
      path: "a.ts",
      baseSHA256: "sha-same",
      baseContent: "unchanged\n",
      content: "unchanged\n",
      dirty: false,
      conflict: false,
    });
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(1));
    await Promise.resolve();
    await Promise.resolve();

    expect(workspaceFileRead).toHaveBeenCalledTimes(1); // no retry, no double-read
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({
        path: "a.ts",
        baseSHA256: "sha-same",
        baseContent: "unchanged\n",
        content: "unchanged\n",
        dirty: false,
        conflict: false,
      }),
    );
    // Restoring the snapshot is a same-value echo of what the host already holds, and disk matching
    // the baseline short-circuits handleExternalChange before it would push anything — no push storm.
    expect(notifyEditorStateChanged).not.toHaveBeenCalled();
  });

  it("a clean snapshot whose file was deleted during hibernation shows the deleted placeholder, keeps the path in the box, and reloads once the file reappears (round-16 Fix 1)", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockRejectedValueOnce(new SpacesBridgeError("notFound", "a.ts is gone"))
      .mockResolvedValueOnce({ content: "back again\n", sha256: "sha-back", size: 11 });
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    await view.restoreState({
      path: "a.ts",
      baseSHA256: "sha-old",
      baseContent: "hello\n",
      content: "hello\n",
      dirty: false,
      conflict: false,
    });
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(1));

    // path stays in the box
    await vi.waitFor(() => expect(container.querySelector(".editor-path")!.textContent).toBe("a.ts"));
    expect(view.collectStateForFlush()).toBeNull(); // no open-file state left to persist
    expect((container.querySelector("button.primary") as HTMLButtonElement).disabled).toBe(true);
    expect((container.querySelector(".banner") as HTMLElement).style.display).toBe("none");

    // The file-signature subscription restoreState installed (not just a bare error from open())
    // is what catches the file reappearing: the next signature event drives the normal reload.
    fireFileSignature({ path: "a.ts", sha256: "sha-back", missing: false });
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(2));
    await vi.waitFor(() =>
      expect(view.collectStateForFlush()).toBe(
        JSON.stringify({
          path: "a.ts",
          baseSHA256: "sha-back",
          baseContent: "back again\n",
          content: "back again\n",
          dirty: false,
          conflict: false,
        }),
      ),
    );
  });

  it("no snapshot leaves the editor blank, same as a pane's first-ever load", async () => {
    const workspaceFileRead = vi.fn();
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    await view.restoreState(undefined);

    expect(workspaceFileRead).not.toHaveBeenCalled();
    const pathLabel = container.querySelector(".editor-path") as HTMLElement;
    expect(pathLabel.textContent).toBe("⌘P to open a file");
    expect(pathLabel.classList.contains("hint")).toBe(true);
  });
});

describe("EditorView — save() serialization (Fix 2)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
    capturedCodeViewOptions.current = undefined;
  });

  it("a second save() while one is still in flight submits no second write", async () => {
    const readResult: WorkspaceFileReadResult = { content: "hello\n", sha256: "sha-1", size: 6 };
    const workspaceFileRead = vi.fn().mockResolvedValue(readResult);
    let resolveWrite: ((result: WorkspaceFileWriteResult) => void) | undefined;
    const workspaceFileWrite = vi.fn(() => new Promise<WorkspaceFileWriteResult>((resolve) => (resolveWrite = resolve)));
    const bridge = makeBridge({ workspaceFileRead, workspaceFileWrite });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "edited" });

    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    saveBtn.disabled = false;
    // Two clicks back to back, same tab: `disabled` alone can't stop the second click's handler
    // from already having fired by the time the first save's synchronous prelude sets it, so this
    // exercises the `saveInFlight` guard itself rather than the disabled attribute.
    saveBtn.click();
    saveBtn.click();
    await vi.waitFor(() => expect(workspaceFileWrite).toHaveBeenCalled());

    resolveWrite!({ ok: true, sha256: "sha-2" });
    await vi.waitFor(() => expect(saveBtn.disabled).toBe(true)); // clean again: nothing typed since the save

    expect(workspaceFileWrite).toHaveBeenCalledTimes(1);
  });
});

describe("EditorView — open() latest-wins generation token (Fix 3)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
  });

  /** Builds a `workspaceFileRead` fake that hands back a per-path deferred promise, so a test can
   *  resolve/reject two overlapping `open()` calls in whichever order it wants to exercise. */
  function makeDeferredRead(): {
    workspaceFileRead: SpacesBridge["workspaceFileRead"];
    settle: Record<string, { resolve: (result: WorkspaceFileReadResult) => void; reject: (err: unknown) => void; promise: Promise<WorkspaceFileReadResult> }>;
  } {
    const settle: Record<string, { resolve: (result: WorkspaceFileReadResult) => void; reject: (err: unknown) => void; promise: Promise<WorkspaceFileReadResult> }> = {};
    const workspaceFileRead = vi.fn((path: string, _purpose: "editor") => {
      let resolve!: (result: WorkspaceFileReadResult) => void;
      let reject!: (err: unknown) => void;
      const promise = new Promise<WorkspaceFileReadResult>((res, rej) => {
        resolve = res;
        reject = rej;
      });
      settle[path] = { resolve, reject, promise };
      return promise;
    });
    return { workspaceFileRead, settle };
  }

  it("open(A) then open(B) before A resolves: resolving B then A leaves B's file open", async () => {
    const { workspaceFileRead, settle } = makeDeferredRead();
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);
    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    view.open("b.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("b.ts", "editor"));

    settle["b.ts"]!.resolve({ content: "b content", sha256: "sha-b", size: 9 });
    await settle["b.ts"]!.promise;
    settle["a.ts"]!.resolve({ content: "a content", sha256: "sha-a", size: 9 });
    await settle["a.ts"]!.promise;

    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({ path: "b.ts", baseSHA256: "sha-b", baseContent: "b content", content: "b content", dirty: false, conflict: false }),
    );
    expect(container.querySelector(".editor-path")!.textContent).toBe("b.ts");
  });

  it("A's rejection after B already won surfaces no error banner and leaves B's state untouched", async () => {
    const { workspaceFileRead, settle } = makeDeferredRead();
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);
    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    view.open("b.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("b.ts", "editor"));

    settle["b.ts"]!.resolve({ content: "b content", sha256: "sha-b", size: 9 });
    await settle["b.ts"]!.promise;

    // Settling A's own promise here (attached after open()'s internal await, which was attached
    // first) only resumes once open()'s catch block has already had its microtask turn — see this
    // block's use below for why that ordering is enough to prove the rejection was a no-op.
    settle["a.ts"]!.reject(new SpacesBridgeError("notFound", "a.ts is gone"));
    await settle["a.ts"]!.promise.catch(() => {});

    expect(container.querySelector(".banner.error")).toBeNull();
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({ path: "b.ts", baseSHA256: "sha-b", baseContent: "b content", content: "b content", dirty: false, conflict: false }),
    );
    expect(container.querySelector(".editor-path")!.textContent).toBe("b.ts");
  });
});

describe("EditorView — save() completion is generation-guarded against a later open() (Fix 5)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
    capturedCodeViewOptions.current = undefined;
  });

  /** Opens "a.ts", edits it, and clicks Save, leaving the write held open on `resolveWrite` — so a
   *  test can open "b.ts" (a real, non-deferred read) before settling A's write and observe whether
   *  A's completion clobbers the editor state that has since moved on to B. */
  async function openEditSaveA(bridge: SpacesBridge): Promise<{
    view: EditorView;
    saveBtn: HTMLButtonElement;
    resolveWrite: (result: WorkspaceFileWriteResult) => void;
    writePromise: Promise<WorkspaceFileWriteResult>;
  }> {
    (bridge.workspaceFileRead as ReturnType<typeof vi.fn>).mockImplementation((path: string) =>
      Promise.resolve(
        path === "a.ts"
          ? { content: "a content", sha256: "sha-a", size: 9 }
          : { content: "b content", sha256: "sha-b", size: 9 },
      ),
    );
    let resolveWrite!: (result: WorkspaceFileWriteResult) => void;
    const writePromise = new Promise<WorkspaceFileWriteResult>((resolve) => (resolveWrite = resolve));
    (bridge.workspaceFileWrite as ReturnType<typeof vi.fn>).mockReturnValue(writePromise);
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(bridge.workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "a content edited" });

    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    saveBtn.click();
    await vi.waitFor(() =>
      expect(bridge.workspaceFileWrite).toHaveBeenCalledWith("a.ts", "a content edited", { baseSHA256: "sha-a" }),
    );

    return { view, saveBtn, resolveWrite, writePromise };
  }

  it("a successful write for A resolving after open(B) leaves B's baseline, dirty state, and save button untouched", async () => {
    const bridge = makeBridge();
    const { view, saveBtn, resolveWrite, writePromise } = await openEditSaveA(bridge);

    // B is opened (and wins) while A's write is still in flight. A is still `dirty` (the save
    // hasn't resolved yet), so this goes through the discard gate (round-13 Fix 1) rather than
    // opening directly.
    view.open("b.ts");
    (container.querySelector(".banner.conflict button") as HTMLButtonElement).click();
    await vi.waitFor(() => expect(bridge.workspaceFileRead).toHaveBeenCalledWith("b.ts", "editor"));
    expect(container.querySelector(".editor-path")!.textContent).toBe("b.ts");
    expect(saveBtn.disabled).toBe(true); // open()'s post-open state for B: nothing edited yet

    // A's write now lands successfully. Awaiting the exact promise save() itself awaits guarantees
    // save()'s post-await continuation (including its generation check and `finally` cleanup) has
    // already run by the time this resolves: the continuation save() registered on this promise
    // (back when it awaited it, before it was settled) was attached first, so it fires before the
    // continuation this `await` registers now that the promise is already resolved.
    resolveWrite({ ok: true, sha256: "write-sha-a" });
    await writePromise;

    // If A's completion had clobbered state, baseSHA256 would read "write-sha-a" instead of B's own
    // "sha-b" — this is the assertion the whole fix is about.
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({ path: "b.ts", baseSHA256: "sha-b", baseContent: "b content", content: "b content", dirty: false, conflict: false }),
    );
    expect(saveBtn.disabled).toBe(true);
    expect((container.querySelector(".banner.conflict") as HTMLElement).style.display).toBe("none");
  });

  it("a conflicting write for A resolving after open(B) shows no conflict banner over B and leaves its save button untouched", async () => {
    const bridge = makeBridge();
    const { view, saveBtn, resolveWrite, writePromise } = await openEditSaveA(bridge);

    // A is still `dirty` (the save hasn't resolved yet), so this goes through the discard gate
    // (round-13 Fix 1) rather than opening directly.
    view.open("b.ts");
    (container.querySelector(".banner.conflict button") as HTMLButtonElement).click();
    await vi.waitFor(() => expect(bridge.workspaceFileRead).toHaveBeenCalledWith("b.ts", "editor"));
    expect(saveBtn.disabled).toBe(true);

    resolveWrite({ conflict: true, currentSHA256: "sha-remote" });
    await writePromise;

    // B's own state (not A's) is untouched by A's conflict: no banner, save button still reflects
    // B's post-open state, and the baseline/dirty snapshot is still B's, not marked conflicted.
    expect((container.querySelector(".banner.conflict") as HTMLElement).style.display).toBe("none");
    expect(saveBtn.disabled).toBe(true);
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({ path: "b.ts", baseSHA256: "sha-b", baseContent: "b content", content: "b content", dirty: false, conflict: false }),
    );
  });
});

describe("EditorView — save() completion is guarded against a concurrent external-change reconcile for the same file (Fix 2, round-2)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
    capturedCodeViewOptions.current = undefined;
  });

  it("an auto-merge reconcile completing while a save is in flight is untouched by the save's late success", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "line1\nline2\n", sha256: "sha-1", size: 12 }) // initial open
      .mockResolvedValueOnce({ content: "line1\nline2\nline3\n", sha256: "sha-2", size: 18 }); // handleExternalChange's own read
    let resolveWrite!: (result: WorkspaceFileWriteResult) => void;
    const writePromise = new Promise<WorkspaceFileWriteResult>((resolve) => (resolveWrite = resolve));
    const workspaceFileWrite = vi.fn().mockReturnValue(writePromise);
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead, workspaceFileWrite });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    // Mine: edits line1 only, so a later non-overlapping "theirs" appending line3 auto-merges cleanly.
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "line1 edited\nline2\n" });

    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    saveBtn.click();
    await vi.waitFor(() =>
      expect(workspaceFileWrite).toHaveBeenCalledWith("a.ts", "line1 edited\nline2\n", { baseSHA256: "sha-1" }),
    );

    // A live signature event for this same file races the in-flight save and runs the reconcile to
    // completion before the save's own write settles.
    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });
    const merge = await vi.waitFor(() => {
      const el = container.querySelector(".banner.merge") as HTMLElement;
      expect(el.style.display).toBe("flex");
      return el;
    });
    expect(merge.textContent).toContain("Merged external changes");
    expect(saveBtn.disabled).toBe(false); // the merge's own dirty buffer is savable again

    // The save's write for the OLD baseline (sha-1) now lands successfully, late.
    resolveWrite({ ok: true, sha256: "write-sha-a" });
    await writePromise;

    // If the save's late success had clobbered the reconcile, baseSHA256 would read "write-sha-a"
    // and the merge banner/pendingMergeUndo would be gone — this is the assertion the fix is about.
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({
        path: "a.ts",
        baseSHA256: "sha-2",
        baseContent: "line1\nline2\nline3\n",
        content: "line1 edited\nline2\nline3\n",
        dirty: true,
        conflict: false,
      }),
    );
    expect((container.querySelector(".banner.merge") as HTMLElement).style.display).toBe("flex");
    expect(merge.textContent).toContain("Merged external changes");
    expect(saveBtn.disabled).toBe(false);
  });

  it("a real-conflict reconcile completing while a save is in flight is untouched by the save's late success", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "hello\n", sha256: "sha-1", size: 6 })
      .mockResolvedValueOnce({ content: "goodbye\n", sha256: "sha-2", size: 8 });
    let resolveWrite!: (result: WorkspaceFileWriteResult) => void;
    const writePromise = new Promise<WorkspaceFileWriteResult>((resolve) => (resolveWrite = resolve));
    const workspaceFileWrite = vi.fn().mockReturnValue(writePromise);
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead, workspaceFileWrite });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "edited\n" });

    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    saveBtn.click();
    await vi.waitFor(() => expect(workspaceFileWrite).toHaveBeenCalledWith("a.ts", "edited\n", { baseSHA256: "sha-1" }));

    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });
    const conflictBanner = await vi.waitFor(() => {
      const el = container.querySelector(".banner.conflict") as HTMLElement;
      expect(el.style.display).toBe("flex");
      return el;
    });
    expect(conflictBanner.textContent).toContain("changed on disk");
    expect(saveBtn.disabled).toBe(true);

    resolveWrite({ ok: true, sha256: "write-sha-a" });
    await writePromise;

    expect((container.querySelector(".banner.conflict") as HTMLElement).style.display).toBe("flex");
    expect(conflictBanner.textContent).toContain("changed on disk");
    expect(saveBtn.disabled).toBe(true);
  });

  it("a reconcile's standing conflict banner is not overwritten by the save's own late failure banner", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "hello\n", sha256: "sha-1", size: 6 })
      .mockResolvedValueOnce({ content: "goodbye\n", sha256: "sha-2", size: 8 });
    let rejectWrite!: (err: unknown) => void;
    const writePromise = new Promise<WorkspaceFileWriteResult>((_resolve, reject) => (rejectWrite = reject));
    const workspaceFileWrite = vi.fn().mockReturnValue(writePromise);
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead, workspaceFileWrite });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "edited\n" });

    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    saveBtn.click();
    await vi.waitFor(() => expect(workspaceFileWrite).toHaveBeenCalledWith("a.ts", "edited\n", { baseSHA256: "sha-1" }));

    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });
    const conflictBanner = await vi.waitFor(() => {
      const el = container.querySelector(".banner.conflict") as HTMLElement;
      expect(el.style.display).toBe("flex");
      return el;
    });

    // Settling the rejection here (attached after save()'s own internal await, which was attached
    // first) only resumes once save()'s catch block has already had its microtask turn — same
    // technique the Fix 5 block above uses to prove a late arrival was a no-op.
    rejectWrite(new SpacesBridgeError("unavailable", "daemon offline"));
    await writePromise.catch(() => {});

    expect(conflictBanner.className).toBe("banner conflict");
    expect(conflictBanner.style.display).toBe("flex");
    expect(conflictBanner.textContent).toContain("changed on disk");
    expect(saveBtn.disabled).toBe(true);
  });
});

describe("EditorView — opening another file while dirty is gated (round-13 Fix 1)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
    capturedCodeViewOptions.current = undefined;
  });

  function makePerPathBridge(): { bridge: SpacesBridge; workspaceFileRead: ReturnType<typeof vi.fn>; workspaceFileWrite: ReturnType<typeof vi.fn> } {
    const workspaceFileRead = vi.fn((path: string) =>
      Promise.resolve({ content: `${path} content`, sha256: `sha-${path}`, size: 9 }),
    );
    const workspaceFileWrite = vi.fn().mockResolvedValue({ ok: true, sha256: "sha-written" });
    const bridge = makeBridge({ workspaceFileRead, workspaceFileWrite });
    return { bridge, workspaceFileRead, workspaceFileWrite };
  }

  /** Opens `path` and marks it edited via the captured fake CodeView's `onItemEditChange`, leaving
   *  `dirty` true — same technique as the other describe blocks above that bypass the real editor. */
  async function openAndEdit(view: EditorView, bridge: SpacesBridge, path: string): Promise<void> {
    view.open(path);
    await vi.waitFor(() => expect(bridge.workspaceFileRead).toHaveBeenCalledWith(path, "editor"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: `${path} content edited` });
  }

  it("opening a new path while dirty does not open it, and shows the discard banner", async () => {
    const { bridge, workspaceFileRead } = makePerPathBridge();
    const view = new EditorView(container, bridge);
    await openAndEdit(view, bridge, "a.ts");
    workspaceFileRead.mockClear();

    view.open("b.ts");

    expect(workspaceFileRead).not.toHaveBeenCalledWith("b.ts", "editor");
    const banner = container.querySelector(".banner.conflict") as HTMLElement;
    expect(banner).not.toBeNull();
    expect(banner.style.display).toBe("flex");
    expect(banner.firstChild?.textContent).toBe("Unsaved changes in a.ts. Save them first, or discard them to open b.ts.");
    expect(banner.querySelector("button")!.textContent).toBe("Discard edits and open");
  });

  // Formerly "a search-suggestion click while dirty is gated the same way as Return": the old
  // top-bar search dropdown's suggestion-row click ultimately called the same private open method
  // this `open()` is now the sole public front door for (⌘P quick-open, the Files tree, and the
  // Changes list all call it too — see editorView.ts's class doc comment). There is no separate
  // suggestion-click code path left to distinguish from a direct `open()` call, so this instead
  // proves the gate holds across repeated calls while still dirty, re-targeting the banner to
  // whichever path was most recently requested — a property the single "Return" test above (one
  // gated call) doesn't cover.
  it("a second open() call while still dirty is gated identically, and the banner re-targets to the newer path", async () => {
    const { bridge, workspaceFileRead } = makePerPathBridge();
    const view = new EditorView(container, bridge);
    await openAndEdit(view, bridge, "a.ts");
    workspaceFileRead.mockClear();

    view.open("b.ts");
    expect(workspaceFileRead).not.toHaveBeenCalledWith("b.ts", "editor");

    view.open("c.ts");
    expect(workspaceFileRead).not.toHaveBeenCalledWith("c.ts", "editor");
    const banner = container.querySelector(".banner.conflict") as HTMLElement;
    expect(banner.style.display).toBe("flex");
    expect(banner.textContent).toContain("discard them to open c.ts");
  });

  it("clicking the discard action opens the requested file and clears dirty", async () => {
    const { bridge, workspaceFileRead } = makePerPathBridge();
    const view = new EditorView(container, bridge);
    await openAndEdit(view, bridge, "a.ts");

    view.open("b.ts");
    const banner = container.querySelector(".banner.conflict") as HTMLElement;
    const discardBtn = banner.querySelector("button") as HTMLButtonElement;
    discardBtn.click();

    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("b.ts", "editor"));
    expect(container.querySelector(".editor-path")!.textContent).toBe("b.ts");
    expect(banner.style.display).toBe("none"); // open()'s success path hides the banner
    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    expect(saveBtn.disabled).toBe(true); // dirty cleared, nothing edited in b.ts yet
  });

  it("saving first, then opening a different path, opens it directly with no gate", async () => {
    const { bridge, workspaceFileRead, workspaceFileWrite } = makePerPathBridge();
    const view = new EditorView(container, bridge);
    await openAndEdit(view, bridge, "a.ts");

    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    saveBtn.click();
    await vi.waitFor(() => expect(workspaceFileWrite).toHaveBeenCalled());
    // The save clears dirty, so the gate no longer applies.
    workspaceFileRead.mockClear();

    view.open("b.ts");

    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("b.ts", "editor"));
    expect(container.querySelector(".editor-path")!.textContent).toBe("b.ts");
    expect(container.querySelector(".banner.conflict")?.textContent ?? "").not.toContain("Unsaved changes");
  });

  it("typing into a just-restored clean buffer while its reconcile read is in flight is merged, never silently discarded (round-16 Fix 1, reworked from round-15 Fix A)", async () => {
    // round-16 Fix 1: restoreState's clean branch no longer routes through open(), so the
    // protection round-15 Fix A proved (open()'s completion-time dirty recheck) no longer applies —
    // there is no open() call in this path any more. The equivalent, still-real protection now lives
    // in handleExternalChange's own dirty check at completion: restoreState's synchronous restore
    // makes the buffer live (loadIntoCodeView wires up onItemEditChange) before its fire-and-forget
    // reconcile read resolves, so a keystroke landing in that window must route to diff3/conflict,
    // never be silently clobbered by whatever the read comes back with. This proves that property
    // through the new path instead of the old one.
    let resolveRead!: (result: WorkspaceFileReadResult) => void;
    const workspaceFileRead = vi.fn(
      () => new Promise<WorkspaceFileReadResult>((resolve) => { resolveRead = resolve; }),
    );
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    await view.restoreState({
      path: "a.ts",
      baseSHA256: "sha-1",
      baseContent: "line1\nline2\n",
      content: "line1\nline2\n",
      dirty: false,
      conflict: false,
    });
    expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"); // reconcile read already started

    // The user types into the now-live restored buffer while that read is still in flight.
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "line1 edited\nline2\n" });

    // Disk independently changed too (appended line3) — non-overlapping with the user's edit.
    resolveRead({ content: "line1\nline2\nline3\n", sha256: "sha-remote", size: 18 });

    const merge = await vi.waitFor(() => {
      const el = container.querySelector(".banner.merge") as HTMLElement;
      expect(el.style.display).toBe("flex");
      return el;
    });
    expect(merge.textContent).toContain("Merged external changes");
    // The user's typed edit survived the merge — it was never silently discarded by the read that
    // was in flight when the keystroke landed.
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({
        path: "a.ts",
        baseSHA256: "sha-remote",
        baseContent: "line1\nline2\nline3\n",
        content: "line1 edited\nline2\nline3\n",
        dirty: true,
        conflict: false,
      }),
    );
  });
});

describe("EditorView — reopening the currently-open file while dirty is a no-op (Finding 2)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
    capturedCodeViewOptions.current = undefined;
  });

  function makePerPathBridge(): { bridge: SpacesBridge; workspaceFileRead: ReturnType<typeof vi.fn> } {
    const workspaceFileRead = vi.fn((path: string) =>
      Promise.resolve({ content: `${path} content`, sha256: `sha-${path}`, size: 9 }),
    );
    const bridge = makeBridge({ workspaceFileRead });
    return { bridge, workspaceFileRead };
  }

  async function openAndEdit(view: EditorView, bridge: SpacesBridge, path: string): Promise<void> {
    view.open(path);
    await vi.waitFor(() => expect(bridge.workspaceFileRead).toHaveBeenCalledWith(path, "editor"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: `${path} content edited` });
  }

  it("re-picking the same dirty file does not raise the discard banner, does not re-read, and leaves the edit intact", async () => {
    const { bridge, workspaceFileRead } = makePerPathBridge();
    const onFileOpened = vi.fn();
    const view = new EditorView(container, bridge, { onFileOpened });
    await openAndEdit(view, bridge, "a.ts");
    workspaceFileRead.mockClear();
    onFileOpened.mockClear(); // drop the initial open's own call

    view.open("a.ts");

    expect(workspaceFileRead).not.toHaveBeenCalled(); // no re-read of the file already open
    // The banner element persists in the DOM (reused, not recreated) but must stay hidden — no
    // discard-consent banner is raised for this reopen.
    expect((container.querySelector(".banner.conflict") as HTMLElement | null)?.style.display ?? "none").toBe("none");
    expect(onFileOpened).not.toHaveBeenCalled(); // this isn't a new open — nothing to record
    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    expect(saveBtn.disabled).toBe(false); // the edit is still there, unsaved
  });

  it("re-picking a DIFFERENT file while dirty still raises the discard banner (unchanged by this fix)", async () => {
    const { bridge, workspaceFileRead } = makePerPathBridge();
    const view = new EditorView(container, bridge);
    await openAndEdit(view, bridge, "a.ts");
    workspaceFileRead.mockClear();

    view.open("b.ts");

    expect(workspaceFileRead).not.toHaveBeenCalledWith("b.ts", "editor");
    const banner = container.querySelector(".banner.conflict") as HTMLElement;
    expect(banner.style.display).toBe("flex");
    expect(banner.querySelector("button")!.textContent).toBe("Discard edits and open");
  });

  it("re-picking the same file mid-conflict also just stays put, leaving the conflict banner and its Keep-mine/Take-disk actions untouched", async () => {
    // `dirty` stays true throughout a standing conflict (see `open()`'s doc comment), so the same
    // path === currentPath early return must hold here too, rather than the conflict's own dirty
    // buffer falling through into the ordinary discard-consent gate.
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "hello\n", sha256: "sha-1", size: 6 })
      .mockResolvedValueOnce({ content: "goodbye\n", sha256: "sha-2", size: 8 });
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "edited\n" });
    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });

    const conflictBanner = await vi.waitFor(() => {
      const el = container.querySelector(".banner.conflict") as HTMLElement;
      expect(el.style.display).toBe("flex");
      return el;
    });
    expect(conflictBanner.textContent).toContain("changed on disk");
    workspaceFileRead.mockClear();

    view.open("a.ts"); // re-picking the file already open, mid-conflict

    expect(workspaceFileRead).not.toHaveBeenCalled(); // no re-read triggered
    // Still the conflict banner (Keep mine / Take disk), not replaced by the discard-consent banner.
    expect(conflictBanner.style.display).toBe("flex");
    expect(conflictBanner.textContent).toContain("changed on disk");
    expect([...conflictBanner.querySelectorAll("button")].map((b) => b.textContent)).toEqual(["Keep mine", "Take disk"]);
  });
});

describe("EditorView — completion recheck + discard-flag interplay (round-15 Fix A+B)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
    capturedCodeViewOptions.current = undefined;
  });

  /** Same held-per-path-read idiom as the "open() latest-wins generation token" block above: each
   *  call to `workspaceFileRead(path)` gets its own deferred promise, tracked by path (a later call
   *  for the same path overwrites the earlier entry, which is fine here since every test only needs
   *  to hold the LATEST in-flight read for a given path). */
  function makeDeferredRead(): {
    workspaceFileRead: SpacesBridge["workspaceFileRead"];
    settle: Record<string, { resolve: (result: WorkspaceFileReadResult) => void; reject: (err: unknown) => void; promise: Promise<WorkspaceFileReadResult> }>;
  } {
    const settle: Record<string, { resolve: (result: WorkspaceFileReadResult) => void; reject: (err: unknown) => void; promise: Promise<WorkspaceFileReadResult> }> = {};
    const workspaceFileRead = vi.fn((path: string, _purpose: "editor") => {
      let resolve!: (result: WorkspaceFileReadResult) => void;
      let reject!: (err: unknown) => void;
      const promise = new Promise<WorkspaceFileReadResult>((res, rej) => {
        resolve = res;
        reject = rej;
      });
      settle[path] = { resolve, reject, promise };
      return promise;
    });
    return { workspaceFileRead, settle };
  }

  it("Bug A: the current buffer going dirty WHILE a different open's read is in flight raises the banner at completion instead of clobbering it", async () => {
    const { workspaceFileRead, settle } = makeDeferredRead();
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    // Open A cleanly.
    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    settle["a.ts"]!.resolve({ content: "a content", sha256: "sha-a", size: 9 });
    await settle["a.ts"]!.promise;

    // A is clean, so open()'s upfront dirty check lets B's open proceed directly — no banner yet.
    view.open("b.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("b.ts", "editor"));
    expect((container.querySelector(".banner.conflict") as HTMLElement).style.display).toBe("none");

    // While B's read is in flight, the user types into A (still the loaded buffer — B hasn't
    // landed). open()'s upfront dirty check ran before this happened, so only open()'s completion-time
    // recheck can catch it.
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "a content edited" });

    settle["b.ts"]!.resolve({ content: "b content", sha256: "sha-b", size: 9 });
    await settle["b.ts"]!.promise;

    // A's buffer must be untouched: the completion recheck refused to replace it and raised the
    // discard banner for B instead of silently clobbering A's in-progress edit.
    const banner = await vi.waitFor(() => {
      const el = container.querySelector(".banner.conflict") as HTMLElement;
      expect(el.style.display).toBe("flex");
      return el;
    });
    expect(banner.firstChild?.textContent).toBe("Unsaved changes in a.ts. Save them first, or discard them to open b.ts.");
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({ path: "a.ts", baseSHA256: "sha-a", baseContent: "a content", content: "a content edited", dirty: true, conflict: false }),
    );

    // Clicking discard commits it: a fresh read for B (the earlier one already resolved and was
    // discarded by the recheck above), landing with `discard: true` so this completion isn't
    // re-litigated as its own conflict.
    (banner.querySelector("button") as HTMLButtonElement).click();
    // a.ts, b.ts, a.ts (round-13 fix: the refused-open reconcile fired when the recheck above raised
    // the banner, for the still-current a.ts — left unresolved here, it never blocks this test), b.ts
    // again.
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(4));
    settle["b.ts"]!.resolve({ content: "b content v2", sha256: "sha-b2", size: 12 });
    await settle["b.ts"]!.promise;

    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({
        path: "b.ts",
        baseSHA256: "sha-b2",
        baseContent: "b content v2",
        content: "b content v2",
        dirty: false,
        conflict: false,
      }),
    );
    expect((container.querySelector("button.primary") as HTMLButtonElement).disabled).toBe(true);
    expect(banner.style.display).toBe("none");
  });

  it("Bug B (success): clicking discard does not touch the old buffer until the reopen actually succeeds", async () => {
    const { workspaceFileRead, settle } = makeDeferredRead();
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);
    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    settle["a.ts"]!.resolve({ content: "a content", sha256: "sha-a", size: 9 });
    await settle["a.ts"]!.promise;
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "a content edited" });

    view.open("b.ts"); // dirty: gated, banner shown, no read yet
    const banner = container.querySelector(".banner.conflict") as HTMLElement;
    expect(banner.style.display).toBe("flex");
    (banner.querySelector("button") as HTMLButtonElement).click(); // discard: read for b.ts starts, held
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("b.ts", "editor"));

    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    // While the reopen is held, nothing about A's buffer has moved: the discard is committed only
    // once open() actually succeeds, not at click time.
    expect(saveBtn.disabled).toBe(false);
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({ path: "a.ts", baseSHA256: "sha-a", baseContent: "a content", content: "a content edited", dirty: true, conflict: false }),
    );

    settle["b.ts"]!.resolve({ content: "b content", sha256: "sha-b", size: 9 });
    await settle["b.ts"]!.promise;

    expect(container.querySelector(".editor-path")!.textContent).toBe("b.ts");
    expect(saveBtn.disabled).toBe(true);
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({ path: "b.ts", baseSHA256: "sha-b", baseContent: "b content", content: "b content", dirty: false, conflict: false }),
    );
  });

  it("Bug B (failure): a reopen that fails after discard leaves the old buffer dirty and Save enabled, not silently marked clean", async () => {
    const { workspaceFileRead, settle } = makeDeferredRead();
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);
    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    settle["a.ts"]!.resolve({ content: "a content", sha256: "sha-a", size: 9 });
    await settle["a.ts"]!.promise;
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "a content edited" });

    view.open("b.ts");
    const banner = container.querySelector(".banner.conflict") as HTMLElement;
    (banner.querySelector("button") as HTMLButtonElement).click();
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("b.ts", "editor"));

    settle["b.ts"]!.reject(new SpacesBridgeError("notFound", "no such file: b.ts"));
    await settle["b.ts"]!.promise.catch(() => {});

    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    // Nothing was silently marked clean by the failed discard attempt: A's path, content, baseline,
    // and dirty flag are exactly what they were before the click, and Save is still enabled.
    expect(saveBtn.disabled).toBe(false);
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({ path: "a.ts", baseSHA256: "sha-a", baseContent: "a content", content: "a content edited", dirty: true, conflict: false }),
    );
    // The failed reopen renders its own factual error, same as any other failed open().
    expect(container.querySelector(".banner.error")).not.toBeNull();
  });
});

describe("EditorView — discard consent is scoped to the edit-generation at click time (against-main round-3 fix)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
    capturedCodeViewOptions.current = undefined;
  });

  /** Same held-per-path-read idiom as the "completion recheck + discard-flag interplay" block above:
   *  each call to `workspaceFileRead(path)` gets its own deferred promise, tracked by path (a later
   *  call for the same path overwrites the earlier entry — every test here only needs to hold the
   *  LATEST in-flight read for a given path, since a re-raised banner's second discard click issues
   *  a brand new read for the same target path). */
  function makeDeferredRead(): {
    workspaceFileRead: SpacesBridge["workspaceFileRead"];
    settle: Record<string, { resolve: (result: WorkspaceFileReadResult) => void; reject: (err: unknown) => void; promise: Promise<WorkspaceFileReadResult> }>;
  } {
    const settle: Record<string, { resolve: (result: WorkspaceFileReadResult) => void; reject: (err: unknown) => void; promise: Promise<WorkspaceFileReadResult> }> = {};
    const workspaceFileRead = vi.fn((path: string) => {
      let resolve!: (result: WorkspaceFileReadResult) => void;
      let reject!: (err: unknown) => void;
      const promise = new Promise<WorkspaceFileReadResult>((res, rej) => {
        resolve = res;
        reject = rej;
      });
      settle[path] = { resolve, reject, promise };
      return promise;
    });
    return { workspaceFileRead, settle };
  }

  it("an edit landing after the discard click but before its read completes re-raises the banner instead of silently discarding it", async () => {
    const { workspaceFileRead, settle } = makeDeferredRead();
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);
    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    settle["a.ts"]!.resolve({ content: "a content", sha256: "sha-a", size: 9 });
    await settle["a.ts"]!.promise;
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "a content edited" });

    view.open("b.ts"); // dirty: gated, banner shown, no read yet
    const banner = container.querySelector(".banner.conflict") as HTMLElement;
    (banner.querySelector("button") as HTMLButtonElement).click(); // discard consent captured at THIS click's bufferEditGeneration
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("b.ts", "editor"));

    // A further keystroke lands into the still-live A buffer while B's read is still held — this is
    // new unsaved work the click's consent never covered.
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "a content edited further" });

    settle["b.ts"]!.resolve({ content: "b content", sha256: "sha-b", size: 9 });
    await settle["b.ts"]!.promise;

    // The banner re-raises: the intervening edit invalidated this discard's consent.
    await vi.waitFor(() => expect(banner.style.display).toBe("flex"));
    expect(banner.firstChild?.textContent).toBe("Unsaved changes in a.ts. Save them first, or discard them to open b.ts.");

    // The buffer was NOT replaced with B's content: A's post-intervening-edit buffer still stands,
    // still dirty, still the open file.
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({ path: "a.ts", baseSHA256: "sha-a", baseContent: "a content", content: "a content edited further", dirty: true, conflict: false }),
    );
    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    expect(saveBtn.disabled).toBe(false);
  });

  it("clicking discard a second time with no further edits lets the reopen complete normally (no infinite re-raise)", async () => {
    const { workspaceFileRead, settle } = makeDeferredRead();
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);
    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    settle["a.ts"]!.resolve({ content: "a content", sha256: "sha-a", size: 9 });
    await settle["a.ts"]!.promise;
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "a content edited" });

    view.open("b.ts");
    const banner = container.querySelector(".banner.conflict") as HTMLElement;
    (banner.querySelector("button") as HTMLButtonElement).click(); // first discard click, consent gen 1
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("b.ts", "editor"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "a content edited further" }); // intervening edit bumps to gen 2
    settle["b.ts"]!.resolve({ content: "b content", sha256: "sha-b", size: 9 });
    await settle["b.ts"]!.promise;
    await vi.waitFor(() => expect(banner.style.display).toBe("flex")); // re-raised, same as the previous test

    // Second discard click: no further edit happens this time, so this click's consent generation
    // still matches `bufferEditGeneration` when the reopen completes.
    (banner.querySelector("button") as HTMLButtonElement).click();
    // a.ts, b.ts, a.ts (round-13 fix: the refused-open reconcile fired when the re-raise above ran,
    // for the still-current a.ts — left unresolved here, it never blocks this test), b.ts again.
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(4));
    settle["b.ts"]!.resolve({ content: "b content v2", sha256: "sha-b2", size: 12 });
    await settle["b.ts"]!.promise;

    // B opens normally this time: the fix does not cause an infinite re-raise loop once there is no
    // new edit to re-litigate.
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({ path: "b.ts", baseSHA256: "sha-b2", baseContent: "b content v2", content: "b content v2", dirty: false, conflict: false }),
    );
    expect(container.querySelector(".editor-path")!.textContent).toBe("b.ts");
    expect((container.querySelector("button.primary") as HTMLButtonElement).disabled).toBe(true);
    expect(banner.style.display).toBe("none");
  });

  it("a discard with no intervening edit opens the target file normally, unchanged from before this fix", async () => {
    const { workspaceFileRead, settle } = makeDeferredRead();
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);
    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    settle["a.ts"]!.resolve({ content: "a content", sha256: "sha-a", size: 9 });
    await settle["a.ts"]!.promise;
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "a content edited" });

    view.open("b.ts");
    const banner = container.querySelector(".banner.conflict") as HTMLElement;
    (banner.querySelector("button") as HTMLButtonElement).click();
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("b.ts", "editor"));

    // No edit happens while the read is held this time — the original, unraced discard shape.
    settle["b.ts"]!.resolve({ content: "b content", sha256: "sha-b", size: 9 });
    await settle["b.ts"]!.promise;

    expect(container.querySelector(".editor-path")!.textContent).toBe("b.ts");
    expect(banner.style.display).toBe("none");
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({ path: "b.ts", baseSHA256: "sha-b", baseContent: "b content", content: "b content", dirty: false, conflict: false }),
    );
    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    expect(saveBtn.disabled).toBe(true);
  });
});

describe("EditorView.collectStateForFlush (round-6 Fix 1)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("returns null when no file is open", () => {
    const bridge = makeBridge();
    const view = new EditorView(container, bridge);

    expect(view.collectStateForFlush()).toBeNull();
  });

  it("returns the latest buffer even while a debounced push is still pending", async () => {
    const result: WorkspaceFileReadResult = { content: "hello\n", sha256: "sha-1", size: 6 };
    const workspaceFileRead = vi.fn().mockResolvedValue(result);
    const notifyEditorStateChanged = vi.fn();
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge, { onStateChanged: notifyEditorStateChanged });

    view.open("a.ts");
    await vi.waitFor(() => expect(notifyEditorStateChanged).toHaveBeenCalledTimes(1));
    notifyEditorStateChanged.mockClear();

    vi.useFakeTimers();
    // A buffer edit inside the ~500ms debounce window: nothing has been pushed
    // to notifyEditorStateChanged yet, but the synchronous flush pull must see it anyway.
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "edited, not yet pushed" });
    expect(notifyEditorStateChanged).not.toHaveBeenCalled();

    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({
        path: "a.ts",
        baseSHA256: "sha-1",
        baseContent: "hello\n",
        content: "edited, not yet pushed",
        dirty: true,
        conflict: false,
      }),
    );
  });
});

describe("EditorView — external-change handling: clean buffer (silent reload / deletion placeholder)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
  });

  it("a clean buffer whose disk content changed reloads silently, with no banner, adopting the new baseline", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "hello\n", sha256: "sha-1", size: 6 })
      .mockResolvedValueOnce({ content: "hello, updated\n", sha256: "sha-2", size: 15 });
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));

    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(2));

    await vi.waitFor(() =>
      expect(view.collectStateForFlush()).toBe(
        JSON.stringify({
          path: "a.ts",
          baseSHA256: "sha-2",
          baseContent: "hello, updated\n",
          content: "hello, updated\n",
          dirty: false,
          conflict: false,
        }),
      ),
    );
    // The shared banner element keeps whatever modifier class ("conflict"/"merge"/"error") it last
    // carried — nothing here resets it, matching the rest of this file's convention (e.g. the
    // discard-banner tests above) of asserting hidden-ness via `style.display`, not via class
    // absence, since the class itself is not the product-visible signal.
    expect((container.querySelector(".banner") as HTMLElement).style.display).toBe("none");
  });

  it("a stray file-signature event whose hash already matches the baseline is a no-op", async () => {
    const workspaceFileRead = vi.fn().mockResolvedValue({ content: "hello\n", sha256: "sha-1", size: 6 });
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));

    fireFileSignature({ path: "a.ts", sha256: "sha-1", missing: false });
    await Promise.resolve();
    await Promise.resolve();

    // `handleExternalChange` always does a fresh read (a `FileSignatureEvent` carries no content,
    // just a hash to go check — see its doc comment), so this is 2 calls, not 1: the "no-op" is
    // about state (no reload, no banner), not about skipping the read.
    expect(workspaceFileRead).toHaveBeenCalledTimes(2);
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({
        path: "a.ts",
        baseSHA256: "sha-1",
        baseContent: "hello\n",
        content: "hello\n",
        dirty: false,
        conflict: false,
      }),
    );
  });

  it("a clean buffer whose file was deleted on disk shows the deleted placeholder, clears the open-file state, and keeps the path in the box", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "hello\n", sha256: "sha-1", size: 6 })
      .mockRejectedValueOnce(new SpacesBridgeError("notFound", "a.ts is gone"));
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);
    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));

    fireFileSignature({ path: "a.ts", sha256: undefined, missing: true });
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(2));

    await vi.waitFor(() => expect(container.querySelector(".editor-path")!.textContent).toBe("a.ts")); // path stays in the box
    expect(view.collectStateForFlush()).toBeNull(); // no open-file state left to persist
    expect((container.querySelector("button.primary") as HTMLButtonElement).disabled).toBe(true);
    // See the previous test's comment: hidden-ness is asserted via `style.display`, not class
    // absence — the shared banner element's last modifier class is not reset here.
    expect((container.querySelector(".banner") as HTMLElement).style.display).toBe("none");
  });
});

describe("EditorView — external-change handling: dirty buffer, auto-merge + Undo", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
    capturedCodeViewOptions.current = undefined;
  });

  it("non-overlapping edits auto-merge, show the dismissible merge indicator, and stay dirty against the new baseline", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "line1\nline2\n", sha256: "sha-1", size: 12 })
      .mockResolvedValueOnce({ content: "line1\nline2\nline3\n", sha256: "sha-2", size: 18 });
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    // Mine: edits line1 only. Theirs: appends line3 only. Non-overlapping.
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "line1 edited\nline2\n" });

    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(2));

    const merge = await vi.waitFor(() => {
      const el = container.querySelector(".banner.merge") as HTMLElement;
      expect(el.style.display).toBe("flex");
      return el;
    });
    expect(merge.textContent).toContain("Merged external changes");
    const buttonLabels = [...merge.querySelectorAll("button")].map((b) => b.textContent);
    expect(buttonLabels).toEqual(["Undo", "Dismiss"]);

    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({
        path: "a.ts",
        baseSHA256: "sha-2",
        baseContent: "line1\nline2\nline3\n",
        content: "line1 edited\nline2\nline3\n",
        dirty: true,
        conflict: false,
      }),
    );
    expect(container.querySelector(".banner.conflict")).toBeNull();
  });

  it("Dismiss on the merge indicator just hides it, leaving the merged buffer standing", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "line1\nline2\n", sha256: "sha-1", size: 12 })
      .mockResolvedValueOnce({ content: "line1\nline2\nline3\n", sha256: "sha-2", size: 18 });
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "line1 edited\nline2\n" });
    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });

    const merge = await vi.waitFor(() => {
      const el = container.querySelector(".banner.merge") as HTMLElement;
      expect(el.style.display).toBe("flex");
      return el;
    });
    const dismissBtn = [...merge.querySelectorAll("button")].find((b) => b.textContent === "Dismiss")!;
    dismissBtn.click();

    expect(merge.style.display).toBe("none");
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({
        path: "a.ts",
        baseSHA256: "sha-2",
        baseContent: "line1\nline2\nline3\n",
        content: "line1 edited\nline2\nline3\n",
        dirty: true,
        conflict: false,
      }),
    );
  });

  it("Undo reverts the buffer to its pre-merge content and enters conflict state against the same disk snapshot, with no re-read", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "line1\nline2\n", sha256: "sha-1", size: 12 })
      .mockResolvedValueOnce({ content: "line1\nline2\nline3\n", sha256: "sha-2", size: 18 });
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "line1 edited\nline2\n" });
    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });

    const merge = await vi.waitFor(() => {
      const el = container.querySelector(".banner.merge") as HTMLElement;
      expect(el.style.display).toBe("flex");
      return el;
    });
    const undoBtn = [...merge.querySelectorAll("button")].find((b) => b.textContent === "Undo")!;
    undoBtn.click();

    expect(workspaceFileRead).toHaveBeenCalledTimes(2); // Undo did not trigger a third read
    const conflictBanner = container.querySelector(".banner.conflict") as HTMLElement;
    expect(conflictBanner.style.display).toBe("flex");
    expect(conflictBanner.textContent).toContain("changed on disk");
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({
        path: "a.ts",
        baseSHA256: "sha-2",
        baseContent: "line1\nline2\nline3\n",
        content: "line1 edited\nline2\n", // reverted to the pre-merge buffer
        dirty: true,
        conflict: true,
      }),
    );
    expect((container.querySelector("button.primary") as HTMLButtonElement).disabled).toBe(true);
  });

  it("a further edit after a merge retires the Undo offer instead of leaving it live", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "line1\nline2\n", sha256: "sha-1", size: 12 })
      .mockResolvedValueOnce({ content: "line1\nline2\nline3\n", sha256: "sha-2", size: 18 });
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "line1 edited\nline2\n" });
    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });

    await vi.waitFor(() => expect((container.querySelector(".banner.merge") as HTMLElement).style.display).toBe("flex"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "line1 edited\nline2\nmore\n" });

    expect((container.querySelector(".banner.merge") as HTMLElement).style.display).toBe("none");
  });
});

describe("EditorView — failed/refused-open reconcile (round-13 fix)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
    capturedCodeViewOptions.current = undefined;
  });

  /** Index-ordered deferred reads, not keyed by path: unlike the round-15 block's `makeDeferredRead`
   *  (which keys by path and so can only ever hold the LATEST call for a given path), these tests need
   *  to hold two separate in-flight reads for the SAME path ("a.ts") at once — the live reconcile
   *  triggered by a signature push, and the fix's own reconcile fired from a later failed/refused open
   *  of a different path. Indexing by call order keeps both addressable independently. */
  function makeIndexedDeferredRead(): {
    workspaceFileRead: SpacesBridge["workspaceFileRead"];
    calls: { path: string; resolve: (result: WorkspaceFileReadResult) => void; reject: (err: unknown) => void; promise: Promise<WorkspaceFileReadResult> }[];
  } {
    const calls: { path: string; resolve: (result: WorkspaceFileReadResult) => void; reject: (err: unknown) => void; promise: Promise<WorkspaceFileReadResult> }[] = [];
    const workspaceFileRead = vi.fn((path: string) => {
      let resolve!: (result: WorkspaceFileReadResult) => void;
      let reject!: (err: unknown) => void;
      const promise = new Promise<WorkspaceFileReadResult>((res, rej) => {
        resolve = res;
        reject = rej;
      });
      calls.push({ path, resolve, reject, promise });
      return promise;
    });
    return { workspaceFileRead, calls };
  }

  it("failure leg: a failed open of a different file fires a reconcile for the still-current file instead of stranding its own discarded reconcile", async () => {
    const { workspaceFileRead, calls } = makeIndexedDeferredRead();
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    // 1. Open a.ts, resolving immediately.
    view.open("a.ts");
    await vi.waitFor(() => expect(calls.length).toBe(1));
    calls[0]!.resolve({ content: "C0\n", sha256: "H0", size: 3 });
    await calls[0]!.promise;
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({ path: "a.ts", baseSHA256: "H0", baseContent: "C0\n", content: "C0\n", dirty: false, conflict: false }),
    );

    // 2. A live signature push for a.ts starts a reconcile read for it; hold it.
    fireFileSignature({ path: "a.ts", sha256: "H1", missing: false });
    await vi.waitFor(() => expect(calls.length).toBe(2));
    expect(calls[1]!.path).toBe("a.ts");

    // 3. Start opening b.ts — bumps openGeneration, which will discard A's in-flight reconcile once it
    // resolves. Hold B's read too.
    view.open("b.ts");
    await vi.waitFor(() => expect(calls.length).toBe(3));
    expect(calls[2]!.path).toBe("b.ts");

    // 4. Resolve A's held reconcile read. The existing generation guard discards it — the buffer must
    // stay untouched. This pins the PRE-EXISTING discard behavior (not new from this fix); it is what
    // creates the stranding the fix addresses.
    calls[1]!.resolve({ content: "C1\n", sha256: "H1", size: 3 });
    await calls[1]!.promise;
    await vi.waitFor(() => {
      expect(view.collectStateForFlush()).toBe(
        JSON.stringify({ path: "a.ts", baseSHA256: "H0", baseContent: "C0\n", content: "C0\n", dirty: false, conflict: false }),
      );
    });

    // 5. B's open fails.
    calls[2]!.reject(new SpacesBridgeError("notFound", "no such file: b.ts"));
    await calls[2]!.promise.catch(() => {});

    // 6. WITH THE FIX: the catch block fires a fresh reconcile for the still-current a.ts.
    await vi.waitFor(() => expect(calls.length).toBe(4));
    expect(calls[3]!.path).toBe("a.ts");
    calls[3]!.resolve({ content: "C1\n", sha256: "H1", size: 3 });
    await calls[3]!.promise;

    // 7. The buffer silently reloaded from the fresh reconcile — the change that would otherwise have
    // been lost for good is caught.
    await vi.waitFor(() => {
      expect(view.collectStateForFlush()).toBe(
        JSON.stringify({ path: "a.ts", baseSHA256: "H1", baseContent: "C1\n", content: "C1\n", dirty: false, conflict: false }),
      );
    });
  });

  it("refusal leg: a discard-gated open of a different file fires a reconcile for the still-current file instead of stranding its own discarded reconcile", async () => {
    const { workspaceFileRead, calls } = makeIndexedDeferredRead();
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    // 1. Open a.ts cleanly.
    view.open("a.ts");
    await vi.waitFor(() => expect(calls.length).toBe(1));
    calls[0]!.resolve({ content: "C0\n", sha256: "H0", size: 3 });
    await calls[0]!.promise;

    // 2. A is clean, so open()'s upfront dirty check lets B's read start directly, no banner yet. Hold it.
    view.open("b.ts");
    await vi.waitFor(() => expect(calls.length).toBe(2));
    expect(calls[1]!.path).toBe("b.ts");

    // 3. While B's read is in flight, edit A — open()'s upfront dirty check ran before this happened, so
    // only open()'s completion-time recheck can catch it (same setup as the round-15 Fix A test).
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "C0 edited\n" });

    // 4. Resolve B's held read successfully.
    calls[1]!.resolve({ content: "CB\n", sha256: "HB", size: 3 });
    await calls[1]!.promise;

    // 5. The completion recheck refuses to replace A and raises the discard banner instead.
    const banner = await vi.waitFor(() => {
      const el = container.querySelector(".banner.conflict") as HTMLElement;
      expect(el.style.display).toBe("flex");
      return el;
    });
    expect(banner.textContent).toContain("Unsaved changes in a.ts");

    // 6. WITH THE FIX: the refusal fires a fresh reconcile for a.ts too. Resolve it with disk content
    // identical to what's already the baseline — the common "nothing actually changed" case.
    await vi.waitFor(() => expect(calls.length).toBe(3));
    expect(calls[2]!.path).toBe("a.ts");
    calls[2]!.resolve({ content: "C0\n", sha256: "H0", size: 3 });
    await calls[2]!.promise;

    // 7. Same-hash no-op: the discard banner and the edited buffer are untouched.
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect((container.querySelector(".banner.conflict") as HTMLElement).style.display).toBe("flex");
    expect(banner.textContent).toContain("Unsaved changes in a.ts");
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({ path: "a.ts", baseSHA256: "H0", baseContent: "C0\n", content: "C0 edited\n", dirty: true, conflict: false }),
    );
  });

  it("control: a first-ever open that fails has no previously-open file to reconcile, so no extra read fires", async () => {
    const workspaceFileRead = vi.fn().mockRejectedValueOnce(new SpacesBridgeError("notFound", "no such file: a.ts"));
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);
    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    await vi.waitFor(() => expect(container.querySelector(".banner.error")).not.toBeNull());

    expect(workspaceFileRead).toHaveBeenCalledTimes(1);
  });
});

describe("EditorView — external-change handling: dirty buffer reconciles clean when disk already matches the buffer (against-main round-4 fix)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
    capturedCodeViewOptions.current = undefined;
  });

  it("the pane's own save landing on disk before its write response returns reconciles clean, and the late response is a no-op", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "hello\n", sha256: "sha-1", size: 6 }) // initial open
      // handleExternalChange's own read: the signature poll picked up this save's own CAS write —
      // disk now holds exactly what's submitted, under a new hash the poll assigned it.
      .mockResolvedValueOnce({ content: "edited\n", sha256: "sha-2", size: 7 });
    let resolveWrite!: (result: WorkspaceFileWriteResult) => void;
    const writePromise = new Promise<WorkspaceFileWriteResult>((resolve) => (resolveWrite = resolve));
    const workspaceFileWrite = vi.fn().mockReturnValue(writePromise);
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead, workspaceFileWrite });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "edited\n" });

    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    saveBtn.click();
    await vi.waitFor(() => expect(workspaceFileWrite).toHaveBeenCalledWith("a.ts", "edited\n", { baseSHA256: "sha-1" }));

    // The write's own CAS commit lands on disk and the 2s signature poll pushes it before the
    // save's own network response comes back.
    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(2));

    // No merge indicator: disk already matched the buffer, so there was nothing to merge.
    expect(container.querySelector(".banner.merge")).toBeNull();
    expect(saveBtn.disabled).toBe(true);
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({
        path: "a.ts",
        baseSHA256: "sha-2",
        baseContent: "edited\n",
        content: "edited\n",
        dirty: false,
        conflict: false,
      }),
    );

    // The save's own write for the OLD baseline (sha-1) now lands successfully, late. Its success arm
    // is discarded by the existing fetchToken guard (the signature push above already bumped it), so
    // this must leave the reconciled clean state exactly as this branch already recorded it.
    resolveWrite({ ok: true, sha256: "write-sha-a" });
    await writePromise;

    expect(container.querySelector(".banner.merge")).toBeNull();
    expect(saveBtn.disabled).toBe(true);
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({
        path: "a.ts",
        baseSHA256: "sha-2",
        baseContent: "edited\n",
        content: "edited\n",
        dirty: false,
        conflict: false,
      }),
    );
  });

  it("an external writer that coincidentally writes exactly the buffer's content reconciles clean, with no save in flight", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "line1\nline2\n", sha256: "sha-1", size: 12 }) // initial open
      // The external writer's content happens to equal the buffer's current (unsaved) content.
      .mockResolvedValueOnce({ content: "line1 edited\nline2\n", sha256: "sha-2", size: 19 });
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "line1 edited\nline2\n" });

    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(2));

    expect(container.querySelector(".banner.merge")).toBeNull();
    expect((container.querySelector("button.primary") as HTMLButtonElement).disabled).toBe(true);
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({
        path: "a.ts",
        baseSHA256: "sha-2",
        baseContent: "line1 edited\nline2\n",
        content: "line1 edited\nline2\n",
        dirty: false,
        conflict: false,
      }),
    );
  });
});

describe("EditorView — a disk read matching an in-flight save's submitted content adopts the baseline and keeps the buffer dirty (against-main round-5 Fix 1)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
    capturedCodeViewOptions.current = undefined;
  });

  it("further typing during the flight is preserved: disk matching the submitted content adopts the baseline but leaves dirty true", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "hello\n", sha256: "sha-1", size: 6 }) // initial open
      // handleExternalChange's own read: the signature poll picked up this save's own CAS write
      // (submitted content "v1\n"), while the buffer has already moved on to "v2\n" underneath it —
      // so this does NOT match `disk.content === this.latestContent` (the round-4 branch), only
      // `disk.content === this.pendingSaveSubmitted` (Fix 1's branch).
      .mockResolvedValueOnce({ content: "v1\n", sha256: "sha-2", size: 3 });
    let resolveWrite!: (result: WorkspaceFileWriteResult) => void;
    const writePromise = new Promise<WorkspaceFileWriteResult>((resolve) => (resolveWrite = resolve));
    const workspaceFileWrite = vi.fn().mockReturnValue(writePromise);
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead, workspaceFileWrite });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "v1\n" });

    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    saveBtn.click();
    await vi.waitFor(() => expect(workspaceFileWrite).toHaveBeenCalledWith("a.ts", "v1\n", { baseSHA256: "sha-1" }));

    // Further typing during the flight: the write already submitted "v1\n", but the buffer moves on
    // to "v2\n" before the write's response comes back.
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "v2\n" });

    // The signature poll picks up the save's own CAS write (disk == "v1\n", exactly what was
    // submitted) before the write's own network response returns.
    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(2));

    // No conflict, no merge indicator: this is recognized as the pane's own write completing, not a
    // real external change to reconcile against.
    // Banner element stays in the DOM classed "banner conflict" from the constructor default (only
    // its content/buttons and display are ever swapped) — no real conflict was entered, so it must
    // stay hidden, and no merge banner (a different className) was raised at all.
    expect((container.querySelector(".banner.conflict") as HTMLElement).style.display).toBe("none");
    expect(container.querySelector(".banner.merge")).toBeNull();
    expect(saveBtn.disabled).toBe(false);
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({
        path: "a.ts",
        baseSHA256: "sha-2",
        baseContent: "v1\n",
        content: "v2\n",
        dirty: true,
        conflict: false,
      }),
    );

    // The save's own write for the OLD baseline (sha-1) now lands successfully, late. Its success arm
    // is discarded by the existing fetchToken guard (the signature push above already bumped it), so
    // this must leave the reconciled state exactly as this branch already recorded it.
    resolveWrite({ ok: true, sha256: "write-sha-a" });
    await writePromise;

    // Banner element stays in the DOM classed "banner conflict" from the constructor default (only
    // its content/buttons and display are ever swapped) — no real conflict was entered, so it must
    // stay hidden, and no merge banner (a different className) was raised at all.
    expect((container.querySelector(".banner.conflict") as HTMLElement).style.display).toBe("none");
    expect(container.querySelector(".banner.merge")).toBeNull();
    expect(saveBtn.disabled).toBe(false);
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({
        path: "a.ts",
        baseSHA256: "sha-2",
        baseContent: "v1\n",
        content: "v2\n",
        dirty: true,
        conflict: false,
      }),
    );
  });

  it("a genuinely third-party disk read during the same held-save shape still routes to diff3 and shows the conflict view (regression)", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "hello\n", sha256: "sha-1", size: 6 }) // initial open
      // A genuinely third-party write: differs from both the submitted content ("world\n") and the
      // buffer's current, further-typed content ("world2\n"), on the same line/region as both.
      .mockResolvedValueOnce({ content: "planet\n", sha256: "sha-2", size: 7 });
    let resolveWrite!: (result: WorkspaceFileWriteResult) => void;
    const writePromise = new Promise<WorkspaceFileWriteResult>((resolve) => (resolveWrite = resolve));
    const workspaceFileWrite = vi.fn().mockReturnValue(writePromise);
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead, workspaceFileWrite });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "world\n" });

    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    saveBtn.click();
    await vi.waitFor(() => expect(workspaceFileWrite).toHaveBeenCalledWith("a.ts", "world\n", { baseSHA256: "sha-1" }));

    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "world2\n" });

    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });

    const conflictBanner = await vi.waitFor(() => {
      const el = container.querySelector(".banner.conflict") as HTMLElement;
      expect(el.style.display).toBe("flex");
      return el;
    });
    expect(conflictBanner.textContent).toContain("changed on disk");
    expect(saveBtn.disabled).toBe(true);

    // The save's own write for the OLD baseline now lands successfully, late — its success arm stands
    // down on the pre-existing fetchToken guard, so the conflict this fix must still catch stays put.
    resolveWrite({ ok: true, sha256: "write-sha-a" });
    await writePromise;

    expect(conflictBanner.style.display).toBe("flex");
    expect(conflictBanner.textContent).toContain("changed on disk");
    expect(saveBtn.disabled).toBe(true);
  });
});

describe("EditorView — external-change handling: dirty buffer, real conflict + compare view", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
    capturedCodeViewOptions.current = undefined;
  });

  it("overlapping edits enter conflict state, blocking Save, with Keep mine / Take disk actions", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "hello\n", sha256: "sha-1", size: 6 })
      .mockResolvedValueOnce({ content: "goodbye\n", sha256: "sha-2", size: 8 });
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "edited\n" });

    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });

    const conflictBanner = await vi.waitFor(() => {
      const el = container.querySelector(".banner.conflict") as HTMLElement;
      expect(el.style.display).toBe("flex");
      return el;
    });
    expect(conflictBanner.textContent).toContain("changed on disk");
    expect((container.querySelector("button.primary") as HTMLButtonElement).disabled).toBe(true);
  });

  it("Keep mine force-writes the buffer over disk (CAS-checked against the conflict's disk snapshot) and returns to a clean, non-conflict state", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "hello\n", sha256: "sha-1", size: 6 })
      .mockResolvedValueOnce({ content: "goodbye\n", sha256: "sha-2", size: 8 });
    const workspaceFileWrite = vi.fn().mockResolvedValue({ ok: true, sha256: "sha-3" });
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead, workspaceFileWrite });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "edited\n" });
    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });

    const conflictBanner = await vi.waitFor(() => {
      const el = container.querySelector(".banner.conflict") as HTMLElement;
      expect(el.style.display).toBe("flex");
      return el;
    });
    (conflictBanner.querySelector("button") as HTMLButtonElement).click(); // "Keep mine" is the first button
    await vi.waitFor(() => expect(workspaceFileWrite).toHaveBeenCalledWith("a.ts", "edited\n", { baseSHA256: "sha-2" }));

    await vi.waitFor(() => expect(conflictBanner.style.display).toBe("none"));
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({
        path: "a.ts",
        baseSHA256: "sha-3",
        baseContent: "edited\n",
        content: "edited\n",
        dirty: false,
        conflict: false,
      }),
    );
  });

  it("Take disk discards the buffer, adopts disk's content, and returns to a clean, non-conflict state", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "hello\n", sha256: "sha-1", size: 6 })
      .mockResolvedValueOnce({ content: "goodbye\n", sha256: "sha-2", size: 8 });
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "edited\n" });
    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });

    const conflictBanner = await vi.waitFor(() => {
      const el = container.querySelector(".banner.conflict") as HTMLElement;
      expect(el.style.display).toBe("flex");
      return el;
    });
    const takeDiskBtn = [...conflictBanner.querySelectorAll("button")].find((b) => b.textContent === "Take disk")!;
    takeDiskBtn.click();

    expect(conflictBanner.style.display).toBe("none");
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({
        path: "a.ts",
        baseSHA256: "sha-2",
        baseContent: "goodbye\n",
        content: "goodbye\n",
        dirty: false,
        conflict: false,
      }),
    );
  });

  it("a dirty buffer whose file was deleted on disk enters conflict state with deleted wording and 'Close without saving'", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "hello\n", sha256: "sha-1", size: 6 })
      .mockRejectedValueOnce(new SpacesBridgeError("notFound", "a.ts is gone"));
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);
    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "edited\n" });
    fireFileSignature({ path: "a.ts", sha256: undefined, missing: true });

    const conflictBanner = await vi.waitFor(() => {
      const el = container.querySelector(".banner.conflict") as HTMLElement;
      expect(el.style.display).toBe("flex");
      return el;
    });
    expect(conflictBanner.textContent).toContain("deleted on disk");
    const closeBtn = [...conflictBanner.querySelectorAll("button")].find((b) => b.textContent === "Close without saving")!;
    closeBtn.click();

    expect(container.querySelector(".editor-path")!.textContent).toBe("a.ts"); // path stays in the box
    expect(view.collectStateForFlush()).toBeNull();
    expect((container.querySelector("button.primary") as HTMLButtonElement).disabled).toBe(true);
  });
});

describe("EditorView — Keep mine's late arms stand down when a newer reconciliation already ran (against-main round-5 Fix 2)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
    capturedCodeViewOptions.current = undefined;
  });

  it("a newer reconcile completing while Keep mine's write is in flight is not clobbered by the write's late success", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "hello\n", sha256: "sha-1", size: 6 }) // initial open
      .mockResolvedValueOnce({ content: "goodbye\n", sha256: "sha-2", size: 8 }) // enters conflict
      // A further external write lands while Keep mine's own write is in flight: distinct from both
      // "mine" ("edited\n") and the original conflict snapshot ("goodbye\n").
      .mockResolvedValueOnce({ content: "third\n", sha256: "sha-3", size: 6 });
    let resolveWrite!: (result: WorkspaceFileWriteResult) => void;
    const writePromise = new Promise<WorkspaceFileWriteResult>((resolve) => (resolveWrite = resolve));
    const workspaceFileWrite = vi.fn().mockReturnValue(writePromise);
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead, workspaceFileWrite });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "edited\n" });
    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });

    const conflictBanner = await vi.waitFor(() => {
      const el = container.querySelector(".banner.conflict") as HTMLElement;
      expect(el.style.display).toBe("flex");
      return el;
    });
    (conflictBanner.querySelector("button") as HTMLButtonElement).click(); // "Keep mine" is the first button
    await vi.waitFor(() => expect(workspaceFileWrite).toHaveBeenCalledWith("a.ts", "edited\n", { baseSHA256: "sha-2" }));

    // A further external write lands while Keep mine's own write is in flight. `handleExternalChange`
    // runs unchanged while already in conflict (see its doc comment): this reconcile re-enters
    // conflict against the NEWEST disk snapshot before Keep mine's own write response ever returns.
    fireFileSignature({ path: "a.ts", sha256: "sha-3", missing: false });
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(3));
    await vi.waitFor(() => expect(conflictBanner.textContent).toContain("changed on disk"));

    // Keep mine's write for the OLD conflict snapshot (baseSHA256 "sha-2") now lands successfully,
    // late. Without this fix, its success arm would overwrite the reconcile's decision with the
    // OLDER submitted content, marking the editor clean — asserting the reconcile's outcome survives
    // is exactly what this fix is about.
    resolveWrite({ ok: true, sha256: "write-sha-a" });
    await writePromise;

    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({
        path: "a.ts",
        baseSHA256: "sha-3",
        baseContent: "third\n",
        content: "edited\n",
        dirty: true,
        conflict: true,
      }),
    );
    expect(container.querySelector(".banner.conflict")!.textContent).toContain("changed on disk");
    // The Save button (first "primary" button in document order — the compare view's own "Keep mine"
    // is a second "primary" button inside the banner) stays disabled: still in conflict.
    expect((container.querySelector("button.primary") as HTMLButtonElement).disabled).toBe(true);
  });

  // Regression: plain Keep mine with no interleaved signature event during the write still commits
  // the clean keep-mine state exactly as before this fix. Already covered by the existing "Keep mine
  // force-writes the buffer over disk..." test above — its write never races a `handleExternalChange`
  // reconcile, so `fetchToken === this.externalChangeFetchToken` holds throughout and the new guard is
  // a pass-through. No separate test added here per the fix spec's guidance to add one only if the
  // existing coverage is judged insufficient.
});

describe("EditorView — Keep mine disables both banner buttons while its write is in flight (P2 fix: Take-disk-after-Keep-mine race)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
    capturedCodeViewOptions.current = undefined;
  });

  it("Take disk stays inert while Keep mine's write is in flight, and the write's late success still commits mine as clean", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "hello\n", sha256: "sha-1", size: 6 })
      .mockResolvedValueOnce({ content: "goodbye\n", sha256: "sha-2", size: 8 });
    let resolveWrite!: (result: WorkspaceFileWriteResult) => void;
    const writePromise = new Promise<WorkspaceFileWriteResult>((resolve) => (resolveWrite = resolve));
    const workspaceFileWrite = vi.fn().mockReturnValue(writePromise);
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead, workspaceFileWrite });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "edited\n" });
    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });

    const conflictBanner = await vi.waitFor(() => {
      const el = container.querySelector(".banner.conflict") as HTMLElement;
      expect(el.style.display).toBe("flex");
      return el;
    });
    const keepMineBtn = [...conflictBanner.querySelectorAll("button")].find((b) => b.textContent === "Keep mine")!;
    const takeDiskBtn = [...conflictBanner.querySelectorAll("button")].find((b) => b.textContent === "Take disk")!;

    keepMineBtn.click();
    await vi.waitFor(() => expect(workspaceFileWrite).toHaveBeenCalledWith("a.ts", "edited\n", { baseSHA256: "sha-2" }));

    expect(keepMineBtn.disabled).toBe(true);
    expect(takeDiskBtn.disabled).toBe(true);

    // Take disk is clicked anyway while disabled: like a real browser, jsdom does not fire a click
    // handler on a disabled button, so this must be a no-op — the compare view keeps showing and the
    // buffer/state are untouched (still "mine", still in conflict against the original snapshot).
    takeDiskBtn.click();
    expect(conflictBanner.style.display).toBe("flex");
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({
        path: "a.ts",
        baseSHA256: "sha-2",
        baseContent: "goodbye\n",
        content: "edited\n",
        dirty: true,
        conflict: true,
      }),
    );

    // Keep mine's write now lands successfully: the pane commits "mine" as clean, same success-arm
    // behavior as the plain Keep mine test above ("Keep mine force-writes the buffer over disk...").
    resolveWrite({ ok: true, sha256: "sha-3" });
    await writePromise;

    await vi.waitFor(() => expect(conflictBanner.style.display).toBe("none"));
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({
        path: "a.ts",
        baseSHA256: "sha-3",
        baseContent: "edited\n",
        content: "edited\n",
        dirty: false,
        conflict: false,
      }),
    );
  });

  it("a rejected Keep mine write re-renders the compare view with fresh, enabled buttons", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "hello\n", sha256: "sha-1", size: 6 })
      .mockResolvedValueOnce({ content: "goodbye\n", sha256: "sha-2", size: 8 });
    let rejectWrite!: (err: unknown) => void;
    const writePromise = new Promise<WorkspaceFileWriteResult>((_resolve, reject) => (rejectWrite = reject));
    const workspaceFileWrite = vi.fn().mockReturnValue(writePromise);
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead, workspaceFileWrite });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "edited\n" });
    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });

    const conflictBanner = await vi.waitFor(() => {
      const el = container.querySelector(".banner.conflict") as HTMLElement;
      expect(el.style.display).toBe("flex");
      return el;
    });
    const keepMineBtn = conflictBanner.querySelector("button") as HTMLButtonElement; // "Keep mine" is the first button
    keepMineBtn.click();
    await vi.waitFor(() => expect(workspaceFileWrite).toHaveBeenCalledWith("a.ts", "edited\n", { baseSHA256: "sha-2" }));
    expect(keepMineBtn.disabled).toBe(true);

    rejectWrite(new SpacesBridgeError("unavailable", "daemon not reachable"));
    await writePromise.catch(() => {});

    // The failure arm calls `renderConflictCompareView(message)`, which rebuilds the banner's
    // buttons from scratch (fresh elements, `disabled` defaulting to false) rather than re-enabling
    // the stale ones — so this also confirms the same DOM node (`this.banner`) got new children.
    await vi.waitFor(() => expect(conflictBanner.textContent).toContain("daemon not reachable"));
    const reKeepMineBtn = [...conflictBanner.querySelectorAll("button")].find((b) => b.textContent === "Keep mine")!;
    const reTakeDiskBtn = [...conflictBanner.querySelectorAll("button")].find((b) => b.textContent === "Take disk")!;
    expect(reKeepMineBtn.disabled).toBe(false);
    expect(reTakeDiskBtn.disabled).toBe(false);
  });
});

describe("EditorView — external-change handling: superseded fetch (round-16 latest-wins)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
  });

  it("two file-signature events firing before either read resolves: only the later read's outcome applies", async () => {
    const settle: { resolve: (r: WorkspaceFileReadResult) => void }[] = [];
    const workspaceFileRead = vi.fn(() => {
      let resolve!: (r: WorkspaceFileReadResult) => void;
      const promise = new Promise<WorkspaceFileReadResult>((res) => (resolve = res));
      settle.push({ resolve });
      return promise;
    });
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(1));
    settle[0]!.resolve({ content: "hello\n", sha256: "sha-1", size: 6 });
    await Promise.resolve();
    await Promise.resolve();

    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(2));
    fireFileSignature({ path: "a.ts", sha256: "sha-3", missing: false });
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(3));

    // Resolve the FIRST (now-superseded) external-change fetch after the second one has already
    // started — its result must be dropped rather than clobbering whatever the second fetch lands.
    settle[1]!.resolve({ content: "stale intermediate\n", sha256: "sha-2", size: 19 });
    await Promise.resolve();
    await Promise.resolve();
    settle[2]!.resolve({ content: "latest\n", sha256: "sha-3", size: 7 });

    await vi.waitFor(() =>
      expect(view.collectStateForFlush()).toBe(
        JSON.stringify({
          path: "a.ts",
          baseSHA256: "sha-3",
          baseContent: "latest\n",
          content: "latest\n",
          dirty: false,
          conflict: false,
        }),
      ),
    );
  });
});

describe("EditorView — external-change execution-failure retry (round-17 Fix A)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("a transient read failure after a signature event retries after the backoff floor and applies the retried read", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "hello\n", sha256: "sha-1", size: 6 }) // initial open
      .mockRejectedValueOnce(new SpacesBridgeError("internalError", "daemon hiccup")) // signature event's read fails transiently
      .mockResolvedValueOnce({ content: "hello, updated\n", sha256: "sha-2", size: 15 }); // retried read succeeds
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(1));

    vi.useFakeTimers();
    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });
    await Promise.resolve();
    await Promise.resolve();
    expect(workspaceFileRead).toHaveBeenCalledTimes(2); // the failed attempt

    vi.advanceTimersByTime(999);
    expect(workspaceFileRead).toHaveBeenCalledTimes(2); // not yet at the 1000ms floor

    await vi.advanceTimersByTimeAsync(1);
    expect(workspaceFileRead).toHaveBeenCalledTimes(3); // the retry fired and re-read

    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({
        path: "a.ts",
        baseSHA256: "sha-2",
        baseContent: "hello, updated\n",
        content: "hello, updated\n",
        dirty: false,
        conflict: false,
      }),
    );
    expect((container.querySelector(".banner") as HTMLElement).style.display).toBe("none");
  });

  it("a pending retry superseded by opening a different file becomes a no-op", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "hello\n", sha256: "sha-1", size: 6 }) // open a.ts
      .mockRejectedValueOnce(new SpacesBridgeError("internalError", "daemon hiccup")) // a.ts's external-change fails transiently
      .mockResolvedValueOnce({ content: "b content\n", sha256: "sha-b", size: 10 }); // open b.ts
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);
    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(1));

    vi.useFakeTimers();
    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });
    await Promise.resolve();
    await Promise.resolve();
    expect(workspaceFileRead).toHaveBeenCalledTimes(2); // a.ts's failed attempt, retry now pending

    // Opening a different file while clean (not dirty) proceeds immediately — no discard gate.
    view.open("b.ts");
    await Promise.resolve();
    await Promise.resolve();
    expect(workspaceFileRead).toHaveBeenCalledTimes(3); // b.ts's own open

    // The stale a.ts retry would fire here if its generation guard didn't catch it.
    await vi.advanceTimersByTimeAsync(1000);
    expect(workspaceFileRead).toHaveBeenCalledTimes(3); // no unwanted 4th call against b.ts

    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({
        path: "b.ts",
        baseSHA256: "sha-b",
        baseContent: "b content\n",
        content: "b content\n",
        dirty: false,
        conflict: false,
      }),
    );
  });

  it("a pending retry superseded by a fresh signature event's own successful fetch is a no-op when it later fires", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "hello\n", sha256: "sha-1", size: 6 }) // open
      .mockRejectedValueOnce(new SpacesBridgeError("internalError", "daemon hiccup")) // first event fails transiently
      .mockResolvedValueOnce({ content: "hello, v3\n", sha256: "sha-3", size: 10 }); // second, genuinely newer event succeeds
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(1));

    vi.useFakeTimers();
    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });
    await Promise.resolve();
    await Promise.resolve();
    expect(workspaceFileRead).toHaveBeenCalledTimes(2); // failed attempt, retry now pending

    fireFileSignature({ path: "a.ts", sha256: "sha-3", missing: false }); // a genuinely newer frame
    await Promise.resolve();
    await Promise.resolve();
    expect(workspaceFileRead).toHaveBeenCalledTimes(3); // the newer event's own fresh fetch

    const latestState = JSON.stringify({
      path: "a.ts",
      baseSHA256: "sha-3",
      baseContent: "hello, v3\n",
      content: "hello, v3\n",
      dirty: false,
      conflict: false,
    });
    expect(view.collectStateForFlush()).toBe(latestState);

    // The stale retry from the first (failed) event would fire here if its token guard didn't
    // catch it — only the newer event's outcome must ever be acted on, not both.
    await vi.advanceTimersByTimeAsync(1000);
    expect(workspaceFileRead).toHaveBeenCalledTimes(3);
    expect(view.collectStateForFlush()).toBe(latestState);
  });

  it("notFound still goes straight to the deleted-file branch with no retry scheduled", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "hello\n", sha256: "sha-1", size: 6 })
      .mockRejectedValueOnce(new SpacesBridgeError("notFound", "a.ts is gone"));
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);
    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(1));

    vi.useFakeTimers();
    fireFileSignature({ path: "a.ts", sha256: undefined, missing: true });
    await Promise.resolve();
    await Promise.resolve();
    expect(workspaceFileRead).toHaveBeenCalledTimes(2);
    expect(view.collectStateForFlush()).toBeNull(); // straight to the deleted-file placeholder
    expect(container.querySelector(".editor-path")!.textContent).toBe("a.ts"); // path stays in the box

    // Well past the retry cap (30s) — a notFound answer is authoritative, so nothing should ever
    // fire here.
    await vi.advanceTimersByTimeAsync(35000);
    expect(workspaceFileRead).toHaveBeenCalledTimes(2);
  });
});

describe("EditorView — external-change execution-failure retry: invalidArgument is terminal (Fix 3, round-2)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
    capturedCodeViewOptions.current = undefined;
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("a decoded invalidArgument read failure shows an error banner without scheduling a retry", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "hello\n", sha256: "sha-1", size: 6 })
      .mockRejectedValueOnce(new SpacesBridgeError("invalidArgument", "a.ts is not a UTF-8 text file"));
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);
    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(1));

    vi.useFakeTimers();
    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });
    await Promise.resolve();
    await Promise.resolve();
    expect(workspaceFileRead).toHaveBeenCalledTimes(2);

    const banner = container.querySelector(".banner") as HTMLElement;
    expect(banner.className).toBe("banner error");
    expect(banner.style.display).toBe("flex");
    expect(banner.textContent).toBe("a.ts is not a UTF-8 text file");
    // The open-file state and clean buffer are untouched — invalidArgument doesn't tear down the
    // pane the way notFound's deleted-file placeholder does.
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({ path: "a.ts", baseSHA256: "sha-1", baseContent: "hello\n", content: "hello\n", dirty: false, conflict: false }),
    );
    expect(container.querySelector(".editor-path")!.textContent).toBe("a.ts");

    // Well past the retry cap — invalidArgument is a durable, decoded answer, so no retry of our own
    // should ever fire for it.
    await vi.advanceTimersByTimeAsync(35000);
    expect(workspaceFileRead).toHaveBeenCalledTimes(2);
  });

  it("a later signature event still attempts a fresh read and reloads normally, proving the subscription survives", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "hello\n", sha256: "sha-1", size: 6 })
      .mockRejectedValueOnce(new SpacesBridgeError("invalidArgument", "a.ts is not a UTF-8 text file"))
      .mockResolvedValueOnce({ content: "hello, fixed\n", sha256: "sha-3", size: 13 });
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(1));

    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(2));
    expect((container.querySelector(".banner") as HTMLElement).className).toBe("banner error");

    // A fresh event (e.g. the file being rewritten back under the size cap, or as valid UTF-8) is
    // still handed to a fresh handleExternalChange() call — the subscription was never torn down.
    fireFileSignature({ path: "a.ts", sha256: "sha-3", missing: false });
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(3));

    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({
        path: "a.ts",
        baseSHA256: "sha-3",
        baseContent: "hello, fixed\n",
        content: "hello, fixed\n",
        dirty: false,
        conflict: false,
      }),
    );
  });
});

describe("EditorView — invalidArgument banner clears once the file becomes readable again (round-1 Fix 1)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
    capturedCodeViewOptions.current = undefined;
  });

  it("a recovery read whose content matches the baseline (same sha256) hides the banner and does not reload", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "hello\n", sha256: "sha-1", size: 6 })
      .mockRejectedValueOnce(new SpacesBridgeError("invalidArgument", "a.ts is not a UTF-8 text file"))
      // The file is back to exactly the baseline content — same hash as `baseSHA256`, which
      // invalidArgument never touched.
      .mockResolvedValueOnce({ content: "hello\n", sha256: "sha-1", size: 6 });
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(1));

    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(2));
    const banner = container.querySelector(".banner") as HTMLElement;
    expect(banner.className).toBe("banner error");
    expect(banner.style.display).toBe("flex");

    fireFileSignature({ path: "a.ts", sha256: "sha-3", missing: false });
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(3));

    expect(banner.style.display).toBe("none");
    // Same-hash early return: no reload, buffer/state untouched from the original open.
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({ path: "a.ts", baseSHA256: "sha-1", baseContent: "hello\n", content: "hello\n", dirty: false, conflict: false }),
    );
  });

  it("a recovery read with new content on a clean buffer hides the banner and silently reloads", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "hello\n", sha256: "sha-1", size: 6 })
      .mockRejectedValueOnce(new SpacesBridgeError("invalidArgument", "a.ts is not a UTF-8 text file"))
      .mockResolvedValueOnce({ content: "hello v2\n", sha256: "sha-2", size: 9 });
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(1));

    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(2));
    const banner = container.querySelector(".banner") as HTMLElement;
    expect(banner.style.display).toBe("flex");

    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(3));

    expect(banner.style.display).toBe("none");
    // Clean-buffer silent reload: the new content and hash are adopted as the fresh baseline.
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({
        path: "a.ts",
        baseSHA256: "sha-2",
        baseContent: "hello v2\n",
        content: "hello v2\n",
        dirty: false,
        conflict: false,
      }),
    );
  });

  it("guard: a spurious same-hash event never clears an unrelated banner (the merge indicator) it did not put up", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "line1\nline2\n", sha256: "sha-1", size: 12 })
      .mockResolvedValueOnce({ content: "line1\nline2\nline3\n", sha256: "sha-2", size: 18 })
      // Spurious dedupe: same content/hash as what the merge already adopted as its baseline.
      .mockResolvedValueOnce({ content: "line1\nline2\nline3\n", sha256: "sha-2", size: 18 });
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    // Mine: edits line1 only. Theirs: appends line3 only. Non-overlapping — auto-merges cleanly.
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "line1 edited\nline2\n" });

    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });
    const merge = await vi.waitFor(() => {
      const el = container.querySelector(".banner.merge") as HTMLElement;
      expect(el.style.display).toBe("flex");
      return el;
    });
    expect(merge.textContent).toContain("Merged external changes");

    // The `unreadableBannerVisible` flag was never set — this run never touched the invalidArgument
    // branch — so this spurious same-hash event must not clear the merge indicator it did not show.
    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(3));

    expect((container.querySelector(".banner") as HTMLElement).className).toBe("banner merge");
    expect((container.querySelector(".banner") as HTMLElement).style.display).toBe("flex");
    expect((container.querySelector(".banner") as HTMLElement).textContent).toContain("Merged external changes");
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({
        path: "a.ts",
        baseSHA256: "sha-2",
        baseContent: "line1\nline2\nline3\n",
        content: "line1 edited\nline2\nline3\n",
        dirty: true,
        conflict: false,
      }),
    );
  });
});

describe("EditorView — round-24 Fix 3 (P2): unreadableBannerVisible does not leak across a file switch", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
    capturedCodeViewOptions.current = undefined;
  });

  // Traced against the actual source (both with and without this fix applied, run empirically):
  // a merge-indicator-then-spurious-same-hash sequence on the switched-to file, as one might first
  // guess, does NOT distinguish pre-fix from post-fix behavior. `handleExternalChange`'s
  // `unreadableBannerVisible`-gated clear (around line 582) runs unconditionally on the FIRST decoded
  // outcome it reaches — and the auto-merge that establishes the merge indicator is itself that first
  // decoded outcome, so the leaked flag is consumed (harmlessly, since no banner is up yet for the new
  // file) BEFORE the merge branch runs later in that same synchronous call and sets the merge banner.
  // By the time a second, genuinely spurious same-hash event arrives, the flag is already false either
  // way. The single-file "guard: a spurious same-hash event never clears an unrelated banner" test
  // above (round-1 Fix 1) already proves this same-call ordering is safe when the flag was never true
  // to begin with; it is not evidence one way or the other about the leak this fix addresses.
  //
  // The leak is only observable when the unrelated banner is put up by a path OTHER than
  // `handleExternalChange` itself — so nothing has yet consumed the leaked-true flag — and a
  // `handleExternalChange` call for the new file arrives afterward. `showDiscardBanner` (opening a
  // third file while the second is dirty) is exactly such a path: it sets the banner directly, with no
  // `handleExternalChange` call in between opening the second file and putting up that banner.
  it("a discard-consent banner on the switched-to file survives a spurious same-hash event, even though the previous file left the unreadable flag set", async () => {
    const workspaceFileRead = vi
      .fn()
      // open a.ts
      .mockResolvedValueOnce({ content: "a content\n", sha256: "sha-a1", size: 10 })
      // a.ts's signature event: unreadable -- sets unreadableBannerVisible = true
      .mockRejectedValueOnce(new SpacesBridgeError("invalidArgument", "a.ts is not a UTF-8 text file"))
      // open b.ts (clean, not dirty -- proceeds immediately, no gate)
      .mockResolvedValueOnce({ content: "line1\nline2\n", sha256: "sha-b1", size: 12 })
      // b.ts's spurious same-hash dedupe (matches its own unchanged baseline)
      .mockResolvedValueOnce({ content: "line1\nline2\n", sha256: "sha-b1", size: 12 });
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);
    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(1));
    fireFileSignature({ path: "a.ts", sha256: "sha-a2", missing: false });
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(2));
    expect((container.querySelector(".banner") as HTMLElement).className).toBe("banner error");

    view.open("b.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(3));
    // open()'s success arm always hides the banner unconditionally, whether or not this fix is
    // applied -- this alone is not evidence the leaked flag was cleared.
    expect((container.querySelector(".banner") as HTMLElement).style.display).toBe("none");

    // Dirty b.ts, then attempt to open a third file while dirty -- open()'s gate shows the
    // discard-consent banner directly (no handleExternalChange call happens in between), so if the
    // leaked flag from a.ts is still true, nothing has consumed it yet.
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "line1 edited\nline2\n" });
    view.open("c.ts");
    const discardBanner = container.querySelector(".banner.conflict") as HTMLElement;
    expect(discardBanner.style.display).toBe("flex");
    expect(discardBanner.textContent).toContain("Unsaved changes in b.ts");

    // A spurious same-hash dedupe for b.ts -- this is the FIRST handleExternalChange call to run for
    // b.ts. Pre-fix, the leaked-true flag hits the gated clear at the top of the decoded-outcome
    // handling (before the same-hash early return a few lines below it), wiping the discard banner it
    // never put up. Post-fix, this fix already cleared the flag when b.ts was opened, so the gated
    // clear block is skipped entirely and the banner is untouched.
    fireFileSignature({ path: "b.ts", sha256: "sha-b1", missing: false });
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(4));

    expect(discardBanner.style.display).toBe("flex");
    expect(discardBanner.textContent).toContain("Unsaved changes in b.ts");
    // Sanity: the read genuinely was the spurious same-hash path (no reload happened).
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({
        path: "b.ts",
        baseSHA256: "sha-b1",
        baseContent: "line1\nline2\n",
        content: "line1 edited\nline2\n",
        dirty: true,
        conflict: false,
      }),
    );
  });
});

describe("EditorView — a standing conflict stays latched until explicit resolution (round-17 Fix 1)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
    capturedCodeViewOptions.current = undefined;
  });

  it("a further disk-side write outside the disputed hunk does not silently auto-merge and re-enable Save; Keep mine still CAS-checks against the newest disk snapshot", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "line1\nline2\nline3\n", sha256: "sha-1", size: 18 }) // initial open
      // disk1: rewrites line1 (the disputed hunk H) differently from "mine" -> genuine conflict.
      .mockResolvedValueOnce({ content: "line1 theirs\nline2\nline3\n", sha256: "sha-2", size: 24 })
      // disk2: keeps disk1's line1 exactly, but edits line3 -- outside H, non-overlapping with "mine"
      // relative to the FROZEN conflict base ("line1 theirs\n..."), which is exactly the shape that
      // would fool diff3 into a false clean merge without the round-17 fix.
      .mockResolvedValueOnce({ content: "line1 theirs\nline2\nline3 edited\n", sha256: "sha-3", size: 30 });
    const workspaceFileWrite = vi.fn().mockResolvedValue({ ok: true, sha256: "sha-4" });
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead, workspaceFileWrite });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "line1 mine\nline2\nline3\n" });

    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });
    const conflictBanner = await vi.waitFor(() => {
      const el = container.querySelector(".banner.conflict") as HTMLElement;
      expect(el.style.display).toBe("flex");
      return el;
    });
    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    expect(saveBtn.disabled).toBe(true);

    // Second external change: disk2 diverges from disk1 only outside H. Without the fix, this would
    // diff3-merge cleanly against the frozen conflict base and silently re-enable Save.
    fireFileSignature({ path: "a.ts", sha256: "sha-3", missing: false });
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(3));

    expect(conflictBanner.style.display).toBe("flex");
    expect(conflictBanner.textContent).toContain("changed on disk");
    expect(saveBtn.disabled).toBe(true);
    expect(container.querySelector(".banner.merge")).toBeNull();

    // Keep mine's CAS baseline must have followed the refreshed (disk2) snapshot, not the stale disk1
    // one -- proving the re-entry above actually refreshed against the newest disk state.
    (conflictBanner.querySelector("button") as HTMLButtonElement).click(); // "Keep mine" is the first button
    await vi.waitFor(() =>
      expect(workspaceFileWrite).toHaveBeenCalledWith("a.ts", "line1 mine\nline2\nline3\n", { baseSHA256: "sha-3" }),
    );
  });

  it("a conflict dissolves when a later disk write exactly matches the frozen buffer, restoring the edit view", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "hello\n", sha256: "sha-1", size: 6 }) // initial open
      .mockResolvedValueOnce({ content: "goodbye\n", sha256: "sha-2", size: 8 }) // enters conflict
      // A later writer (e.g. Keep mine from another client) lands exactly the frozen buffer content.
      .mockResolvedValueOnce({ content: "edited\n", sha256: "sha-4", size: 7 });
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    view.open("a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "edited\n" });
    fireFileSignature({ path: "a.ts", sha256: "sha-2", missing: false });

    const conflictBanner = await vi.waitFor(() => {
      const el = container.querySelector(".banner.conflict") as HTMLElement;
      expect(el.style.display).toBe("flex");
      return el;
    });

    fireFileSignature({ path: "a.ts", sha256: "sha-4", missing: false });
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(3));

    expect(conflictBanner.style.display).toBe("none");
    expect((container.querySelector("button.primary") as HTMLButtonElement).disabled).toBe(true); // not dirty
    // Pushed state confirms the conflict is fully cleared, not just the banner hidden, and that the
    // edit view (not the diff/compare view) was restored -- collectStateForFlush's `conflict: false`
    // is the seam this harness exposes for that, since the fake CodeView doesn't render real DOM.
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({
        path: "a.ts",
        baseSHA256: "sha-4",
        baseContent: "edited\n",
        content: "edited\n",
        dirty: false,
        conflict: false,
      }),
    );
  });
});

describe("EditorView — editor-attach heal (completeEditorAttach)", () => {
  let container: HTMLElement;

  beforeEach(async () => {
    container = document.createElement("div");
    // A prior test's poll whose first frame hasn't fired yet would otherwise spin into this
    // test and heal alongside its own poll; let such strays resolve under the instant-attach
    // default before switching the fake to attach-pending mode.
    await new Promise((resolve) => setTimeout(resolve, 50));
    fakeCodeViewControl.editor = undefined;
    fakeCodeViewControl.updateItemCalls = [];
  });

  afterEach(() => {
    // Restore the instant-attach default the rest of this file relies on.
    fakeCodeViewControl.editor = {};
  });

  async function openFile(view: EditorView, bridge: SpacesBridge, path: string): Promise<void> {
    view.open(path);
    await vi.waitFor(() => expect(bridge.workspaceFileRead).toHaveBeenCalledWith(path, "editor"));
  }

  it("polls until the editor attaches, then forces exactly one version-bumped re-render", async () => {
    const result: WorkspaceFileReadResult = { content: "a\n", sha256: "sha-1", size: 2 };
    const bridge = makeBridge({ workspaceFileRead: vi.fn().mockResolvedValue(result) });
    const view = new EditorView(container, bridge);
    await openFile(view, bridge, "src/a.ts");

    // Attach still pending: the poll must keep waiting without forcing a render.
    await new Promise((resolve) => setTimeout(resolve, 80));
    expect(fakeCodeViewControl.updateItemCalls).toEqual([]);

    fakeCodeViewControl.editor = {};
    await vi.waitFor(() => expect(fakeCodeViewControl.updateItemCalls.length).toBe(1));
    expect(fakeCodeViewControl.updateItemCalls[0]?.id).toBe("src/a.ts");

    // One heal per load: no further renders arrive after the poll resolved.
    await new Promise((resolve) => setTimeout(resolve, 80));
    expect(fakeCodeViewControl.updateItemCalls.length).toBe(1);
  });

  it("a poll superseded by a newer open stands down; only the newest load heals", async () => {
    const result: WorkspaceFileReadResult = { content: "a\n", sha256: "sha-1", size: 2 };
    const bridge = makeBridge({ workspaceFileRead: vi.fn().mockResolvedValue(result) });
    const view = new EditorView(container, bridge);
    await openFile(view, bridge, "src/a.ts");
    await openFile(view, bridge, "src/b.ts");

    fakeCodeViewControl.editor = {};
    await vi.waitFor(() => expect(fakeCodeViewControl.updateItemCalls.length).toBe(1));
    expect(fakeCodeViewControl.updateItemCalls[0]?.id).toBe("src/b.ts");

    await new Promise((resolve) => setTimeout(resolve, 80));
    expect(fakeCodeViewControl.updateItemCalls.length).toBe(1);
  });

  it("a same-file signature reconcile during the paint wait does not cancel the file-open render milestone", async () => {
    fakeCodeViewControl.editor = {};
    const workspaceFileRead = vi
      .fn()
      .mockResolvedValueOnce({ content: "a\n", sha256: "sha-1", size: 2 })
      .mockResolvedValueOnce({ content: "changed\n", sha256: "sha-2", size: 8 });
    const { bridge, fireFileSignature } = makeFileSignatureCapturingBridge({ workspaceFileRead });
    const onFileRendered = vi.fn();
    const view = new EditorView(container, bridge, { onFileRendered });
    await openFile(view, bridge, "src/a.ts");
    await vi.waitFor(() => expect(fakeCodeViewControl.updateItemCalls.length).toBe(1));

    fireFileSignature({ path: "src/a.ts", sha256: "sha-2", missing: false });
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(2));
    await vi.waitFor(() => expect(onFileRendered).toHaveBeenCalledTimes(1));
    expect(onFileRendered).toHaveBeenCalledWith("src/a.ts", expect.any(Number), 2);
  });

  it("retries restored caret focus until the asynchronously attached editor is available", async () => {
    const result: WorkspaceFileReadResult = { content: "one\ntwo\nthree\n", sha256: "sha-1", size: 14 };
    const bridge = makeBridge({ workspaceFileRead: vi.fn().mockResolvedValue(result) });
    const view = new EditorView(container, bridge);
    await openFile(view, bridge, "src/a.ts");

    view.restorePosition(null, 3);
    // The old one-frame attempt has already observed the unattached editor by this point.
    await new Promise((resolve) => setTimeout(resolve, 40));
    const focus = vi.fn();
    fakeCodeViewControl.editor = { focus };

    await vi.waitFor(() => expect(focus).toHaveBeenCalledWith({ lineNumber: 3 }));
  });

  it("does not start a restored-caret poll for the read-only conflict comparison", async () => {
    const workspaceFileRead = vi.fn().mockResolvedValue({ content: "disk\n", sha256: "sha-disk", size: 5 });
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);
    await view.restoreState({
      path: "src/conflict.ts",
      baseSHA256: "sha-base",
      baseContent: "base\n",
      content: "mine\n",
      dirty: true,
      conflict: true,
    });
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("src/conflict.ts", "editor"));

    const requestFrame = vi.spyOn(window, "requestAnimationFrame");
    view.restorePosition(null, 2);

    expect(requestFrame.mock.calls.map(([callback]) => (callback as unknown as { name: string }).name)).not.toContain("focusWhenAttached");
    requestFrame.mockRestore();
  });

  it("does not start a restored-caret poll for a deleted-file placeholder", async () => {
    // Let the ordinary editor attach finish before the restore reconciliation replaces it with the
    // non-editable deleted-file placeholder.
    fakeCodeViewControl.editor = {};
    const workspaceFileRead = vi.fn().mockRejectedValue(new SpacesBridgeError("notFound", "src/deleted.ts is gone"));
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);
    await view.restoreState({
      path: "src/deleted.ts",
      baseSHA256: "sha-base",
      baseContent: "before\n",
      content: "before\n",
      dirty: false,
      conflict: false,
    });
    await vi.waitFor(() => expect(view.collectStateForFlush()).toBeNull());
    await new Promise((resolve) => setTimeout(resolve, 30));
    fakeCodeViewControl.editor = undefined;

    const requestFrame = vi.spyOn(window, "requestAnimationFrame");
    view.restorePosition(null, 2);

    expect(requestFrame.mock.calls.map(([callback]) => (callback as unknown as { name: string }).name)).not.toContain("focusWhenAttached");
    requestFrame.mockRestore();
  });

  it("bounds restored-caret polling when an editable attachment never appears", async () => {
    // Let the ordinary attach-heal finish first. The editor can disappear after that render (for
    // example while Pierre replaces an item), so restorePosition still needs a finite retry rather
    // than relying only on the conflict/placeholder guards above.
    fakeCodeViewControl.editor = {};
    const bridge = makeBridge({
      workspaceFileRead: vi.fn().mockResolvedValue({ content: "one\n", sha256: "sha-1", size: 4 }),
    });
    const view = new EditorView(container, bridge);
    await openFile(view, bridge, "src/a.ts");
    await vi.waitFor(() => expect(fakeCodeViewControl.updateItemCalls.length).toBe(1));
    fakeCodeViewControl.editor = undefined;

    const queuedFrames: FrameRequestCallback[] = [];
    const requestFrame = vi.spyOn(window, "requestAnimationFrame").mockImplementation((callback) => {
      queuedFrames.push(callback);
      return queuedFrames.length;
    });
    view.restorePosition(null, 1);

    // Drain more than the permitted number. The old unbounded loop still has a focus callback
    // queued at this point; the bounded behavior naturally drains to zero.
    for (let runs = 0; queuedFrames.length > 0 && runs < 130; runs += 1) {
      queuedFrames.shift()!(performance.now());
    }

    const focusPolls = requestFrame.mock.calls.filter(
      ([callback]) => (callback as unknown as { name: string }).name === "focusWhenAttached",
    );
    expect(focusPolls).toHaveLength(121);
    expect(queuedFrames).toHaveLength(0);
    requestFrame.mockRestore();
  });
});

describe("EditorView focused-line recovery", () => {
  it("does not report a rendered line after its scroll host is detached", () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    const view = new EditorView(container, makeBridge());
    const host = container.querySelector<HTMLElement>("#code-pane-editor-scroll")!;
    const line = document.createElement("div");
    line.dataset.line = "4";
    Object.defineProperty(host, "getBoundingClientRect", { value: () => ({ top: 0 }) });
    Object.defineProperty(line, "getBoundingClientRect", { value: () => ({ bottom: 1 }) });
    host.appendChild(line);

    expect(view.visibleLine()).toBe(4);
    container.remove();
    expect(view.visibleLine()).toBeNull();
  });

  it("does not report a line whose bottom is exactly at the viewport top", () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    const view = new EditorView(container, makeBridge());
    const host = container.querySelector<HTMLElement>("#code-pane-editor-scroll")!;
    const preceding = document.createElement("div");
    preceding.dataset.line = "3";
    const visible = document.createElement("div");
    visible.dataset.line = "4";
    Object.defineProperty(host, "getBoundingClientRect", { value: () => ({ top: 100 }) });
    Object.defineProperty(preceding, "getBoundingClientRect", { value: () => ({ bottom: 100 }) });
    Object.defineProperty(visible, "getBoundingClientRect", { value: () => ({ bottom: 101 }) });
    host.append(preceding, visible);

    expect(view.visibleLine()).toBe(4);
    container.remove();
  });

  it("samples the live caret line for a workspace snapshot even when no edit occurred", async () => {
    const container = document.createElement("div");
    document.body.appendChild(container);
    const bridge = makeBridge({
      workspaceFileRead: vi.fn().mockResolvedValue({ content: "one\ntwo\nthree\n", sha256: "sha-1", size: 14 }),
    });
    const view = new EditorView(container, bridge);
    view.open("src/a.ts");
    await vi.waitFor(() => expect(bridge.workspaceFileRead).toHaveBeenCalledWith("src/a.ts", "editor"));

    fakeCodeViewControl.editorSelection = { start: { line: 2 }, end: { line: 2 }, direction: 0 };

    expect(view.focusedLineNumber()).toBe(3);
    fakeCodeViewControl.editorSelection = { start: { line: 1 }, end: { line: 2 }, direction: -1 };
    expect(view.focusedLineNumber()).toBe(2);
    fakeCodeViewControl.editorSelection = undefined;
    container.remove();
  });
});
