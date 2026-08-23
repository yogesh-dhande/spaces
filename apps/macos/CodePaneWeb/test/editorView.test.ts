import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { EditorView } from "../src/app/editorView";
import { SpacesBridge, SpacesBridgeError, WorkspaceFileReadResult, WorkspaceFileWriteResult } from "../src/bridge/types";

// EditorView's `open()` constructs a real `@pierre/diffs` CodeView on first
// success, which needs browser APIs jsdom doesn't provide (ResizeObserver,
// canvas). These tests are about editorView.ts's own request-routing and
// error-surfacing logic, not the diff-rendering library, so CodeView/Editor
// are replaced with no-op fakes; every other export (types, helpers) passes
// through untouched.
// Captures the options EditorView last constructed a (fake) CodeView with, so tests can invoke
// `onItemEditChange` directly to simulate a buffer edit without a real @pierre/diffs editor.
const capturedCodeViewOptions = vi.hoisted(() => ({ current: undefined as undefined | { onItemEditChange: (item: unknown, file: { contents: string }) => void } }));

vi.mock("@pierre/diffs", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@pierre/diffs")>();
  class FakeCodeView {
    constructor(options: { onItemEditChange: (item: unknown, file: { contents: string }) => void }) {
      capturedCodeViewOptions.current = options;
    }
    setup(): void {}
    setItems(): void {}
    cleanUp(): void {}
  }
  return { ...actual, CodeView: FakeCodeView };
});
vi.mock("@pierre/diffs/edit", () => ({
  Editor: class {},
}));

function makeBridge(overrides: Partial<SpacesBridge> = {}): SpacesBridge {
  return {
    workspaceDiff: vi.fn().mockRejectedValue(new Error("not used")),
    workspaceFileRead: vi.fn().mockRejectedValue(new Error("not used")),
    workspaceFileWrite: vi.fn().mockRejectedValue(new Error("not used")),
    workspaceFileList: vi.fn().mockRejectedValue(new SpacesBridgeError("unavailable", "File search is not available yet.")),
    subscribeDiffSignature: vi.fn(() => () => {}),
    notifyEditorStateChanged: vi.fn(),
    notifyModeChanged: vi.fn(),
    // Not used by EditorView (comments are diff-mode only) — stubbed so this satisfies
    // `SpacesBridge` without any of these tests needing to care about the comment surface.
    reviewCommentList: vi.fn().mockRejectedValue(new Error("not used")),
    reviewCommentUpsert: vi.fn().mockRejectedValue(new Error("not used")),
    reviewCommentDelete: vi.fn().mockRejectedValue(new Error("not used")),
    reviewCommentsSend: vi.fn().mockRejectedValue(new Error("not used")),
    ...overrides,
  };
}

function pressEnter(input: HTMLInputElement, value: string): void {
  input.value = value;
  input.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
}

