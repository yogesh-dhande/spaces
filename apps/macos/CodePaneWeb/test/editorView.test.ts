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