describe("EditorView — direct-path open (Fix A)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
  });

  it("Enter with a non-empty path reads it directly and opens it, with no error shown", async () => {
    const result: WorkspaceFileReadResult = { content: "export {}\n", sha256: "sha-1", size: 10 };
    const workspaceFileRead = vi.fn().mockResolvedValue(result);
    const bridge = makeBridge({ workspaceFileRead });
    new EditorView(container, bridge);

    const input = container.querySelector("input") as HTMLInputElement;
    pressEnter(input, "src/app/root.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("src/app/root.ts"));

    expect(container.querySelector(".msg.error")).toBeNull();
  });

  it("Enter with a path the bridge rejects notFound shows the error and leaves the field editable", async () => {
    const workspaceFileRead = vi
      .fn()
      .mockRejectedValue(new SpacesBridgeError("notFound", "No such file in the mock workspace: missing.ts"));
    const bridge = makeBridge({ workspaceFileRead });
    new EditorView(container, bridge);

    const input = container.querySelector("input") as HTMLInputElement;
    pressEnter(input, "missing.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("missing.ts"));

    const errorRow = await vi.waitFor(() => {
      const row = container.querySelector(".msg.error");
      expect(row).not.toBeNull();
      return row!;
    });
    expect(errorRow.textContent).toBe("No such file in the mock workspace: missing.ts");
    expect(input.disabled).toBe(false);
    expect(input.value).toBe("missing.ts");
  });

  it("degrades workspaceFileList's unavailable rejection to a quiet hint, and Enter-open still works", async () => {
    const result: WorkspaceFileReadResult = { content: "x", sha256: "sha-2", size: 1 };
    const workspaceFileRead = vi.fn().mockResolvedValue(result);
    const bridge = makeBridge({ workspaceFileRead }); // workspaceFileList defaults to rejecting unavailable
    new EditorView(container, bridge);

    const input = container.querySelector("input") as HTMLInputElement;
    input.value = "src";
    input.dispatchEvent(new Event("input", { bubbles: true }));

    const hintRow = await vi.waitFor(() => {
      const row = container.querySelector(".msg.hint");
      expect(row).not.toBeNull();
      return row!;
    });
    expect(hintRow.textContent).toMatch(/Return/);
    expect(container.querySelector(".msg.error")).toBeNull();

    // The always-available path still works even though search degraded.
    pressEnter(input, "src/app/root.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("src/app/root.ts"));
    expect(container.querySelector(".msg.error")).toBeNull();
  });
});

describe("EditorView — save conflict banner (Fix 3)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
  });

  async function openAndSave(
    bridge: SpacesBridge,
  ): Promise<{ saveBtn: HTMLButtonElement; banner: HTMLElement | null }> {
    const readResult: WorkspaceFileReadResult = { content: "export {}\n", sha256: "sha-1", size: 10 };
    (bridge.workspaceFileRead as ReturnType<typeof vi.fn>).mockResolvedValue(readResult);
    new EditorView(container, bridge);

    const input = container.querySelector("input") as HTMLInputElement;
    pressEnter(input, "src/app/root.ts");
    await vi.waitFor(() => expect(bridge.workspaceFileRead).toHaveBeenCalledWith("src/app/root.ts"));

    // Save starts disabled until the editor reports an edit (`onItemEditChange`, never fired here
    // since CodeView is faked out — see this file's top-level doc comment). That gate is unrelated to
    // what's under test, so it's bypassed directly rather than simulating an edit through the fake.
    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    saveBtn.disabled = false;
    saveBtn.click();
    await vi.waitFor(() => expect(bridge.workspaceFileWrite).toHaveBeenCalled());

    return { saveBtn, banner: container.querySelector(".banner.conflict") };
  }

  it("an ordinary hash-mismatch conflict shows the changed-on-disk message", async () => {
    const bridge = makeBridge({ workspaceFileWrite: vi.fn().mockResolvedValue({ conflict: true, currentSHA256: "new-sha" }) });

    const { banner } = await openAndSave(bridge);

    expect(banner).not.toBeNull();
    await vi.waitFor(() => expect(banner!.style.display).toBe("flex"));
    expect(banner!.textContent).toBe("File changed on disk — save disabled");
  });

  it("a fileMissing conflict shows the deleted-on-disk message, not the changed-on-disk one", async () => {
    const bridge = makeBridge({ workspaceFileWrite: vi.fn().mockResolvedValue({ conflict: true, fileMissing: true }) });

    const { banner } = await openAndSave(bridge);

    expect(banner).not.toBeNull();
    await vi.waitFor(() => expect(banner!.style.display).toBe("flex"));
    expect(banner!.textContent).toBe("File deleted on disk — save disabled");
  });
});

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
    new EditorView(container, bridge);

    const input = container.querySelector("input") as HTMLInputElement;
    pressEnter(input, "src/app/root.ts");
    await vi.waitFor(() => expect(bridge.workspaceFileRead).toHaveBeenCalledWith("src/app/root.ts"));
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

    const input = container.querySelector("input") as HTMLInputElement;
    pressEnter(input, "a.ts");
    await vi.waitFor(() => expect(bridge.workspaceFileRead).toHaveBeenCalledWith("a.ts"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "a content edited" });

    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    saveBtn.click();
    await vi.waitFor(() =>
      expect(bridge.workspaceFileWrite).toHaveBeenCalledWith("a.ts", "a content edited", { baseSHA256: "sha-a" }),
    );

    // B is opened (and wins) while A's write is still in flight. A is still `dirty` (the save
    // hasn't resolved yet), so this goes through the discard gate (round-13 Fix 1) rather than
    // opening directly.
    pressEnter(input, "b.ts");
    (container.querySelector(".banner.conflict button") as HTMLButtonElement).click();
    await vi.waitFor(() => expect(bridge.workspaceFileRead).toHaveBeenCalledWith("b.ts"));
    expect(saveBtn.disabled).toBe(true); // open()'s post-open state for B: nothing edited yet

    // A's write now fails. Same await-ordering guarantee as the sibling generation tests above:
    // save()'s own catch (registered on this promise back when it awaited it) fires before this
    // `.catch` continuation, so by the time this settles A's failure has already been dropped.
    rejectWrite(new SpacesBridgeError("unavailable", "daemon not reachable"));
    await writePromise.catch(() => {});

    expect(container.querySelector(".banner.error")).toBeNull();
    expect(saveBtn.disabled).toBe(true);
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({ path: "b.ts", baseSHA256: "sha-b", content: "b content", dirty: false }),
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
    new EditorView(container, bridge);

    const input = container.querySelector("input") as HTMLInputElement;
    pressEnter(input, "src/app/root.ts");
    await vi.waitFor(() => expect(bridge.workspaceFileRead).toHaveBeenCalledWith("src/app/root.ts"));

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
    const bridge = makeBridge({ workspaceFileRead, notifyEditorStateChanged });
    new EditorView(container, bridge);

    pressEnter(container.querySelector("input") as HTMLInputElement, "a.ts");
    await vi.waitFor(() =>
      expect(notifyEditorStateChanged).toHaveBeenCalledWith({
        path: "a.ts",
        baseSHA256: "sha-1",
        content: "hello\n",
        dirty: false,
      }),
    );
  });

  it("debounces the push on buffer edits, trailing ~500ms after the last edit", async () => {
    const result: WorkspaceFileReadResult = { content: "hello\n", sha256: "sha-1", size: 6 };
    const workspaceFileRead = vi.fn().mockResolvedValue(result);
    const notifyEditorStateChanged = vi.fn();
    const bridge = makeBridge({ workspaceFileRead, notifyEditorStateChanged });
    new EditorView(container, bridge);

    pressEnter(container.querySelector("input") as HTMLInputElement, "a.ts");
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
      content: "edited once",
      dirty: true,
    });
  });

  it("pushes immediately (not debounced) when a save succeeds, with dirty back to false", async () => {
    const readResult: WorkspaceFileReadResult = { content: "hello\n", sha256: "sha-1", size: 6 };
    const workspaceFileRead = vi.fn().mockResolvedValue(readResult);
    const workspaceFileWrite = vi.fn().mockResolvedValue({ ok: true, sha256: "sha-2" });
    const notifyEditorStateChanged = vi.fn();
    const bridge = makeBridge({ workspaceFileRead, workspaceFileWrite, notifyEditorStateChanged });
    new EditorView(container, bridge);

    pressEnter(container.querySelector("input") as HTMLInputElement, "a.ts");
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
        content: "edited",
        dirty: false,
      }),
    );
  });

  it("stays dirty when the user types again while the save is still in flight (round-7 Fix 1)", async () => {
    const readResult: WorkspaceFileReadResult = { content: "hello\n", sha256: "sha-1", size: 6 };
    const workspaceFileRead = vi.fn().mockResolvedValue(readResult);
    let resolveWrite: ((result: WorkspaceFileWriteResult) => void) | undefined;
    const workspaceFileWrite = vi.fn(() => new Promise<WorkspaceFileWriteResult>((resolve) => (resolveWrite = resolve)));
    const notifyEditorStateChanged = vi.fn();
    const bridge = makeBridge({ workspaceFileRead, workspaceFileWrite, notifyEditorStateChanged });
    new EditorView(container, bridge);

    pressEnter(container.querySelector("input") as HTMLInputElement, "a.ts");
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
        content: "edited, then more", // the buffer the user is looking at, which disk does not hold
        dirty: true, // stays dirty: the buffer moved on past what this save actually wrote
      }),
    );
    expect(saveBtn.disabled).toBe(false);
  });

  it("pushes immediately (not debounced) when a save conflicts, dirty staying true", async () => {
    const readResult: WorkspaceFileReadResult = { content: "hello\n", sha256: "sha-1", size: 6 };
    const workspaceFileRead = vi.fn().mockResolvedValue(readResult);
    const workspaceFileWrite = vi.fn().mockResolvedValue({ conflict: true, currentSHA256: "sha-remote" });
    const notifyEditorStateChanged = vi.fn();
    const bridge = makeBridge({ workspaceFileRead, workspaceFileWrite, notifyEditorStateChanged });
    new EditorView(container, bridge);

    pressEnter(container.querySelector("input") as HTMLInputElement, "a.ts");
    await vi.waitFor(() => expect(notifyEditorStateChanged).toHaveBeenCalledTimes(1));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "edited" });
    notifyEditorStateChanged.mockClear();

    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    saveBtn.disabled = false;
    saveBtn.click();
    await vi.waitFor(() =>
      expect(notifyEditorStateChanged).toHaveBeenCalledExactlyOnceWith({
        path: "a.ts",
        baseSHA256: "sha-1", // the conflicting write's sha256 is never adopted as the baseline
        content: "edited",
        dirty: true,
      }),
    );
  });
});

describe("EditorView — restoreState (round-5 hibernation fix)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    container = document.createElement("div");
  });

  it("a dirty snapshot restores the buffer and baseline directly, with no workspaceFileRead call", async () => {
    const workspaceFileRead = vi.fn().mockRejectedValue(new Error("must not be called for a dirty restore"));
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    await view.restoreState({ path: "a.ts", baseSHA256: "sha-dirty", content: "unsaved edits", dirty: true });

    expect(workspaceFileRead).not.toHaveBeenCalled();
    expect((container.querySelector("input") as HTMLInputElement).value).toBe("a.ts");
    expect((container.querySelector("button.primary") as HTMLButtonElement).disabled).toBe(false);
  });

  it("a clean snapshot re-reads the path from disk rather than trusting the stale copy", async () => {
    const result: WorkspaceFileReadResult = { content: "fresh from disk\n", sha256: "sha-fresh", size: 16 };
    const workspaceFileRead = vi.fn().mockResolvedValue(result);
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    await view.restoreState({ path: "a.ts", baseSHA256: "sha-old", content: "stale clean copy", dirty: false });

    expect(workspaceFileRead).toHaveBeenCalledWith("a.ts");
  });

  it("no snapshot leaves the editor blank, same as a pane's first-ever load", async () => {
    const workspaceFileRead = vi.fn();
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);

    await view.restoreState(undefined);

    expect(workspaceFileRead).not.toHaveBeenCalled();
    expect((container.querySelector("input") as HTMLInputElement).value).toBe("");
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
    new EditorView(container, bridge);

    pressEnter(container.querySelector("input") as HTMLInputElement, "a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts"));
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

  it("open(A) then open(B) before A resolves: resolving B then A leaves B's file open", async () => {
    const { workspaceFileRead, settle } = makeDeferredRead();
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);
    const input = container.querySelector("input") as HTMLInputElement;

    pressEnter(input, "a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts"));
    pressEnter(input, "b.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("b.ts"));

    settle["b.ts"]!.resolve({ content: "b content", sha256: "sha-b", size: 9 });
    await settle["b.ts"]!.promise;
    settle["a.ts"]!.resolve({ content: "a content", sha256: "sha-a", size: 9 });
    await settle["a.ts"]!.promise;

    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({ path: "b.ts", baseSHA256: "sha-b", content: "b content", dirty: false }),
    );
    expect(input.value).toBe("b.ts");
  });

  it("A's rejection after B already won surfaces no error banner and leaves B's state untouched", async () => {
    const { workspaceFileRead, settle } = makeDeferredRead();
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);
    const input = container.querySelector("input") as HTMLInputElement;

    pressEnter(input, "a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts"));
    pressEnter(input, "b.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("b.ts"));

    settle["b.ts"]!.resolve({ content: "b content", sha256: "sha-b", size: 9 });
    await settle["b.ts"]!.promise;

    // Settling A's own promise here (attached after open()'s internal await, which was attached
    // first) only resumes once open()'s catch block has already had its microtask turn — see this
    // block's use below for why that ordering is enough to prove the rejection was a no-op.
    settle["a.ts"]!.reject(new SpacesBridgeError("notFound", "a.ts is gone"));
    await settle["a.ts"]!.promise.catch(() => {});

    expect(container.querySelector(".msg.error")).toBeNull();
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({ path: "b.ts", baseSHA256: "sha-b", content: "b content", dirty: false }),
    );
    expect(input.value).toBe("b.ts");
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
    input: HTMLInputElement;
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

    const input = container.querySelector("input") as HTMLInputElement;
    pressEnter(input, "a.ts");
    await vi.waitFor(() => expect(bridge.workspaceFileRead).toHaveBeenCalledWith("a.ts"));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "a content edited" });

    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    saveBtn.click();
    await vi.waitFor(() =>
      expect(bridge.workspaceFileWrite).toHaveBeenCalledWith("a.ts", "a content edited", { baseSHA256: "sha-a" }),
    );

    return { view, input, saveBtn, resolveWrite, writePromise };
  }

  it("a successful write for A resolving after open(B) leaves B's baseline, dirty state, and save button untouched", async () => {
    const bridge = makeBridge();
    const { view, input, saveBtn, resolveWrite, writePromise } = await openEditSaveA(bridge);

    // B is opened (and wins) while A's write is still in flight. A is still `dirty` (the save
    // hasn't resolved yet), so this goes through the discard gate (round-13 Fix 1) rather than
    // opening directly.
    pressEnter(input, "b.ts");
    (container.querySelector(".banner.conflict button") as HTMLButtonElement).click();
    await vi.waitFor(() => expect(bridge.workspaceFileRead).toHaveBeenCalledWith("b.ts"));
    expect(input.value).toBe("b.ts");
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
      JSON.stringify({ path: "b.ts", baseSHA256: "sha-b", content: "b content", dirty: false }),
    );
    expect(saveBtn.disabled).toBe(true);
    expect((container.querySelector(".banner.conflict") as HTMLElement).style.display).toBe("none");
  });

  it("a conflicting write for A resolving after open(B) shows no conflict banner over B and leaves its save button untouched", async () => {
    const bridge = makeBridge();
    const { view, input, saveBtn, resolveWrite, writePromise } = await openEditSaveA(bridge);

    // A is still `dirty` (the save hasn't resolved yet), so this goes through the discard gate
    // (round-13 Fix 1) rather than opening directly.
    pressEnter(input, "b.ts");
    (container.querySelector(".banner.conflict button") as HTMLButtonElement).click();
    await vi.waitFor(() => expect(bridge.workspaceFileRead).toHaveBeenCalledWith("b.ts"));
    expect(saveBtn.disabled).toBe(true);

    resolveWrite({ conflict: true, currentSHA256: "sha-remote" });
    await writePromise;

    // B's own state (not A's) is untouched by A's conflict: no banner, save button still reflects
    // B's post-open state, and the baseline/dirty snapshot is still B's, not marked conflicted.
    expect((container.querySelector(".banner.conflict") as HTMLElement).style.display).toBe("none");
    expect(saveBtn.disabled).toBe(true);
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({ path: "b.ts", baseSHA256: "sha-b", content: "b content", dirty: false }),
    );
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
  async function openAndEdit(bridge: SpacesBridge, path: string): Promise<void> {
    const input = container.querySelector("input") as HTMLInputElement;
    pressEnter(input, path);
    await vi.waitFor(() => expect(bridge.workspaceFileRead).toHaveBeenCalledWith(path));
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: `${path} content edited` });
  }

  it("Return on a new path while dirty does not open it, and shows the discard banner", async () => {
    const { bridge, workspaceFileRead } = makePerPathBridge();
    new EditorView(container, bridge);
    await openAndEdit(bridge, "a.ts");
    workspaceFileRead.mockClear();

    const input = container.querySelector("input") as HTMLInputElement;
    pressEnter(input, "b.ts");

    expect(workspaceFileRead).not.toHaveBeenCalledWith("b.ts");
    const banner = container.querySelector(".banner.conflict") as HTMLElement;
    expect(banner).not.toBeNull();
    expect(banner.style.display).toBe("flex");
    expect(banner.firstChild?.textContent).toBe("Unsaved changes in a.ts. Save them first, or discard them to open b.ts.");
    expect(banner.querySelector("button")!.textContent).toBe("Discard edits and open");
  });

  it("a search-suggestion click while dirty is gated the same way as Return", async () => {
    const { bridge, workspaceFileRead } = makePerPathBridge();
    const bridgeWithSearch = makeBridge({
      workspaceFileRead: bridge.workspaceFileRead,
      workspaceFileWrite: bridge.workspaceFileWrite,
      workspaceFileList: vi.fn().mockResolvedValue({ paths: ["b.ts"] }),
    });
    new EditorView(container, bridgeWithSearch);
    await openAndEdit(bridgeWithSearch, "a.ts");
    workspaceFileRead.mockClear();

    const input = container.querySelector("input") as HTMLInputElement;
    input.value = "b";
    input.dispatchEvent(new Event("input", { bubbles: true }));
    const opt = await vi.waitFor(() => {
      const row = container.querySelector(".opt");
      expect(row).not.toBeNull();
      return row as HTMLElement;
    });
    opt.click();

    expect(bridgeWithSearch.workspaceFileRead).not.toHaveBeenCalledWith("b.ts");
    const banner = container.querySelector(".banner.conflict") as HTMLElement;
    expect(banner.style.display).toBe("flex");
    expect(banner.textContent).toContain("discard them to open b.ts");
  });

  it("clicking the discard action opens the requested file and clears dirty", async () => {
    const { bridge, workspaceFileRead } = makePerPathBridge();
    new EditorView(container, bridge);
    await openAndEdit(bridge, "a.ts");

    const input = container.querySelector("input") as HTMLInputElement;
    pressEnter(input, "b.ts");
    const banner = container.querySelector(".banner.conflict") as HTMLElement;
    const discardBtn = banner.querySelector("button") as HTMLButtonElement;
    discardBtn.click();

    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("b.ts"));
    expect(input.value).toBe("b.ts");
    expect(banner.style.display).toBe("none"); // open()'s success path hides the banner
    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    expect(saveBtn.disabled).toBe(true); // dirty cleared, nothing edited in b.ts yet
  });

  it("saving first, then Return on a different path, opens it directly with no gate", async () => {
    const { bridge, workspaceFileRead, workspaceFileWrite } = makePerPathBridge();
    new EditorView(container, bridge);
    await openAndEdit(bridge, "a.ts");

    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    saveBtn.click();
    await vi.waitFor(() => expect(workspaceFileWrite).toHaveBeenCalled());
    // The save clears dirty, so the gate no longer applies.
    workspaceFileRead.mockClear();

    const input = container.querySelector("input") as HTMLInputElement;
    pressEnter(input, "b.ts");

    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("b.ts"));
    expect(input.value).toBe("b.ts");
    expect(container.querySelector(".banner.conflict")?.textContent ?? "").not.toContain("Unsaved changes");
  });

  it("restoreState's clean-branch path bypasses openGated's own pre-check gate, but a genuinely dirty buffer still gets open()'s completion-time protection (round-15 Fix A)", async () => {
    // restoreState's doc comment guarantees it only ever runs "before anything else touches this
    // view," so real dirty state can never actually be present when its clean branch fires — but
    // this proves the generalized invariant defensively: `open()`'s own completion recheck (Bug A's
    // fix) doesn't care which caller reached it, only whether the buffer is actually dirty. So
    // restoreState calling `open()` directly (never through `openGated`, hence still "unaffected by
    // the gate" in the sense this test's name describes) still gets the read started unconditionally
    // — unlike openGated's fast path, which would have skipped the read entirely — while the
    // completion recheck refuses to silently clobber a dirty buffer no matter who asked for the open.
    const { bridge, workspaceFileRead } = makePerPathBridge();
    const view = new EditorView(container, bridge);
    await openAndEdit(bridge, "a.ts"); // dirty is now true

    await view.restoreState({ path: "b.ts", baseSHA256: "sha-old", content: "stale", dirty: false });

    // The read still runs (restoreState's call bypassed openGated's pre-check), but the completion
    // recheck refuses to commit it over A's dirty buffer, raising the discard banner instead.
    expect(workspaceFileRead).toHaveBeenCalledWith("b.ts");
    expect((container.querySelector("input") as HTMLInputElement).value).toBe("a.ts");
    expect((container.querySelector(".banner.conflict") as HTMLElement).style.display).toBe("flex");
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({ path: "a.ts", baseSHA256: `sha-a.ts`, content: "a.ts content edited", dirty: true }),
    );
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

  it("Bug A: the current buffer going dirty WHILE a different open's read is in flight raises the banner at completion instead of clobbering it", async () => {
    const { workspaceFileRead, settle } = makeDeferredRead();
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);
    const input = container.querySelector("input") as HTMLInputElement;

    // Open A cleanly.
    pressEnter(input, "a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts"));
    settle["a.ts"]!.resolve({ content: "a content", sha256: "sha-a", size: 9 });
    await settle["a.ts"]!.promise;

    // A is clean, so openGated's upfront check lets B's open proceed directly — no banner yet.
    pressEnter(input, "b.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("b.ts"));
    expect((container.querySelector(".banner.conflict") as HTMLElement).style.display).toBe("none");

    // While B's read is in flight, the user types into A (still the loaded buffer — B hasn't
    // landed). openGated's upfront check ran before this happened, so only open()'s completion-time
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
      JSON.stringify({ path: "a.ts", baseSHA256: "sha-a", content: "a content edited", dirty: true }),
    );

    // Clicking discard commits it: a fresh read for B (the earlier one already resolved and was
    // discarded by the recheck above), landing with `discard: true` so this completion isn't
    // re-litigated as its own conflict.
    (banner.querySelector("button") as HTMLButtonElement).click();
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledTimes(3)); // a.ts, b.ts, b.ts again
    settle["b.ts"]!.resolve({ content: "b content v2", sha256: "sha-b2", size: 12 });
    await settle["b.ts"]!.promise;

    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({ path: "b.ts", baseSHA256: "sha-b2", content: "b content v2", dirty: false }),
    );
    expect((container.querySelector("button.primary") as HTMLButtonElement).disabled).toBe(true);
    expect(banner.style.display).toBe("none");
  });

  it("Bug B (success): clicking discard does not touch the old buffer until the reopen actually succeeds", async () => {
    const { workspaceFileRead, settle } = makeDeferredRead();
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);
    const input = container.querySelector("input") as HTMLInputElement;

    pressEnter(input, "a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts"));
    settle["a.ts"]!.resolve({ content: "a content", sha256: "sha-a", size: 9 });
    await settle["a.ts"]!.promise;
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "a content edited" });

    pressEnter(input, "b.ts"); // dirty: gated, banner shown, no read yet
    const banner = container.querySelector(".banner.conflict") as HTMLElement;
    expect(banner.style.display).toBe("flex");
    (banner.querySelector("button") as HTMLButtonElement).click(); // discard: read for b.ts starts, held
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("b.ts"));

    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    // While the reopen is held, nothing about A's buffer has moved: the discard is committed only
    // once open() actually succeeds, not at click time.
    expect(saveBtn.disabled).toBe(false);
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({ path: "a.ts", baseSHA256: "sha-a", content: "a content edited", dirty: true }),
    );

    settle["b.ts"]!.resolve({ content: "b content", sha256: "sha-b", size: 9 });
    await settle["b.ts"]!.promise;

    expect(input.value).toBe("b.ts");
    expect(saveBtn.disabled).toBe(true);
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({ path: "b.ts", baseSHA256: "sha-b", content: "b content", dirty: false }),
    );
  });

  it("Bug B (failure): a reopen that fails after discard leaves the old buffer dirty and Save enabled, not silently marked clean", async () => {
    const { workspaceFileRead, settle } = makeDeferredRead();
    const bridge = makeBridge({ workspaceFileRead });
    const view = new EditorView(container, bridge);
    const input = container.querySelector("input") as HTMLInputElement;

    pressEnter(input, "a.ts");
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("a.ts"));
    settle["a.ts"]!.resolve({ content: "a content", sha256: "sha-a", size: 9 });
    await settle["a.ts"]!.promise;
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "a content edited" });

    pressEnter(input, "b.ts");
    const banner = container.querySelector(".banner.conflict") as HTMLElement;
    (banner.querySelector("button") as HTMLButtonElement).click();
    await vi.waitFor(() => expect(workspaceFileRead).toHaveBeenCalledWith("b.ts"));

    settle["b.ts"]!.reject(new SpacesBridgeError("notFound", "no such file: b.ts"));
    await settle["b.ts"]!.promise.catch(() => {});

    const saveBtn = container.querySelector("button.primary") as HTMLButtonElement;
    // Nothing was silently marked clean by the failed discard attempt: A's path, content, baseline,
    // and dirty flag are exactly what they were before the click, and Save is still enabled.
    expect(saveBtn.disabled).toBe(false);
    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({ path: "a.ts", baseSHA256: "sha-a", content: "a content edited", dirty: true }),
    );
    // The failed reopen renders its own factual error, same as any other failed open().
    expect(container.querySelector(".msg.error")).not.toBeNull();
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
    const bridge = makeBridge({ workspaceFileRead, notifyEditorStateChanged });
    const view = new EditorView(container, bridge);

    pressEnter(container.querySelector("input") as HTMLInputElement, "a.ts");
    await vi.waitFor(() => expect(notifyEditorStateChanged).toHaveBeenCalledTimes(1));
    notifyEditorStateChanged.mockClear();

    vi.useFakeTimers();
    // A buffer edit inside the ~500ms debounce window: nothing has been pushed
    // to notifyEditorStateChanged yet, but the synchronous flush pull must see it anyway.
    capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: "edited, not yet pushed" });
    expect(notifyEditorStateChanged).not.toHaveBeenCalled();

    expect(view.collectStateForFlush()).toBe(
      JSON.stringify({ path: "a.ts", baseSHA256: "sha-1", content: "edited, not yet pushed", dirty: true }),
    );
  });
});
