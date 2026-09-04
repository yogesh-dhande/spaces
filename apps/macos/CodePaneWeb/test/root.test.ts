import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createTwoFilesPatch } from "diff";
import { DIFF_EDIT_INPUT_ID, DiffView } from "../src/app/diffView";
import { mountRoot as mountRootDirect } from "../src/app/root";
import type { CodePaneRootHandle } from "../src/app/root";
import {
  CodePaneDiffEditorState,
  CodePaneEditorState,
  CodePaneInitPayload,
  CodePaneWorkspaceState,
  DiffFileEntry,
  PendingReviewCommentEntry,
  SpacesBridgeError,
  WorkspaceDiffFileChunkResult,
} from "../src/bridge/types";

// Captures the options the most recently constructed (fake) CodeView was built with — DiffView and
// EditorView share the same `CodeView` class, but only EditorView's instance ever exercises
// `onItemEditChange` (Finding C's tests dirty the editor buffer this way, the same technique
// editorView.test.ts's own `capturedCodeViewOptions` uses). EditorView constructs its CodeView
// lazily, on the first successful open (see `ensureCodeView`), which is always after DiffView's own
// construction at mount — so by the time a test needs it, `.current` is the editor's instance.
const capturedCodeViewOptions = vi.hoisted(() => ({
  current: undefined as
    | undefined
    | {
        onItemEditChange: (item: { id?: string; type?: string } | undefined, file: { contents: string }) => void;
        onLineClick?: (event: { type: "diff-line"; lineNumber: number; annotationSide?: string }, context: { type: string; item: { id: string } }) => void;
        renderHeaderMetadata?: (file: { name: string }) => HTMLElement | undefined;
        onPostRender?: (node: HTMLElement, ...args: unknown[]) => void;
      },
  scrollCalls: [] as unknown[],
  selectedLineCalls: [] as unknown[],
}));

// mountRoot pulls in DiffView and EditorView, both of which construct a real
// `@pierre/diffs` CodeView on non-empty content — replaced with a no-op fake
// here since these tests are about root.ts's own stale-response guard (Fix
// B), not the diff-rendering library. Every other export passes through.
vi.mock("@pierre/diffs", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@pierre/diffs")>();
  class FakeCodeView {
    constructor(options: { onItemEditChange: (item: unknown, file: { contents: string }) => void }) {
      capturedCodeViewOptions.current = options;
    }
    setup(): void {}
    setItems(): void {}
    setOptions(): void {}
    getScrollTop(): number {
      return 0;
    }
    scrollTo(input: unknown): void {
      capturedCodeViewOptions.scrollCalls.push(input);
    }
    cleanUp(): void {}
    // Models an attach that completed instantly so `completeEditorAttach`'s poll resolves
    // on its first frame (see the matching fake in editorView.test.ts).
    getEditor(): object {
      return {};
    }
    updateItem(): void {}
    addItem(): void {}
    setSelectedLines(input: unknown): void {
      capturedCodeViewOptions.selectedLineCalls.push(input);
    }
    clearSelectedLines(): void {
      capturedCodeViewOptions.selectedLineCalls.push(null);
    }
  }
  return { ...actual, CodeView: FakeCodeView };
});
vi.mock("@pierre/diffs/edit", () => ({
  Editor: class {},
}));

// jsdom has no ResizeObserver; mountRoot's file-list divider observes the pane with one
// (fileListDivider.ts). These tests don't exercise resize behavior — see fileListDivider.test.ts.
vi.stubGlobal(
  "ResizeObserver",
  class {
    observe(): void {}
    unobserve(): void {}
    disconnect(): void {}
  },
);

// jsdom has no scrollIntoView; the Files tree's FilesTreeHandle.setSelected calls it on every
// selection change (opening a file via the Files tree, or via ⌘P quick-open, in Editor mode).
Element.prototype.scrollIntoView = function scrollIntoView(): void {};

/** The production scheduler waits for two actual browser frames before starting patch transport.
 * These retry tests use fake timers for seconds-long backoff, so make those paint frames explicit
 * microtasks rather than leaving their promises parked behind a synthetic 16ms RAF clock. */
const nativeRequestAnimationFrame = window.requestAnimationFrame;
function useFakeTimersWithImmediatePaint(): void {
  vi.useFakeTimers();
  window.requestAnimationFrame = (callback) => {
    queueMicrotask(() => callback(performance.now()));
    return 0;
  };
}
/** Every root this file mounts, as the pending mount itself rather than the resolved handle. A
 *  mounted root owns window listeners, a signature subscription, retry timers, and its autosave
 *  schedulers, none of which the container element holds; without the teardown below, a finished
 *  test's root keeps writing files and answering host events while the next one runs. Registering
 *  the promise (not the handle) is what covers a root left mid-initialization: several tests
 *  deliberately never settle the first manifest pull, and such a root has already attached every
 *  window listener by the time it reaches that await. */
const mountedRoots: Array<{ mounted: ReturnType<typeof mountRootDirect>; handle?: CodePaneRootHandle }> = [];

/** The single entry point every test in this file mounts through, so no call site can forget to
 *  register its root for teardown. */
function mountRoot(container: HTMLElement): ReturnType<typeof mountRootDirect> {
  const entry: { mounted: ReturnType<typeof mountRootDirect>; handle?: CodePaneRootHandle } = { mounted: mountRootDirect(container) };
  entry.mounted.then(
    (handle) => {
      entry.handle = handle;
    },
    () => {},
  );
  mountedRoots.push(entry);
  return entry.mounted;
}

afterEach(async () => {
  const entries = mountedRoots.splice(0);
  if (entries.some((entry) => entry.handle === undefined)) {
    // A root parked on a manifest pull the test never settled has to finish initializing before it
    // can hand over its dispose handle, so release what it is waiting on. This runs only when such
    // a root exists: rejecting a live root's in-flight pull would send it into a retry it schedules
    // after this teardown has already disposed it.
    for (const call of hoisted.pendingDiffCalls.splice(0)) call.reject(new Error("root.test.ts teardown"));
    await Promise.allSettled(entries.map((entry) => entry.mounted));
  }
  for (const entry of entries) entry.handle?.dispose();
  // Restored after the awaits above, not before: a test that ended with fake timers installed still
  // needs the immediate-paint frames to drive that last stretch of initialization to completion.
  window.requestAnimationFrame = nativeRequestAnimationFrame;
});

// Mutable (not `const`) so Fix 1's describe block below can substitute a payload carrying a dirty
// `editorState` for its one test, then restore the default afterward — the bridge mock's
// `notifyReady` reads this binding at call time, not at module-evaluation time, so reassigning it
// before `mountRoot` is called is enough; no `vi.hoisted` indirection needed.
let INIT_PAYLOAD: CodePaneInitPayload = {
  workspaceId: "w1",
  workspaceName: "Test workspace",
  workspaceState: {
    mode: "diff",
    scope: { kind: "uncommitted" },
    diffLayout: "unified",
    editorSidebarMode: "files",
    editorRecentPaths: [],
    selectedAgentSessionId: null,
    pendingAgentLaunch: null,
    fileTreeExpandedPaths: [],
    diffSelectedPath: null,
    diffTreeSelectedPath: null,
    fileTreeSelectedPath: null,
    diffScrollLine: null,
    diffScrollSide: null,
    diffFocusedPath: null,
    diffFocusedLine: null,
    diffFocusedSide: null,
    editorScrollLine: null,
    editorFocusedLine: null,
    editorState: null,
    diffEditorState: null,
    pendingReviewComments: null,
  },
  theme: "dark",
  // Badges the compare dialog's base-branch entry; not exercised by most of this file's tests,
  // which use the compare menu's "Last commit" item purely as a scope-switch trigger (Fix B is
  // about stale-response ordering, not about which scope is picked).
  baseBranch: "main",
  // No running agents: these tests exercise refreshDiff's own logic, not the comment surface (see
  // test/commentsController.test.ts and test/reviewComments.test.ts for that).
  agents: [],
};

// vi.mock factories are hoisted above every import in this file, so the state
// they close over has to come from vi.hoisted rather than a plain top-level
// const — this is the "controllable promise resolution" mock bridge Fix B's
// tests need: each workspaceDiff call is held open until the test resolves
// or rejects it explicitly, in whatever order the test chooses.
const hoisted = vi.hoisted(() => {
  const pendingDiffCalls: Array<{
    resolve: (result: { scopeSignature: string; files: unknown[] }) => void;
    reject: (error: unknown) => void;
  }> = [];
  const workspaceDiff = vi.fn((_scope: unknown) => new Promise((resolve, reject) => pendingDiffCalls.push({ resolve, reject })));
  const notifyModeChanged = vi.fn();
  // Controllable the same way `workspaceDiff` above is: defaults to the same permanent rejection
  // every other not-under-test bridge method uses, but a test that exercises the Files tab or the
  // ⌘P overlay's full-listing search can `mockResolvedValueOnce` a real listing on top of that
  // default without leaking it into any other test (see the Files/Changes sidebar describe block).
  const workspaceFileList = vi.fn().mockRejectedValue(new Error("not used"));
  // Controllable the same way: defaults to the same permanent rejection every other
  // not-under-test bridge method uses, but the Files/Changes sidebar describe block's recent-files
  // tests (Finding C) need a real open to actually complete, so they configure a per-test resolution
  // instead of relying on the default.
  const workspaceFileRead = vi.fn().mockRejectedValue(new Error("not used"));
  // Last Commit inline editing verifies the live file against the immutable revision pinned in
  // the streamed file metadata before it permits a write surface.
  const workspaceRevisionFileRead = vi.fn().mockRejectedValue(new Error("not used"));
  const workspaceRefList = vi.fn().mockResolvedValue({
    branches: ["main"],
    branchesTruncated: false,
    commits: [],
    commitsTruncated: false,
  });
  // Captures every push so a test can assert on the exact `CodePaneEditorUIState` sent — see the
  // Files/Changes sidebar describe block's recent-files and sidebarMode-toggle coverage.
  const notifyEditorUIStateChanged = vi.fn();
  const notifyWorkspaceStateChanged = vi.fn((state: unknown) => {
    const workspaceState = state as { mode: string; editorSidebarMode: string; editorRecentPaths: string[] };
    notifyModeChanged(workspaceState.mode);
    notifyEditorUIStateChanged({ sidebarMode: workspaceState.editorSidebarMode, recentPaths: workspaceState.editorRecentPaths });
  });
  const notifyRenderMetric = vi.fn();
  const notifyEditsFlushed = vi.fn();
  const reviewCommentList = vi.fn().mockResolvedValue([]);
  const workspaceFileWrite = vi.fn().mockRejectedValue(new Error("not used"));
  const startWorkspaceCommand = vi.fn().mockResolvedValue({
    sessionId: "command-1",
    status: "starting" as const,
    deadlineEpochMilliseconds: 90_000,
  });
  const resumeWorkspaceCommandTracking = vi.fn().mockResolvedValue({
    sessionId: "command-1",
    status: "starting" as const,
    deadlineEpochMilliseconds: 90_000,
  });
  const manifests = new Map<string, { scopeSignature: string; files: DiffFileEntry[] }>();
  let nextManifestID = 0;
  let manifestPageSize = Number.POSITIVE_INFINITY;
  const workspaceDiffManifestChunk = vi.fn((scope: unknown, request: { manifestID?: string; fileIndex: number }) =>
    {
      const page = (manifestID: string, manifest: { scopeSignature: string; files: DiffFileEntry[] }) => {
        const files = manifest.files.slice(request.fileIndex, request.fileIndex + manifestPageSize);
        return {
          manifestID,
          scopeSignature: manifest.scopeSignature,
          files: files.map(({ path, oldPath, status }) => ({ path, oldPath, status })),
          nextFileIndex: request.fileIndex + files.length < manifest.files.length ? request.fileIndex + files.length : undefined,
        };
      };
      if (request.manifestID !== undefined) {
        const manifest = manifests.get(request.manifestID);
        if (!manifest) return Promise.reject(new Error("missing manifest"));
        return Promise.resolve(page(request.manifestID, manifest));
      }
      if (request.fileIndex !== 0) throw new Error("initial metadata page must start at index zero");
      return workspaceDiff(scope).then((raw: unknown) => {
        const result = raw as { scopeSignature: string; files: DiffFileEntry[] };
        const manifestID = `test-manifest-${++nextManifestID}`;
        const manifest = { scopeSignature: result.scopeSignature, files: result.files };
        manifests.set(manifestID, manifest);
        return page(manifestID, manifest);
      });
    },
  );
  const workspaceDiffFileChunk = vi.fn((_scope: unknown, request: { manifestID: string; relativePath: string }): Promise<WorkspaceDiffFileChunkResult> => {
    const manifest = manifests.get(request.manifestID);
    const file = manifest?.files.find((entry) => entry.path === request.relativePath);
    if (file && manifest) {
      return Promise.resolve({
        scopeSignature: manifest.scopeSignature,
        file,
        // The production scheduler assembles patch bytes from this transport field; include the
        // fixture's actual patch so inline hydration tests exercise reverse reconstruction rather
        // than an empty patch accidentally rescued by a fallback.
        patchBase64Data: file.patch === undefined ? undefined : btoa(file.patch),
      });
    }
    return Promise.reject(new Error(`missing manifest file ${request.relativePath}`));
  });
  const workspaceDiffManifestRelease = vi.fn((_scope: unknown, request: { manifestID: string }) => {
    manifests.delete(request.manifestID);
    return Promise.resolve();
  });
  // round-16 Fix 1: captures every `subscribeDiffSignature` callback root.ts registers, in order,
  // so a test can simulate a diff-signature push event by invoking one directly — mirroring
  // `pendingDiffCalls`' "controllable" approach for `workspaceDiff` above, but for the push side.
  // `resubscribeDiffSignature` replaces the previous subscription on every scope change, so the
  // LAST entry is always the one a real push would currently be delivered to.
  const diffSignatureCallbacks: Array<() => void> = [];
  const subscribeDiffSignature = vi.fn((_scope: unknown, callback: () => void) => {
    diffSignatureCallbacks.push(callback);
    return () => {};
  });
  const fileListSignatureCallbacks: Array<() => void> = [];
  const subscribeFileListSignature = vi.fn((callback: () => void) => {
    fileListSignatureCallbacks.push(callback);
    return () => {};
  });
  return {
    pendingDiffCalls,
    workspaceDiff,
    workspaceDiffManifestChunk,
    setManifestPageSize: (size: number) => {
      manifestPageSize = size;
    },
    workspaceDiffFileChunk,
    workspaceDiffManifestRelease,
    workspaceFileList,
    workspaceFileRead,
    workspaceRevisionFileRead,
    workspaceRefList,
    workspaceFileWrite,
    startWorkspaceCommand,
    resumeWorkspaceCommandTracking,
    notifyModeChanged,
    notifyEditorUIStateChanged,
    notifyWorkspaceStateChanged,
    notifyRenderMetric,
    notifyEditsFlushed,
    reviewCommentList,
    diffSignatureCallbacks,
    fileListSignatureCallbacks,
    subscribeDiffSignature,
    subscribeFileListSignature,
  };
});

vi.mock("../src/bridge", () => ({
  createBridge: async () => ({
    notifyReady: () => {
      queueMicrotask(() => {
        window.dispatchEvent(new CustomEvent("spaces:init", { detail: INIT_PAYLOAD }));
      });
    },
    workspaceDiffManifestChunk: hoisted.workspaceDiffManifestChunk,
    workspaceDiffFileChunk: hoisted.workspaceDiffFileChunk,
    workspaceDiffFileChunkCancel: vi.fn().mockResolvedValue(undefined),
    workspaceDiffManifestRelease: hoisted.workspaceDiffManifestRelease,
    workspaceFileRead: hoisted.workspaceFileRead,
    workspaceRevisionFileRead: hoisted.workspaceRevisionFileRead,
    workspaceRefList: hoisted.workspaceRefList,
    workspaceFileWrite: hoisted.workspaceFileWrite,
    workspaceFileList: hoisted.workspaceFileList,
    subscribeDiffSignature: hoisted.subscribeDiffSignature,
    subscribeFileListSignature: hoisted.subscribeFileListSignature,
    subscribeFileSignature: vi.fn(() => () => {}),
    notifyWorkspaceStateChanged: hoisted.notifyWorkspaceStateChanged,
    notifyRenderMetric: hoisted.notifyRenderMetric,
    notifyEditsFlushed: hoisted.notifyEditsFlushed,
    reviewCommentList: hoisted.reviewCommentList,
    reviewCommentUpsert: vi.fn().mockRejectedValue(new Error("not used")),
    reviewCommentDelete: vi.fn().mockRejectedValue(new Error("not used")),
    reviewCommentsSend: vi.fn().mockRejectedValue(new Error("not used")),
    startWorkspaceCommand: hoisted.startWorkspaceCommand,
    resumeWorkspaceCommandTracking: hoisted.resumeWorkspaceCommandTracking,
  }),
}));

function makeFile(path: string): DiffFileEntry {
  // isBinary skips patch parsing entirely (buildItem short-circuits to a
  // placeholder item), which keeps these tests independent of the diff patch
  // format — they only care which scope's file list won.
  return { path, status: "modified", isBinary: true };
}

function resolveDiff(index: number, files: DiffFileEntry[], signature: string): void {
  hoisted.pendingDiffCalls[index]!.resolve({ scopeSignature: signature, files });
}

function rejectDiff(index: number, error: unknown): void {
  hoisted.pendingDiffCalls[index]!.reject(error);
}

function clickButton(container: HTMLElement, label: string): void {
  const button = [...container.querySelectorAll("button")].find((b) => b.textContent === label);
  if (!button) throw new Error(`no button labeled "${label}"`);
  button.click();
}

/** Switches the diff pane to the "Last commit" scope via the compare menu — these tests use it
 *  purely as a trigger for a second, distinct scope (most of them are about refreshDiff's
 *  request-ordering behavior, not about which scope is picked). Scoped selectors (rather than
 *  `clickButton`'s label match) because the compare button's own label is "Uncommitted" too when
 *  that's the current scope, same as the menu item it opens. */
function switchToLastCommit(container: HTMLElement): void {
  const compareBtn = container.querySelector(".compare-btn");
  if (!compareBtn) throw new Error("no .compare-btn found");
  (compareBtn as HTMLButtonElement).click();

  const item = [...container.querySelectorAll<HTMLButtonElement>(".compare-menu .item")].find(
    (el) => el.textContent === "Last commit",
  );
  if (!item) throw new Error("no 'Last commit' compare menu item found");
  item.click();
}

function switchToUncommitted(container: HTMLElement): void {
  const compareBtn = container.querySelector(".compare-btn");
  if (!compareBtn) throw new Error("no .compare-btn found");
  (compareBtn as HTMLButtonElement).click();
  const item = [...container.querySelectorAll<HTMLButtonElement>(".compare-menu .item")].find(
    (el) => el.textContent === "Uncommitted",
  );
  if (!item) throw new Error("no 'Uncommitted' compare menu item found");
  item.click();
}

/** Simulates a diff-signature push event on whichever scope is currently subscribed (see
 *  `hoisted.diffSignatureCallbacks`'s doc comment). */
function fireDiffSignature(): void {
  const callbacks = hoisted.diffSignatureCallbacks;
  if (callbacks.length === 0) throw new Error("no diff-signature subscription registered yet");
  callbacks[callbacks.length - 1]!();
}

function fireFileListSignature(): void {
  const callbacks = hoisted.fileListSignatureCallbacks;
  if (callbacks.length === 0) throw new Error("no file-list-signature subscription registered yet");
  callbacks[callbacks.length - 1]!();
}

describe("mountRoot's diff render metrics", () => {
  const defaultInitPayload = INIT_PAYLOAD;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.notifyRenderMetric.mockClear();
    INIT_PAYLOAD = defaultInitPayload;
  });

  afterEach(() => {
    INIT_PAYLOAD = defaultInitPayload;
  });

  it("does not report the background diff refresh while the diff view is detached in Editor mode", async () => {
    const container = document.createElement("div");
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));

    window.dispatchEvent(new CustomEvent("spaces:setMode", { detail: { mode: "editor" } }));
    resolveDiff(0, [makeFile("background.ts")], "sig-background");
    await mounted;
    await new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));

    // Workspace-state recovery is independently observable. A detached background refresh must
    // not claim a visible per-file patch paint.
    expect(hoisted.notifyRenderMetric.mock.calls.map(([metric]) => (metric as { trigger: string }).trigger)).not.toContain(
      "filePatch",
    );
    // This file intentionally retains mounted panes between tests; restore this pane so its global
    // mode listener cannot perturb the later setMode no-op coverage.
    window.dispatchEvent(new CustomEvent("spaces:setMode", { detail: { mode: "diff" } }));
  });
});

describe("mountRoot's configured base preset", () => {
  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.workspaceRefList.mockClear();
  });

  it("uses the origin-prefixed ref when the configured base is remote-only", async () => {
    hoisted.workspaceRefList.mockResolvedValueOnce({
      branches: ["origin/main"],
      branchesTruncated: false,
      commits: [],
      commitsTruncated: false,
    });
    const container = document.createElement("div");
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [], "sig-initial");
    await mounted;

    const compareButton = container.querySelector<HTMLButtonElement>(".compare-btn");
    expect(compareButton).not.toBeNull();
    compareButton!.click();
    const preset = [...container.querySelectorAll<HTMLButtonElement>(".compare-menu .item")].find(
      (item) => item.textContent === "vs main",
    );
    expect(preset).not.toBeUndefined();
    preset!.click();

    await vi.waitFor(() => expect(hoisted.workspaceRefList).toHaveBeenCalledTimes(1));
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    expect(hoisted.workspaceDiff.mock.calls[1]![0]).toEqual({ kind: "ref", refName: "origin/main" });
    resolveDiff(1, [], "sig-origin-main");
  });
});

describe("mountRoot's refreshDiff — stale-response guard (Fix B)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.notifyModeChanged.mockClear();
    hoisted.notifyRenderMetric.mockClear();
    container = document.createElement("div");
  });

  it("a slow scope-A reply that resolves after scope-B cannot overwrite B's file list", async () => {
    const mounted = mountRoot(container);
    // The initial refreshDiff (scope A, "uncommitted") is issued synchronously
    // off the spaces:init round trip, and mountRoot awaits it before
    // returning — so it's deliberately left pending here rather than awaited.
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));

    // round-16 Fix 1: with scope A's pull still in flight, a scope switch to B no longer fires a
    // second concurrent request — it coalesces into a single trailing pull (see the round-16
    // describe blocks below for direct coverage of that coalescing), so this stays at 1 call.
    switchToLastCommit(container); // dispatches setScope -> refreshDiff (scope B), coalesced
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1);

    // Resolve the stale scope-A reply: superseded by the coalesce's token bump, so it must not
    // render — and its settling is what fires the trailing pull for scope B.
    resolveDiff(0, [makeFile("a.ts")], "sig-a");
    await mounted; // scope A's own refreshDiff call settles once resolved, letting mountRoot return
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2)); // trailing pull for B

    resolveDiff(1, [makeFile("b.ts")], "sig-b");
    await vi.waitFor(() => expect(container.textContent).toContain("b.ts"));

    expect(container.textContent).not.toContain("a.ts");
  });

  it("a stale scope-A error arriving after scope-B's good result does not surface an error over it", async () => {
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));

    // round-16 Fix 1: coalesces into the trailing slot instead of firing a second concurrent
    // request (see the note in the sibling test above).
    switchToLastCommit(container);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1);

    // The stale A reply is now an error; it must be swallowed (superseded by the coalesce), not
    // thrown or rendered — and its settling is what fires the trailing pull for scope B.
    rejectDiff(0, new Error("stale scope-A workspaceDiff failure"));
    await mounted;
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2)); // trailing pull for B

    resolveDiff(1, [makeFile("b.ts")], "sig-b");
    await vi.waitFor(() => expect(container.textContent).toContain("b.ts"));

    expect(container.textContent).toContain("b.ts");
  });
});

describe("mountRoot's refreshDiff — bounded-backoff retry on failure (round-6 Fix 3)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.notifyModeChanged.mockClear();
    container = document.createElement("div");
    useFakeTimersWithImmediatePaint();
  });

  afterEach(() => {
    vi.useRealTimers();
    window.requestAnimationFrame = nativeRequestAnimationFrame;
  });

  it("swallows a failed pull, retries at the 1s floor, and renders once the retry succeeds", async () => {
    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0); // flush notifyReady's queueMicrotask + spaces:init dispatch
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1);

    rejectDiff(0, new Error("transient failure"));
    await mounted; // the failure is swallowed, not thrown — mountRoot's startup await settles anyway

    await vi.advanceTimersByTimeAsync(999);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1); // not yet due
    await vi.advanceTimersByTimeAsync(1);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2); // retried at the floor

    resolveDiff(1, [makeFile("a.ts")], "sig-a");
    await vi.advanceTimersByTimeAsync(0);
    expect(container.textContent).toContain("a.ts");
  });

  it("doubles the delay after each consecutive failure, capped at 30s", async () => {
    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0);
    rejectDiff(0, new Error("f0"));
    await mounted;

    const expectedDelays = [1000, 2000, 4000, 8000, 16000, 30000, 30000];
    let totalCalls = 1;
    for (let i = 0; i < expectedDelays.length; i++) {
      const delay = expectedDelays[i]!;
      await vi.advanceTimersByTimeAsync(delay - 1);
      expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(totalCalls); // not yet due
      await vi.advanceTimersByTimeAsync(1);
      totalCalls += 1;
      expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(totalCalls); // this retry fired
      rejectDiff(totalCalls - 1, new Error(`f${i + 1}`));
      await vi.advanceTimersByTimeAsync(0); // let the rejection schedule the next retry
    }
  });

  it("a scope switch while a retry is pending supersedes it instead of retrying the old scope", async () => {
    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0);
    rejectDiff(0, new Error("boom"));
    await mounted;

    switchToLastCommit(container); // dispatches setScope -> a fresh refreshDiff call for scope B
    await vi.advanceTimersByTimeAsync(0);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2);

    // Advance well past where scope A's retry would have fired: it must not issue a 3rd call.
    await vi.advanceTimersByTimeAsync(5000);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2);

    resolveDiff(1, [makeFile("b.ts")], "sig-b");
    await vi.advanceTimersByTimeAsync(0);
    expect(container.textContent).toContain("b.ts");
  });

  it("resets the backoff floor after a success", async () => {
    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0);
    rejectDiff(0, new Error("boom 1"));
    await mounted;

    await vi.advanceTimersByTimeAsync(1000); // 1st retry, at the floor
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2);
    resolveDiff(1, [makeFile("a.ts")], "sig-a");
    await vi.advanceTimersByTimeAsync(0);
    expect(container.textContent).toContain("a.ts");

    switchToLastCommit(container); // fresh scope, fresh refreshDiff call
    await vi.advanceTimersByTimeAsync(0);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(3);
    rejectDiff(2, new Error("boom 2"));
    await vi.advanceTimersByTimeAsync(0);

    // If the prior success hadn't reset diffRetryFailures, this retry would be due at 2s, not 1s.
    await vi.advanceTimersByTimeAsync(999);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(3);
    await vi.advanceTimersByTimeAsync(1);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(4);
  });

  it("a scope change resets the backoff floor even without an intervening success", async () => {
    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0);
    rejectDiff(0, new Error("f0")); // call 0: scope A's initial pull fails
    await mounted;

    // Climb scope A's retry counter through 3 consecutive transient failures: after this,
    // diffRetryFailures is 4, and the next scheduled retry (not yet fired) is due at 8000ms.
    const climbDelays = [1000, 2000, 4000];
    let totalCalls = 1;
    for (const delay of climbDelays) {
      await vi.advanceTimersByTimeAsync(delay);
      totalCalls += 1;
      expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(totalCalls); // this retry fired
      rejectDiff(totalCalls - 1, new Error("climb"));
      await vi.advanceTimersByTimeAsync(0); // let the rejection schedule the next retry
    }
    expect(totalCalls).toBe(4);

    // Switch scopes now, WITHOUT letting scope A's pending 8000ms retry ever fire. The scope switch's
    // own token bump makes that pending timer a no-op when it eventually would have fired (see the
    // "a scope switch while a retry is pending supersedes it" test above); it fires a fresh pull for
    // scope B instead.
    switchToLastCommit(container);
    await vi.advanceTimersByTimeAsync(0);
    totalCalls += 1;
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(totalCalls); // scope B's immediate pull

    // Scope B's own first pull also fails transiently.
    rejectDiff(totalCalls - 1, new Error("b0"));
    await vi.advanceTimersByTimeAsync(0);

    // WITH THE FIX: the scope change reset diffRetryFailures to 0, so this retry is due at the 1s
    // floor, not at 16s (the delay `1000 * 2 ** 4` would inherit from scope A's climbed counter).
    await vi.advanceTimersByTimeAsync(999);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(totalCalls); // not yet due
    await vi.advanceTimersByTimeAsync(1);
    totalCalls += 1;
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(totalCalls); // retried at the floor
  });
});

describe("mountRoot's progressive patch scheduler — interrupted chunk recovery", () => {
  let container: HTMLElement;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.workspaceDiffManifestChunk.mockClear();
    hoisted.workspaceDiffFileChunk.mockClear();
    hoisted.workspaceDiffManifestRelease.mockClear();
    hoisted.setManifestPageSize(Number.POSITIVE_INFINITY);
    container = document.createElement("div");
    useFakeTimersWithImmediatePaint();
  });

  afterEach(() => {
    hoisted.setManifestPageSize(Number.POSITIVE_INFINITY);
    hoisted.reviewCommentList.mockReset().mockResolvedValue([]);
    vi.useRealTimers();
    window.requestAnimationFrame = nativeRequestAnimationFrame;
  });

  it("subscribes before initial patch streaming so a live signature queues exactly one refresh", async () => {
    const file = makeFile("initial-stream.ts");
    hoisted.subscribeDiffSignature.mockClear();
    hoisted.diffSignatureCallbacks.length = 0;
    let resolveChunk: ((result: WorkspaceDiffFileChunkResult) => void) | undefined;
    hoisted.workspaceDiffFileChunk.mockImplementationOnce(
      () => new Promise<WorkspaceDiffFileChunkResult>((resolve) => { resolveChunk = resolve; }),
    );
    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0);
    resolveDiff(0, [file], "initial-stream-sig");
    await vi.waitFor(() => expect(resolveChunk).toBeDefined());

    // The initial manifest/sidebar is visible, but its first file is still streaming. A worktree
    // update in this interval must not vanish merely because startup has not yet reached its old
    // end-of-mount subscription call.
    expect(hoisted.subscribeDiffSignature).toHaveBeenCalledTimes(1);
    fireDiffSignature();
    resolveChunk!({ scopeSignature: "initial-stream-sig", file });

    await vi.advanceTimersByTimeAsync(0);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [file], "post-stream-sig");
    await vi.advanceTimersByTimeAsync(0);
    await mounted;

    // The initial listener stays current through the queued refresh; startup must not layer a
    // second callback over it after the stream finally settles.
    expect(hoisted.subscribeDiffSignature).toHaveBeenCalledTimes(1);
  });

  it("does not clean up a completion paint from a superseded stream", async () => {
    const file = makeFile("superseded-stream.ts");
    let resolveChunk: ((result: WorkspaceDiffFileChunkResult) => void) | undefined;
    hoisted.workspaceDiffFileChunk.mockImplementationOnce(
      () => new Promise<WorkspaceDiffFileChunkResult>((resolve) => { resolveChunk = resolve; }),
    );
    const finishRestoredStream = vi.spyOn(DiffView.prototype, "finishRestoredStream");
    const originalRequestAnimationFrame = window.requestAnimationFrame;
    const pendingPaints: FrameRequestCallback[] = [];
    try {
      const mounted = mountRoot(container);
      await vi.advanceTimersByTimeAsync(0);
      resolveDiff(0, [file], "superseded-stream-sig");
      await vi.waitFor(() => expect(resolveChunk).toBeDefined());

      // Hold the completion paint so a newer signature can invalidate the stream before its
      // callback runs. The stale callback must not clear restoration state for the new generation.
      window.requestAnimationFrame = (callback) => {
        pendingPaints.push(callback);
        return pendingPaints.length;
      };
      resolveChunk!({ scopeSignature: "superseded-stream-sig", file });
      await mounted;
      fireDiffSignature();

      while (pendingPaints.length > 0) pendingPaints.shift()!(performance.now());
      expect(finishRestoredStream).not.toHaveBeenCalled();
    } finally {
      window.requestAnimationFrame = originalRequestAnimationFrame;
      finishRestoredStream.mockRestore();
    }
  });

  it("keeps completed work visible, releases the interrupted lease, and retries a recoverable notFound chunk", async () => {
    // A replayed/lost EOF can surface as notFound from the per-file transfer. It is not a bad
    // comparison scope, so the scheduler must use the same bounded retry path as a manifest
    // transport failure rather than leave this row permanently Loading.
    hoisted.workspaceDiffFileChunk.mockRejectedValueOnce(new SpacesBridgeError("notFound", "transfer expired"));
    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1);

    resolveDiff(0, [makeFile("replay.ts")], "sig-a");
    await vi.advanceTimersByTimeAsync(0);
    await mounted;
    expect(hoisted.workspaceDiffFileChunk).toHaveBeenCalledTimes(1);
    const firstRequest = hoisted.workspaceDiffFileChunk.mock.calls[0]![1] as { manifestID: string };
    expect(hoisted.workspaceDiffManifestRelease).toHaveBeenCalledWith(expect.anything(), { manifestID: firstRequest.manifestID });

    await vi.advanceTimersByTimeAsync(999);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2);

    resolveDiff(1, [makeFile("replay.ts")], "sig-b");
    await vi.advanceTimersByTimeAsync(0);
    expect(hoisted.workspaceDiffFileChunk).toHaveBeenCalledTimes(2);
  });

  it("accumulates metadata pages under one manifest before scheduling patches", async () => {
    hoisted.setManifestPageSize(2);
    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0);
    resolveDiff(0, [makeFile("one.ts"), makeFile("two.ts"), makeFile("three.ts")], "sig-pages");
    await vi.waitFor(() => expect(hoisted.workspaceDiffManifestChunk).toHaveBeenCalledTimes(2));
    await mounted;

    const first = hoisted.workspaceDiffManifestChunk.mock.calls[0]![1] as { manifestID?: string; fileIndex: number };
    const second = hoisted.workspaceDiffManifestChunk.mock.calls[1]![1] as { manifestID?: string; fileIndex: number };
    expect(first).toEqual({ manifestID: undefined, fileIndex: 0 });
    expect(second).toEqual({ manifestID: expect.any(String), fileIndex: 2 });
    expect(hoisted.workspaceDiffFileChunk).toHaveBeenCalledTimes(3);
  });

  it("keeps a collapsed Changes tree stable while hidden rows stream, then shows their final state on expansion", async () => {
    const previousPayload = INIT_PAYLOAD;
    INIT_PAYLOAD = {
      ...previousPayload,
      workspaceState: { ...previousPayload.workspaceState, diffTreeExpandedPaths: [] },
    };
    try {
      const file: DiffFileEntry = {
        path: "src/hidden.ts",
        status: "modified",
        isBinary: false,
        patch: "@@ -1 +1 @@\n-old\n+new",
      };
      hoisted.workspaceDiffFileChunk.mockImplementationOnce(() => Promise.resolve({
        scopeSignature: "sig-hidden-stream",
        file,
        patchBase64Data: btoa(file.patch!),
      }));
      const mounted = mountRoot(container);
      await vi.advanceTimersByTimeAsync(0);
      resolveDiff(0, [file], "sig-hidden-stream");
      await mounted;

      const group = container.querySelector(".dir-group");
      const dirrow = container.querySelector(".dirrow") as HTMLElement;
      expect(dirrow.getAttribute("aria-expanded")).toBe("false");
      expect(container.querySelectorAll(".row")).toHaveLength(0);

      // Both streaming and completion updates target the backing manifest entry. Neither should
      // replace the collapsed tree or eagerly create its hidden row.
      expect(container.querySelector(".dir-group")).toBe(group);
      expect(hoisted.workspaceDiffFileChunk).toHaveBeenCalledTimes(1);

      dirrow.click();

      expect(container.querySelector(".dir-group")).toBe(group);
      expect(container.querySelector('.row[data-path="src/hidden.ts"] .st')?.textContent).toBe("+1 -1");
    } finally {
      INIT_PAYLOAD = previousPayload;
    }
  });

  it("loads persisted comments after the manifest is available without waiting for a held patch stream", async () => {
    const queuedFile: DiffFileEntry = {
      path: "comments-while-streaming.ts",
      status: "modified",
      isBinary: false,
      patch: "diff --git a/comments-while-streaming.ts b/comments-while-streaming.ts\n--- a/comments-while-streaming.ts\n+++ b/comments-while-streaming.ts\n@@ -1 +1 @@\n-before\n+after\n",
    };
    const serverDraft = {
      id: "comment-during-stream",
      filePath: queuedFile.path,
      side: "new" as const,
      lineNumber: 1,
      lineText: "after",
      body: "review while patch is loading",
      createdAt: "2026-08-26T00:00:00.000Z",
      revision: 0,
    };
    let resolveChunk: ((result: WorkspaceDiffFileChunkResult) => void) | undefined;
    hoisted.workspaceDiffFileChunk.mockImplementationOnce(
      () => new Promise<WorkspaceDiffFileChunkResult>((resolve) => { resolveChunk = resolve; }),
    );
    hoisted.reviewCommentList.mockReset().mockResolvedValue([serverDraft]);

    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0);
    resolveDiff(0, [queuedFile], "comments-streaming-sig");
    await vi.waitFor(() => expect(resolveChunk).toBeDefined());

    // The manifest has named the file, so comments can retain that queued anchor and populate the
    // tray before the slow file patch completes. Waiting for the full stream hides real drafts.
    await vi.waitFor(() => expect(container.querySelector(".comment-tray")?.textContent).toContain("review while patch is loading"));
    expect(container.querySelector(".comment-tray")?.textContent).toContain(`${queuedFile.path}:1`);

    resolveChunk!({ scopeSignature: "comments-streaming-sig", file: queuedFile });
    await vi.advanceTimersByTimeAsync(0);
    await mounted;
  });

  it("releases an initial manifest lease whose first metadata page arrives after supersession", async () => {
    type MockManifestPage = Awaited<ReturnType<typeof hoisted.workspaceDiffManifestChunk>>;
    let resolveInitialPage: ((result: MockManifestPage) => void) | undefined;
    hoisted.workspaceDiffManifestChunk.mockImplementationOnce(
      () => new Promise<MockManifestPage>((resolve) => { resolveInitialPage = resolve; }),
    );

    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0);
    expect(hoisted.workspaceDiffManifestChunk).toHaveBeenCalledTimes(1);

    // A scope switch supersedes the first pull before the daemon returns its first metadata page.
    // That page has already minted a manifest lease, even though the page must never render.
    switchToLastCommit(container);
    resolveInitialPage!({ manifestID: "late-initial-manifest", scopeSignature: "sig-late", files: [], nextFileIndex: undefined });

    await vi.waitFor(() => {
      expect(hoisted.workspaceDiffManifestRelease).toHaveBeenCalledWith(
        expect.anything(),
        { manifestID: "late-initial-manifest" },
      );
    });
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [], "sig-current");
    await vi.advanceTimersByTimeAsync(0);
    await mounted;
  });

  it("assembles a multi-chunk textual patch in order before updating only that completed item", async () => {
    const file: DiffFileEntry = { path: "chunked.ts", status: "modified", isBinary: false };
    hoisted.workspaceDiffFileChunk
      .mockImplementationOnce(() =>
        Promise.resolve({
          scopeSignature: "sig-chunked",
          file,
          patchBase64Data: btoa("first "),
          transferID: "transfer-1",
          nextByteOffset: 6,
        }),
      )
      .mockImplementationOnce(() =>
        Promise.resolve({
          scopeSignature: "sig-chunked",
          file,
          patchBase64Data: btoa("second"),
        }),
      );
    const updateFileSpy = vi.spyOn(DiffView.prototype, "updateFile");
    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0);
    resolveDiff(0, [file], "sig-chunked");
    await vi.advanceTimersByTimeAsync(0);
    await mounted;

    expect(hoisted.workspaceDiffFileChunk).toHaveBeenNthCalledWith(
      2,
      expect.anything(),
      expect.objectContaining({ relativePath: "chunked.ts", byteOffset: 6, transferID: "transfer-1" }),
    );
    expect(updateFileSpy).toHaveBeenLastCalledWith(
      expect.objectContaining({ path: "chunked.ts", patch: "first second", patchState: "ready" }),
    );
    await vi.waitFor(() => {
      const metric = hoisted.notifyRenderMetric.mock.calls
        .map(([value]) => value as { trigger?: string })
        .find((value) => value.trigger === "filePatch") as
        | ({ trigger: "filePatch"; bridgeElapsedMs?: unknown; decodeElapsedMs?: unknown; updateElapsedMs?: unknown; paintElapsedMs?: unknown })
        | undefined;
      expect(metric).toEqual(expect.objectContaining({
        bridgeElapsedMs: expect.any(Number),
        decodeElapsedMs: expect.any(Number),
        updateElapsedMs: expect.any(Number),
        paintElapsedMs: expect.any(Number),
      }));
    });
    updateFileSpy.mockRestore();
  });

  it("reveals a selected queued file when its promoted patch arrives and repairs order once after streaming", async () => {
    const files = [makeFile("1.ts"), makeFile("2.ts"), makeFile("50.ts")];
    let releaseFirst: ((value: WorkspaceDiffFileChunkResult) => void) | undefined;
    hoisted.workspaceDiffFileChunk.mockImplementationOnce(
      () => new Promise<WorkspaceDiffFileChunkResult>((resolve) => { releaseFirst = resolve; }),
    );
    const scrollToFile = vi.spyOn(DiffView.prototype, "scrollToFile");
    const finalizeOrder = vi.spyOn(DiffView.prototype, "finalizeStreamOrder");
    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0);
    resolveDiff(0, files, "sig-priority");
    await vi.waitFor(() => expect(releaseFirst).toBeDefined());

    (container.querySelector<HTMLElement>('[data-path="50.ts"]'))!.click();
    releaseFirst!({ scopeSignature: "sig-priority", file: files[0]! });
    await mounted;

    // The explicit sidebar navigation is the only public scrollToFile call. Subsequent streaming
    // reveals use DiffView's internal non-clearing path so they cannot erase a pending restore.
    expect(scrollToFile.mock.calls.filter(([path]) => path === "50.ts")).toHaveLength(1);
    expect(finalizeOrder).toHaveBeenCalledTimes(1);
    scrollToFile.mockRestore();
    finalizeOrder.mockRestore();
  });

  it("uses the sidebar selection, promotion, and reveal path when Quick Open picks a queued diff file", async () => {
    const files = [makeFile("1.ts"), makeFile("2.ts"), makeFile("50.ts")];
    hoisted.workspaceFileList.mockResolvedValue({ paths: files.map((file) => file.path), truncated: false });
    let releaseFirst: ((value: WorkspaceDiffFileChunkResult) => void) | undefined;
    hoisted.workspaceDiffFileChunk.mockImplementationOnce(
      () => new Promise<WorkspaceDiffFileChunkResult>((resolve) => { releaseFirst = resolve; }),
    );
    const scrollToFile = vi.spyOn(DiffView.prototype, "scrollToFile");
    const finalizeOrder = vi.spyOn(DiffView.prototype, "finalizeStreamOrder");
    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0);
    resolveDiff(0, files, "sig-quick-open-priority");
    await vi.waitFor(() => expect(releaseFirst).toBeDefined());

    window.dispatchEvent(new KeyboardEvent("keydown", { key: "p", metaKey: true }));
    const input = container.querySelector<HTMLInputElement>(".quick-open input")!;
    input.value = "50.ts";
    input.dispatchEvent(new Event("input"));
    const row = await vi.waitFor(() => {
      const result = container.querySelector<HTMLElement>('.quick-open .row[data-path="50.ts"]');
      expect(result).not.toBeNull();
      return result!;
    });
    row.click();

    releaseFirst!({ scopeSignature: "sig-quick-open-priority", file: files[0]! });
    await mounted;

    expect(hoisted.workspaceDiffFileChunk.mock.calls[1]![1]).toEqual(expect.objectContaining({ relativePath: "50.ts" }));
    expect(scrollToFile.mock.calls.filter(([path]) => path === "50.ts")).toHaveLength(1);
    expect(finalizeOrder).toHaveBeenCalledTimes(1);
    hoisted.workspaceFileList.mockReset().mockRejectedValue(new Error("not used"));
    scrollToFile.mockRestore();
    finalizeOrder.mockRestore();
  });
});

describe("mountRoot's persisted diff position recovery", () => {
  const defaultInitPayload = INIT_PAYLOAD;
  let container: HTMLElement;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.workspaceDiffFileChunk.mockClear();
    capturedCodeViewOptions.current = undefined;
    capturedCodeViewOptions.scrollCalls = [];
    capturedCodeViewOptions.selectedLineCalls = [];
    INIT_PAYLOAD = {
      ...defaultInitPayload,
      workspaceState: {
        ...defaultInitPayload.workspaceState,
        // The Changes-tree selection is deliberately unrelated: recovery must follow the saved
        // visible patch rather than a sidebar row from the prior session.
        diffSelectedPath: "restored.ts",
        diffTreeSelectedPath: "another-row.ts",
        diffScrollLine: 7,
        diffScrollSide: "old",
        diffFocusedPath: "restored.ts",
        diffFocusedLine: 8,
        diffFocusedSide: "old",
      },
    };
    container = document.createElement("div");
  });

  afterEach(() => {
    INIT_PAYLOAD = defaultInitPayload;
    container.remove();
  });

  it("defers persisted line restoration until the saved path's delayed textual patch post-renders", async () => {
    const finishRestoredStream = vi.spyOn(DiffView.prototype, "finishRestoredStream");
    const delayedFile: DiffFileEntry = {
      path: "restored.ts",
      status: "modified",
      isBinary: false,
      patch: "diff --git a/restored.ts b/restored.ts\n--- a/restored.ts\n+++ b/restored.ts\n@@ -1 +1 @@\n-before\n+after\n",
    };
    let resolveChunk: ((result: { scopeSignature: string; file: DiffFileEntry }) => void) | undefined;
    hoisted.workspaceDiffFileChunk.mockImplementationOnce(
      () => new Promise((resolve) => {
        resolveChunk = resolve;
      }),
    );

    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));

    // The initial diff manifest is still pending. A hibernation at this point must nevertheless
    // retain the saved logical location instead of serializing nulls from an unpopulated CodeView.
    const earlySnapshot = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}");
    expect(earlySnapshot).toMatchObject({
      diffSelectedPath: "restored.ts",
      diffScrollLine: 7,
      diffScrollSide: "old",
      diffFocusedPath: "restored.ts",
      diffFocusedLine: 8,
      diffFocusedSide: "old",
    });
    resolveDiff(0, [delayedFile], "restore-sig");
    await vi.waitFor(() => expect(hoisted.workspaceDiffFileChunk).toHaveBeenCalledTimes(1));

    // The manifest has painted only a Loading patch row. Revealing/focusing line 7 here would be
    // a no-op in Pierre and permanently lose the saved position.
    expect(capturedCodeViewOptions.scrollCalls).toEqual([]);
    expect(capturedCodeViewOptions.selectedLineCalls).toEqual([]);

    resolveChunk!({ scopeSignature: "restore-sig", file: delayedFile });
    await mounted;
    // The final streamed update schedules Pierre's FileDiff render. The restoration guard must
    // remain active until that render's callback can apply the saved line.
    expect(finishRestoredStream).not.toHaveBeenCalled();
    // This no-op test double does not automatically invoke library post-render callbacks. Drive
    // the callback exactly as Pierre does after the textual FileDiff is attached.
    capturedCodeViewOptions.current!.onPostRender!(document.createElement("div"), { item: { id: "restored.ts" } });

    expect(capturedCodeViewOptions.scrollCalls).toContainEqual({
      type: "line",
      id: "restored.ts",
      lineNumber: 7,
      side: "deletions",
      behavior: "instant",
    });
    expect(capturedCodeViewOptions.selectedLineCalls).toEqual([null]);
    finishRestoredStream.mockRestore();
  });

  it("does not replace a delayed restored source line with the selected patch's first line", async () => {
    INIT_PAYLOAD = {
      ...INIT_PAYLOAD,
      workspaceState: {
        ...INIT_PAYLOAD.workspaceState,
        diffScrollLine: 203,
        diffScrollSide: "new",
      },
    };
    const delayedFile: DiffFileEntry = {
      path: "restored.ts",
      status: "modified",
      isBinary: false,
      patch: "diff --git a/restored.ts b/restored.ts\n--- a/restored.ts\n+++ b/restored.ts\n@@ -1 +1 @@\n-before\n+after\n",
    };
    let resolveChunk: ((result: { scopeSignature: string; file: DiffFileEntry }) => void) | undefined;
    hoisted.workspaceDiffFileChunk.mockImplementationOnce(
      () => new Promise((resolve) => { resolveChunk = resolve; }),
    );

    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [delayedFile], "restore-selected-stream");
    await vi.waitFor(() => expect(hoisted.workspaceDiffFileChunk).toHaveBeenCalledTimes(1));
    resolveChunk!({ scopeSignature: "restore-selected-stream", file: delayedFile });
    await mounted;

    // A selected queued row becomes scrollable as its patch arrives. That reveal must not replace
    // the restored source location with the file's first line before Pierre post-renders it.
    expect(capturedCodeViewOptions.scrollCalls).not.toContainEqual({
      type: "item",
      id: "restored.ts",
      align: "start",
      behavior: "smooth",
    });
    capturedCodeViewOptions.current!.onPostRender!(document.createElement("div"), { item: { id: "restored.ts" } });
    expect(capturedCodeViewOptions.scrollCalls).toContainEqual({
      type: "line",
      id: "restored.ts",
      lineNumber: 203,
      side: "additions",
      behavior: "instant",
    });
  });

  it("keeps the restored position in a teardown snapshot while an earlier streamed patch is visible", async () => {
    document.body.appendChild(container);
    const delayedFile: DiffFileEntry = {
      path: "restored.ts",
      status: "modified",
      isBinary: false,
      patch: "diff --git a/restored.ts b/restored.ts\n--- a/restored.ts\n+++ b/restored.ts\n@@ -1 +1 @@\n-before\n+after\n",
    };
    let resolveChunk: ((result: { scopeSignature: string; file: DiffFileEntry }) => void) | undefined;
    hoisted.workspaceDiffFileChunk.mockImplementationOnce(
      () => new Promise((resolve) => { resolveChunk = resolve; }),
    );

    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [delayedFile], "restore-snapshot-sig");
    await vi.waitFor(() => expect(hoisted.workspaceDiffFileChunk).toHaveBeenCalledTimes(1));

    // The restored target is still a queued placeholder, so no live line is in the virtualized
    // diff yet. A host collection at this point must preserve the pending logical position.
    let snapshot = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}");
    expect(snapshot).toMatchObject({
      diffSelectedPath: "restored.ts",
      diffScrollLine: 7,
      diffScrollSide: "old",
    });

    // An earlier streamed file can render before the restored target. Its first visible line is
    // not the restored viewport, so a teardown during this stream must retain the exact target.
    const scrollRoot = container.querySelector<HTMLElement>("#code-pane-diff-scroll")!;
    const visibleLine = document.createElement("div");
    visibleLine.dataset.line = "3";
    visibleLine.dataset.diffPath = "concrete.ts";
    visibleLine.dataset.diffSide = "new";
    Object.defineProperty(scrollRoot, "getBoundingClientRect", { value: () => ({ top: 0 }) });
    Object.defineProperty(visibleLine, "getBoundingClientRect", { value: () => ({ bottom: 1 }) });
    scrollRoot.appendChild(visibleLine);

    snapshot = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}");
    expect(snapshot).toMatchObject({
      diffSelectedPath: "restored.ts",
      diffScrollLine: 7,
      diffScrollSide: "old",
    });

    resolveChunk!({ scopeSignature: "restore-snapshot-sig", file: delayedFile });
    await mounted;
  });

  it("reports the durable pending diff position before its delayed patch renders", async () => {
    document.body.appendChild(container);
    const delayedFile: DiffFileEntry = {
      path: "restored.ts",
      status: "modified",
      isBinary: false,
      patch: "diff --git a/restored.ts b/restored.ts\n--- a/restored.ts\n+++ b/restored.ts\n@@ -1 +1 @@\n-before\n+after\n",
    };
    let resolveChunk: ((result: { scopeSignature: string; file: DiffFileEntry }) => void) | undefined;
    hoisted.workspaceDiffFileChunk.mockImplementationOnce(
      () => new Promise((resolve) => { resolveChunk = resolve; }),
    );

    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    await vi.waitFor(() => {
      const metric = hoisted.notifyRenderMetric.mock.calls
        .map(([value]) => value as { trigger?: string; path?: string; scrollTop?: number; focusedLine?: number })
        .find((value) => value.trigger === "workspaceStateRestored" && value.path === "restored.ts");
      expect(metric).toEqual(expect.objectContaining({ scrollTop: 7, focusedLine: 8 }));
    });

    resolveDiff(0, [delayedFile], "restore-metric-sig");
    await vi.waitFor(() => expect(hoisted.workspaceDiffFileChunk).toHaveBeenCalledTimes(1));
    resolveChunk!({ scopeSignature: "restore-metric-sig", file: delayedFile });
    await mounted;
  });
});

describe("mountRoot's queued live diff refresh position recovery", () => {
  let container: HTMLElement;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.workspaceDiffFileChunk.mockClear();
    hoisted.workspaceDiffManifestRelease.mockClear();
    capturedCodeViewOptions.current = undefined;
    capturedCodeViewOptions.scrollCalls = [];
    capturedCodeViewOptions.selectedLineCalls = [];
    container = document.createElement("div");
    document.body.appendChild(container);
  });

  afterEach(() => {
    container.remove();
  });

  it("keeps the current location while a signature refresh holds its replacement patch queued", async () => {
    const file: DiffFileEntry = {
      path: "live.ts",
      status: "modified",
      isBinary: false,
      patch: "diff --git a/live.ts b/live.ts\n--- a/live.ts\n+++ b/live.ts\n@@ -1 +1 @@\n-before\n+after\n",
    };
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [file], "live-first");
    await mounted;

    const diffRoot = container.querySelector<HTMLElement>("#code-pane-diff-scroll")!;
    const visibleLine = document.createElement("div");
    visibleLine.dataset.line = "11";
    visibleLine.dataset.diffPath = file.path;
    visibleLine.dataset.diffSide = "new";
    Object.defineProperty(diffRoot, "getBoundingClientRect", { value: () => ({ top: 0 }) });
    Object.defineProperty(visibleLine, "getBoundingClientRect", { value: () => ({ bottom: 1 }) });
    diffRoot.appendChild(visibleLine);
    capturedCodeViewOptions.current!.onLineClick!(
      { type: "diff-line", lineNumber: 12, annotationSide: "deletions" },
      { type: "diff", item: { id: file.path } },
    );
    capturedCodeViewOptions.scrollCalls = [];
    capturedCodeViewOptions.selectedLineCalls = [];

    let releaseReplacementPatch!: (value: WorkspaceDiffFileChunkResult) => void;
    hoisted.workspaceDiffFileChunk.mockImplementationOnce(
      () => new Promise<WorkspaceDiffFileChunkResult>((resolve) => { releaseReplacementPatch = resolve; }),
    );
    fireDiffSignature();
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [file], "live-second");
    await vi.waitFor(() => expect(releaseReplacementPatch).toBeTypeOf("function"));

    // The refreshed manifest is metadata-only while its patch is in flight. Its replacement
    // CodeView has no line to sample, but teardown/state collection must keep the old location.
    visibleLine.remove();
    const queuedSnapshot = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}");
    expect(queuedSnapshot).toMatchObject({
      diffSelectedPath: file.path,
      diffScrollLine: 11,
      diffScrollSide: "new",
      diffFocusedPath: file.path,
      diffFocusedLine: 12,
      diffFocusedSide: "old",
    });

    releaseReplacementPatch({ scopeSignature: "live-second", file });
    await vi.waitFor(() => expect(hoisted.workspaceDiffManifestRelease).toHaveBeenCalledTimes(2));
    capturedCodeViewOptions.current!.onPostRender!(document.createElement("div"), { item: { id: file.path } });

    expect(capturedCodeViewOptions.scrollCalls).toContainEqual({
      type: "line",
      id: file.path,
      lineNumber: 11,
      side: "additions",
      behavior: "instant",
    });
    expect(capturedCodeViewOptions.selectedLineCalls).toEqual([null]);
  });
});

describe("mountRoot's diff-tree expansion recovery", () => {
  const defaultInitPayload = INIT_PAYLOAD;
  let container: HTMLElement;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    INIT_PAYLOAD = defaultInitPayload;
    container = document.createElement("div");
  });

  afterEach(() => {
    INIT_PAYLOAD = defaultInitPayload;
  });

  it("uses the expanded tree default for a fresh workspace whose state omits expansion choices", async () => {
    const { diffTreeExpandedPaths: _freshExpansionChoice, ...freshWorkspaceState } = defaultInitPayload.workspaceState;
    INIT_PAYLOAD = { ...defaultInitPayload, workspaceState: freshWorkspaceState };
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [makeFile("src/fresh.ts")], "fresh-tree-sig");
    await mounted;

    expect(container.querySelector(".dirrow .tri")?.textContent).toBe("▾");
    const snapshot = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}");
    expect(snapshot).not.toHaveProperty("diffTreeExpandedPaths");
  });

  it("restores an explicit empty expansion choice as collapse-all", async () => {
    INIT_PAYLOAD = {
      ...defaultInitPayload,
      workspaceState: { ...defaultInitPayload.workspaceState, diffTreeExpandedPaths: [] },
    };
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [makeFile("src/collapsed.ts")], "collapsed-tree-sig");
    await mounted;

    expect(container.querySelector(".dirrow .tri")?.textContent).toBe("▸");
    const snapshot = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}");
    expect(snapshot.diffTreeExpandedPaths).toEqual([]);
  });
});

describe("mountRoot's routine workspace-state snapshots", () => {
  const defaultInitPayload = INIT_PAYLOAD;
  let container: HTMLElement;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.reviewCommentList.mockReset();
    hoisted.notifyWorkspaceStateChanged.mockClear();
    INIT_PAYLOAD = defaultInitPayload;
    container = document.createElement("div");
    useFakeTimersWithImmediatePaint();
  });

  afterEach(() => {
    hoisted.reviewCommentList.mockReset().mockResolvedValue([]);
    INIT_PAYLOAD = defaultInitPayload;
    vi.useRealTimers();
    window.requestAnimationFrame = nativeRequestAnimationFrame;
  });

  it("does not cancel a failed initial comment-list retry when an unrelated workspace state changes", async () => {
    const serverDraft = {
      id: "loaded-after-retry",
      filePath: "retry.ts",
      side: "new" as const,
      lineNumber: 1,
      lineText: "after retry",
      body: "loaded after retry",
      createdAt: "2026-08-26T00:00:00.000Z",
      revision: 0,
    };
    hoisted.reviewCommentList
      .mockRejectedValueOnce(new SpacesBridgeError("unavailable", "comment service temporarily unavailable"))
      .mockResolvedValueOnce([serverDraft]);
    const setCommentsSpy = vi.spyOn(DiffView.prototype, "setComments");

    try {
      const mounted = mountRoot(container);
      await vi.advanceTimersByTimeAsync(0);
      expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1);
      resolveDiff(0, [], "comments-retry-sig");
      await vi.advanceTimersByTimeAsync(0);
      await mounted;
      expect(hoisted.reviewCommentList).toHaveBeenCalledTimes(1);

      // Mode is unrelated to comment loading, but dispatching it persists the complete workspace
      // document. That routine snapshot must not behave like the teardown collector and clear the
      // retry timer it happens to inspect.
      clickButton(container, "Editor");
      expect(hoisted.notifyWorkspaceStateChanged).toHaveBeenCalled();

      await vi.advanceTimersByTimeAsync(999);
      expect(hoisted.reviewCommentList).toHaveBeenCalledTimes(1);
      await vi.advanceTimersByTimeAsync(1);
      expect(hoisted.reviewCommentList).toHaveBeenCalledTimes(2);
      await vi.waitFor(() =>
        expect(
          setCommentsSpy.mock.calls.some(([comments]) =>
            (comments as ReadonlyArray<{ comment: { id: string } }>).some((entry) => entry.comment.id === serverDraft.id),
          ),
        ).toBe(true),
      );
    } finally {
      setCommentsSpy.mockRestore();
    }
  });
});

describe("mountRoot's inline diff edit ownership and CAS races", () => {
  let container: HTMLElement;
  const defaultInitPayload = INIT_PAYLOAD;
  const editableFile: DiffFileEntry = {
    path: "editable.ts",
    status: "modified",
    isBinary: false,
    // The inline editor hydrates a complete diff by reversing this patch against the disk read.
    // Keep the synthetic pair coherent so failed hydration cannot be hidden by a fallback item.
    patch: "diff --git a/editable.ts b/editable.ts\n--- a/editable.ts\n+++ b/editable.ts\n@@ -1 +1 @@\n-before\n+disk before\n",
  };

  function editableFileForContent(content: string, oldContent = "before\n"): DiffFileEntry {
    return {
      ...editableFile,
      patch: createTwoFilesPatch("a/editable.ts", "b/editable.ts", oldContent, content),
    };
  }

  async function mountEditableDiff(file = editableFile): Promise<void> {
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [file], "editable-sig");
    await mounted;
  }

  async function startEdit(path = editableFile.path): Promise<void> {
    capturedCodeViewOptions.current!.onLineClick!(
      { type: "diff-line", lineNumber: 1, annotationSide: "additions" },
      { type: "diff", item: { id: path } },
    );
    await Promise.resolve();
    await Promise.resolve();
  }

  function typeInEditor(content: string, path = editableFile.path): void {
    capturedCodeViewOptions.current!.onItemEditChange({ id: path, type: "diff" }, { contents: content });
  }

  /** ⌘S is the pane's "don't wait for the debounce" shortcut. Tests that only care about the write
   *  itself use it instead of advancing 800ms of scheduler debounce. */
  function pressSaveShortcut(): void {
    window.dispatchEvent(new KeyboardEvent("keydown", { key: "s", metaKey: true, bubbles: true, cancelable: true }));
  }

  /** Escape typed inside the inline editor, which is the only Escape the pane claims. The stubbed
   *  `CodeView` renders no Pierre DOM, so this dispatches from a stand-in carrying the id
   *  `DiffView` puts on the real contenteditable; `test/root.pierre.test.ts` covers the same path
   *  against the real renderer. */
  function pressEscape(): void {
    const editor = document.createElement("div");
    editor.id = DIFF_EDIT_INPUT_ID;
    document.body.appendChild(editor);
    editor.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, composed: true, cancelable: true }));
    editor.remove();
  }

  /** Escape typed anywhere else: a toolbar menu, a sidebar row, the diff body. */
  function pressEscapeOutsideTheEditor(): void {
    document.body.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true, composed: true, cancelable: true }));
  }

  function editHeader(path = editableFile.path): HTMLElement {
    return capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: path })!;
  }

  function editStatusChip(path = editableFile.path): HTMLElement | null {
    return editHeader(path).querySelector<HTMLElement>("#code-pane-diff-edit-status");
  }

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.workspaceDiffFileChunk.mockClear();
    hoisted.workspaceFileRead.mockReset();
    hoisted.workspaceRevisionFileRead.mockReset();
    hoisted.workspaceFileWrite.mockReset();
    hoisted.notifyWorkspaceStateChanged.mockClear();
    hoisted.notifyRenderMetric.mockClear();
    hoisted.notifyEditsFlushed.mockClear();
    capturedCodeViewOptions.current = undefined;
    INIT_PAYLOAD = defaultInitPayload;
    container = document.createElement("div");
  });

  afterEach(() => {
    INIT_PAYLOAD = defaultInitPayload;
    hoisted.workspaceFileRead.mockReset().mockRejectedValue(new Error("not used"));
    hoisted.workspaceRevisionFileRead.mockReset().mockRejectedValue(new Error("not used"));
    hoisted.workspaceFileWrite.mockReset().mockRejectedValue(new Error("not used"));
    vi.useRealTimers();
    window.requestAnimationFrame = nativeRequestAnimationFrame;
  });

  it("blocks Last Commit inline editing when the worktree no longer matches the pinned revision", async () => {
    const lastCommitFile: DiffFileEntry = {
      ...editableFile,
      targetRevision: "a".repeat(40),
    };
    // The server's one response supplies both the exact live CAS baseline and the Git result.
    // A false result must prevent an editor even though the returned content is otherwise usable.
    hoisted.workspaceRevisionFileRead.mockResolvedValue({
      content: "same decoded text\n", sha256: "sha-worktree", size: 18,
      isWorktreeEquivalentToRevision: false, comparisonOldContent: null,
    });

    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [], "uncommitted-sig");
    await mounted;
    hoisted.workspaceDiffManifestRelease.mockClear();

    switchToLastCommit(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [lastCommitFile], "last-commit-sig");
    await vi.waitFor(() => expect(capturedCodeViewOptions.current?.onLineClick).toBeDefined());
    await startEdit();

    await vi.waitFor(() =>
      expect(hoisted.workspaceRevisionFileRead).toHaveBeenCalledWith({
        path: "editable.ts",
        revision: "a".repeat(40),
      }),
    );
    expect(hoisted.workspaceFileRead).not.toHaveBeenCalledWith("editable.ts", "inlineDiff");
    await vi.waitFor(() =>
      expect(container.querySelector("#code-pane-diff-edit-error")?.textContent).toBe(
        "Workspace file changed since this commit. Switch to Uncommitted to edit it.",
      ),
    );
    await vi.waitFor(() => expect(hoisted.workspaceDiffManifestRelease).toHaveBeenCalledTimes(1));
    expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toBeNull();
  });

  it("uses the Git-filtered Last Commit comparison content instead of reverse-applying the raw patch", async () => {
    const disk = "new SMUDGE\n";
    const lastCommitFile = {
      ...editableFileForContent(disk, "old CANON\n"),
      targetRevision: "z".repeat(40),
    };
    INIT_PAYLOAD = { ...INIT_PAYLOAD, workspaceState: { ...INIT_PAYLOAD.workspaceState, scope: { kind: "lastCommit" } } };
    hoisted.workspaceRevisionFileRead.mockResolvedValue({
      content: disk,
      sha256: "sha-smudged",
      size: disk.length,
      isWorktreeEquivalentToRevision: true,
      comparisonOldContent: "old SMUDGE\n",
    });

    await mountEditableDiff(lastCommitFile);
    await startEdit();
    await vi.waitFor(() => {
      const snapshot = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}") as { diffEditorState?: CodePaneDiffEditorState };
      expect(snapshot.diffEditorState?.comparisonOldContent).toBe("old SMUDGE\n");
    });
  });

  it("uses the server-filtered old side for an Uncommitted inline edit", async () => {
    const disk = "new SMUDGE\n";
    const file = {
      ...editableFileForContent(disk, "old CANON\n"),
      comparisonBaseRevision: "c".repeat(40),
    };
    hoisted.workspaceFileRead.mockResolvedValue({
      content: disk, sha256: "sha-smudged", size: disk.length, comparisonOldContent: "old SMUDGE\n",
    });

    await mountEditableDiff(file);
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith(
      "editable.ts", "inlineDiff", { baseRevision: "c".repeat(40), oldPath: undefined },
    ));
    const snapshot = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}") as { diffEditorState?: CodePaneDiffEditorState };
    expect(snapshot.diffEditorState?.comparisonOldContent).toBe("old SMUDGE\n");
  });

  it("preserves an added file's explicit null comparison side when switching to Last Commit", async () => {
    const content = "added text\n";
    const uncommittedAdded: DiffFileEntry = {
      path: "editable.ts", status: "added", isBinary: false,
      patch: createTwoFilesPatch("a/editable.ts", "b/editable.ts", "", content),
      comparisonBaseRevision: "a".repeat(40),
    };
    const lastCommitAdded: DiffFileEntry = {
      ...uncommittedAdded,
      comparisonBaseRevision: undefined,
      targetRevision: "b".repeat(40),
    };
    hoisted.workspaceFileRead.mockResolvedValueOnce({ content, sha256: "sha-uncommitted", size: content.length, comparisonOldContent: null });
    hoisted.workspaceRevisionFileRead.mockResolvedValueOnce({
      content, sha256: "sha-last-commit", size: content.length,
      isWorktreeEquivalentToRevision: true, comparisonOldContent: null,
    });

    await mountEditableDiff(uncommittedAdded);
    await startEdit();
    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "diff" }, { contents: "my added edit\n" });

    switchToLastCommit(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [lastCommitAdded], "last-commit-added-sig");
    await vi.waitFor(() => {
      const snapshot = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}") as { diffEditorState?: CodePaneDiffEditorState };
      expect(snapshot.diffEditorState).toMatchObject({
        content: "my added edit\n",
        dirty: true,
        comparisonOldContent: null,
      });
    });
  });

  it("treats a Last Commit worktree deletion as divergence while retaining ordinary scope deletion behavior", async () => {
    const lastCommitFile: DiffFileEntry = { ...editableFile, targetRevision: "d".repeat(40) };
    hoisted.workspaceRevisionFileRead.mockRejectedValue(new SpacesBridgeError("notFound", "editable.ts was deleted"));

    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [], "uncommitted-sig");
    await mounted;

    switchToLastCommit(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [lastCommitFile], "last-commit-deleted-sig");
    await vi.waitFor(() => expect(capturedCodeViewOptions.current?.onLineClick).toBeDefined());
    await startEdit();

    await vi.waitFor(() =>
      expect(container.querySelector("#code-pane-diff-edit-error")?.textContent).toBe(
        "Workspace file changed since this commit. Switch to Uncommitted to edit it.",
      ),
    );
  });

  it("re-arms a live editor before entering Last Commit and restores it only after the pinned revision matches disk", async () => {
    hoisted.workspaceFileRead.mockResolvedValueOnce({ content: "disk before\n", sha256: "sha-before", size: 12 });
    await mountEditableDiff();
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));

    let resolveRevision: ((result: { content: string; sha256: string; size: number; isWorktreeEquivalentToRevision: boolean; comparisonOldContent: string | null }) => void) | undefined;
    hoisted.workspaceRevisionFileRead.mockImplementationOnce(
      () => new Promise((resolve) => {
        resolveRevision = resolve;
      }),
    );
    const beginPreparedSpy = vi.spyOn(DiffView.prototype, "beginPreparedEdit");
    const endEditSpy = vi.spyOn(DiffView.prototype, "endEdit");
    const lastCommitFile: DiffFileEntry = { ...editableFile, targetRevision: "e".repeat(40) };

    switchToLastCommit(container);
    expect(endEditSpy).toHaveBeenCalledWith("editable.ts");
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [lastCommitFile], "last-commit-guarded-sig");
    await vi.waitFor(() => expect(hoisted.workspaceRevisionFileRead).toHaveBeenCalledTimes(1));
    expect(beginPreparedSpy).not.toHaveBeenCalled();
    expect(capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })).toBeUndefined();

    resolveRevision!({ content: "disk before\n", sha256: "sha-commit", size: 12, isWorktreeEquivalentToRevision: true, comparisonOldContent: "before\n" });
    await vi.waitFor(() => expect(beginPreparedSpy).toHaveBeenCalledTimes(1));
    beginPreparedSpy.mockRestore();
    endEditSpy.mockRestore();
  });

  it("re-arms an active Last Commit editor through the immutable guard after a signature refresh", async () => {
    const lastCommitFile: DiffFileEntry = { ...editableFile, targetRevision: "h".repeat(40) };
    INIT_PAYLOAD = { ...INIT_PAYLOAD, workspaceState: { ...INIT_PAYLOAD.workspaceState, scope: { kind: "lastCommit" } } };
    let resolveRevision: ((result: { content: string; sha256: string; size: number; isWorktreeEquivalentToRevision: boolean; comparisonOldContent: string | null }) => void) | undefined;
    hoisted.workspaceRevisionFileRead
      .mockResolvedValueOnce({ content: "disk before\n", sha256: "sha-first", size: 12, isWorktreeEquivalentToRevision: true, comparisonOldContent: "before\n" })
      .mockImplementationOnce(() => new Promise((resolve) => { resolveRevision = resolve; }));
    const beginPreparedSpy = vi.spyOn(DiffView.prototype, "beginPreparedEdit");
    const endEditSpy = vi.spyOn(DiffView.prototype, "endEdit");

    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [lastCommitFile], "last-commit-first-sig");
    await mounted;
    await startEdit();
    await vi.waitFor(() => expect(beginPreparedSpy).toHaveBeenCalledTimes(1));

    fireDiffSignature();
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    expect(endEditSpy).toHaveBeenCalledWith("editable.ts");
    resolveDiff(1, [lastCommitFile], "last-commit-refreshed-sig");
    await vi.waitFor(() => expect(hoisted.workspaceRevisionFileRead).toHaveBeenCalledTimes(2));
    // The manifest itself may paint, but an old commit editor never reattaches before the
    // single immutable-revision response settles.
    expect(beginPreparedSpy).toHaveBeenCalledTimes(1);

    resolveRevision!({ content: "disk before\n", sha256: "sha-refreshed", size: 12, isWorktreeEquivalentToRevision: true, comparisonOldContent: "before\n" });
    await vi.waitFor(() => expect(beginPreparedSpy).toHaveBeenCalledTimes(2));
    beginPreparedSpy.mockRestore();
    endEditSpy.mockRestore();
  });

  it("restores a dirty Last Commit edit after a failed refresh and guards it again when the retry succeeds", async () => {
    const lastCommitFile: DiffFileEntry = { ...editableFile, targetRevision: "r".repeat(40) };
    INIT_PAYLOAD = { ...INIT_PAYLOAD, workspaceState: { ...INIT_PAYLOAD.workspaceState, scope: { kind: "lastCommit" } } };
    let resolveRetryRevision: ((result: { content: string; sha256: string; size: number; isWorktreeEquivalentToRevision: boolean; comparisonOldContent: string | null }) => void) | undefined;
    hoisted.workspaceRevisionFileRead
      .mockResolvedValueOnce({ content: "disk before\n", sha256: "sha-original", size: 12, isWorktreeEquivalentToRevision: true, comparisonOldContent: "before\n" })
      .mockImplementationOnce(() => new Promise((resolve) => { resolveRetryRevision = resolve; }));
    const beginPreparedSpy = vi.spyOn(DiffView.prototype, "beginPreparedEdit");
    const endEditSpy = vi.spyOn(DiffView.prototype, "endEdit");

    try {
      const mounted = mountRoot(container);
      await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
      resolveDiff(0, [lastCommitFile], "last-commit-original");
      await mounted;
      await startEdit();
      capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "diff" }, { contents: "my unsaved edit\n" });

      useFakeTimersWithImmediatePaint();
      fireDiffSignature();
      await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
      expect(endEditSpy).toHaveBeenCalledWith("editable.ts");
      rejectDiff(1, new SpacesBridgeError("unavailable", "daemon reconnecting"));
      await vi.advanceTimersByTimeAsync(0);

      const recoveredHeader = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })!;
      expect(recoveredHeader.textContent).toContain("Editing");
      expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
        content: "my unsaved edit\n",
        dirty: true,
        baseSHA256: "sha-original",
        comparisonOldContent: "before\n",
      });

      await vi.advanceTimersByTimeAsync(1000);
      expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(3);
      expect(endEditSpy).toHaveBeenCalledTimes(2);
      resolveDiff(2, [lastCommitFile], "last-commit-retry");
      await vi.waitFor(() => expect(hoisted.workspaceRevisionFileRead).toHaveBeenCalledTimes(2));
      // The retry owns a fresh immutable check; restoring after the failed manifest does not make
      // the saved editor eligible to render against the retry's patch without verification.
      expect(beginPreparedSpy).toHaveBeenCalledTimes(2);

      resolveRetryRevision!({ content: "disk before\n", sha256: "sha-retry", size: 12, isWorktreeEquivalentToRevision: true, comparisonOldContent: "before\n" });
      await vi.waitFor(() => expect(beginPreparedSpy).toHaveBeenCalledTimes(3));
    } finally {
      beginPreparedSpy.mockRestore();
      endEditSpy.mockRestore();
    }
  });

  it("keeps a Last Commit session mounted across the refresh its own autosave triggers", async () => {
    const lastCommitFile: DiffFileEntry = { ...editableFile, targetRevision: "s".repeat(40) };
    INIT_PAYLOAD = { ...INIT_PAYLOAD, workspaceState: { ...INIT_PAYLOAD.workspaceState, scope: { kind: "lastCommit" } } };
    hoisted.workspaceRevisionFileRead
      .mockResolvedValueOnce({ content: "disk before\n", sha256: "sha-before", size: 12, isWorktreeEquivalentToRevision: true, comparisonOldContent: "before\n" })
      // The pane's own write is what moved the worktree away from the commit, so the second
      // verification reports a divergence that the session itself caused.
      .mockResolvedValueOnce({ content: "disk before\n", sha256: "sha-before", size: 12, isWorktreeEquivalentToRevision: false, comparisonOldContent: "before\n" });
    hoisted.workspaceFileWrite.mockResolvedValueOnce({ ok: true, sha256: "sha-autosaved" });
    hoisted.workspaceFileRead.mockResolvedValue({ content: "last commit edit\n", sha256: "sha-autosaved", size: 18 });

    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [lastCommitFile], "last-commit-autosave-first");
    await mounted;
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceRevisionFileRead).toHaveBeenCalledTimes(1));
    typeInEditor("last commit edit\n");

    pressSaveShortcut();
    await vi.waitFor(() =>
      expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith("editable.ts", "last commit edit\n", { baseSHA256: "sha-before", purpose: "inlineDiff" }),
    );
    // The save's own refresh: the session it just wrote for must come back, not vanish behind the
    // divergence guard, since Escape is what ends a session.
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [lastCommitFile], "last-commit-autosave-refreshed");

    // The refresh re-verifies against the commit and finds the worktree diverged, by this pane's
    // own hand, so the session comes back instead of being replaced by the guard message.
    await vi.waitFor(() => expect(hoisted.workspaceRevisionFileRead).toHaveBeenCalledTimes(2));
    await vi.waitFor(() => expect(capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })).toBeInstanceOf(HTMLElement));
    expect(editHeader().textContent).toContain("Editing");
    expect(editStatusChip()?.textContent).toBe("Saved");
    expect(container.querySelector<HTMLElement>("#code-pane-diff-edit-error")?.style.display).toBe("none");
    expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      path: "editable.ts",
      content: "last commit edit\n",
      baseSHA256: "sha-autosaved",
      dirty: false,
    });
  });

  it("still hibernates a Last Commit session when someone else moves the file away from the commit", async () => {
    const lastCommitFile: DiffFileEntry = { ...editableFile, targetRevision: "t".repeat(40) };
    INIT_PAYLOAD = { ...INIT_PAYLOAD, workspaceState: { ...INIT_PAYLOAD.workspaceState, scope: { kind: "lastCommit" } } };
    hoisted.workspaceRevisionFileRead
      .mockResolvedValueOnce({ content: "disk before\n", sha256: "sha-before", size: 12, isWorktreeEquivalentToRevision: true, comparisonOldContent: "before\n" })
      .mockResolvedValue({ content: "disk before\n", sha256: "sha-before", size: 12, isWorktreeEquivalentToRevision: false, comparisonOldContent: "before\n" });
    // The worktree holds someone else's bytes, not the ones this pane last wrote.
    hoisted.workspaceFileRead.mockResolvedValue({ content: "an agent's version\n", sha256: "sha-agent", size: 19 });

    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [lastCommitFile], "last-commit-diverged-first");
    await mounted;
    await startEdit();
    await vi.waitFor(() => expect(capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })).toBeInstanceOf(HTMLElement));

    fireDiffSignature();
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [lastCommitFile], "last-commit-diverged-refreshed");

    await vi.waitFor(() => expect(container.textContent).toContain("Workspace file changed since this commit."));
    expect(capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })).toBeUndefined();
  });

  it("turns an overlapping dirty Last Commit refresh into an explicit conflict against the verified new disk target", async () => {
    const base = "value = base\n";
    const disk = "value = remote\n";
    const initialFile = { ...editableFileForContent(base, "value = previous\n"), targetRevision: "j".repeat(40) };
    const refreshedFile = { ...editableFileForContent(disk, base), targetRevision: "k".repeat(40) };
    INIT_PAYLOAD = { ...INIT_PAYLOAD, workspaceState: { ...INIT_PAYLOAD.workspaceState, scope: { kind: "lastCommit" } } };
    hoisted.workspaceFileRead
      .mockResolvedValueOnce({ content: base, sha256: "sha-base", size: base.length })
      .mockResolvedValueOnce({ content: disk, sha256: "sha-disk", size: disk.length });
    hoisted.workspaceRevisionFileRead
      .mockResolvedValueOnce({ content: base, sha256: "sha-base", size: base.length, isWorktreeEquivalentToRevision: true })
      .mockResolvedValueOnce({ content: disk, sha256: "sha-disk", size: disk.length, isWorktreeEquivalentToRevision: true });
    const conflictSpy = vi.spyOn(DiffView.prototype, "setEditConflict");

    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [initialFile], "last-commit-overlap-initial");
    await mounted;
    await startEdit();
    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "diff" }, { contents: "value = mine\n" });

    fireDiffSignature();
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [refreshedFile], "last-commit-overlap-refreshed");
    await vi.waitFor(() => expect(conflictSpy).toHaveBeenCalledWith("editable.ts", { kind: "changed", diskContent: disk }));
    const snapshot = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}") as { diffEditorState?: CodePaneDiffEditorState };
    expect(snapshot.diffEditorState).toMatchObject({
      content: "value = mine\n",
      dirty: true,
      conflict: true,
      baseSHA256: "sha-disk",
      baseContent: disk,
      conflictBaseSHA256: "sha-disk",
    });
    conflictSpy.mockRestore();
  });

  it("three-way merges non-overlapping dirty Last Commit refreshes onto the verified disk baseline", async () => {
    const base = "mine base\nkeep\nremote base\n";
    const disk = "mine base\nkeep\nremote user\n";
    const mine = "mine user\nkeep\nremote base\n";
    const initialFile = { ...editableFileForContent(base, "previous\nkeep\nremote base\n"), targetRevision: "l".repeat(40) };
    const refreshedFile = { ...editableFileForContent(disk, base), targetRevision: "m".repeat(40) };
    INIT_PAYLOAD = { ...INIT_PAYLOAD, workspaceState: { ...INIT_PAYLOAD.workspaceState, scope: { kind: "lastCommit" } } };
    hoisted.workspaceFileRead
      .mockResolvedValueOnce({ content: base, sha256: "sha-base", size: base.length })
      .mockResolvedValueOnce({ content: disk, sha256: "sha-disk", size: disk.length });
    hoisted.workspaceRevisionFileRead
      .mockResolvedValueOnce({ content: base, sha256: "sha-base", size: base.length, isWorktreeEquivalentToRevision: true })
      .mockResolvedValueOnce({ content: disk, sha256: "sha-disk", size: disk.length, isWorktreeEquivalentToRevision: true });

    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [initialFile], "last-commit-merge-initial");
    await mounted;
    await startEdit();
    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "diff" }, { contents: mine });

    fireDiffSignature();
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [refreshedFile], "last-commit-merge-refreshed");
    await vi.waitFor(() => {
      const snapshot = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}") as { diffEditorState?: CodePaneDiffEditorState };
      expect(snapshot.diffEditorState).toMatchObject({
        content: "mine user\nkeep\nremote user\n",
        dirty: true,
        conflict: false,
        baseSHA256: "sha-disk",
        baseContent: disk,
      });
    });
  });

  it("rebuilds a ref editor's comparison side from the completed Last Commit patch while keeping its dirty buffer", async () => {
    const refFile = editableFileForContent("disk before\n", "ref comparison\n");
    const lastCommitFile = editableFileForContent("disk before\n", "commit comparison\n");
    lastCommitFile.targetRevision = "i".repeat(40);
    INIT_PAYLOAD = {
      ...INIT_PAYLOAD,
      workspaceState: { ...INIT_PAYLOAD.workspaceState, scope: { kind: "ref", refName: "main" } },
    };
    hoisted.workspaceFileRead
      .mockResolvedValueOnce({ content: "disk before\n", sha256: "sha-ref", size: 12 })
      .mockResolvedValueOnce({ content: "disk before\n", sha256: "sha-commit", size: 12 });
    hoisted.workspaceRevisionFileRead.mockResolvedValueOnce({
      content: "disk before\n", sha256: "sha-commit", size: 12, isWorktreeEquivalentToRevision: true,
      comparisonOldContent: "commit comparison\n",
    });

    await mountEditableDiff(refFile);
    await startEdit();
    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "diff" }, { contents: "my dirty edit\n" });

    switchToLastCommit(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [lastCommitFile], "last-commit-comparison-sig");
    await vi.waitFor(() => {
      const snapshot = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}") as { diffEditorState?: CodePaneDiffEditorState };
      expect(snapshot.diffEditorState).toMatchObject({
        content: "my dirty edit\n",
        dirty: true,
        baseSHA256: "sha-commit",
        comparisonOldContent: "commit comparison\n",
      });
    });
  });

  it("rebuilds a dirty Last Commit editor from the completed Uncommitted patch before restoring it", async () => {
    const lastCommitFile = editableFileForContent("disk before\n", "commit comparison\n");
    lastCommitFile.targetRevision = "s".repeat(40);
    const uncommittedFile = editableFileForContent("disk before\n", "working comparison\n");
    INIT_PAYLOAD = { ...INIT_PAYLOAD, workspaceState: { ...INIT_PAYLOAD.workspaceState, scope: { kind: "lastCommit" } } };
    hoisted.workspaceFileRead.mockResolvedValue({ content: "disk before\n", sha256: "sha-disk", size: 12 });
    hoisted.workspaceRevisionFileRead.mockResolvedValue({
      content: "disk before\n", sha256: "sha-commit", size: 12, isWorktreeEquivalentToRevision: true,
    });

    await mountEditableDiff(lastCommitFile);
    await startEdit();
    await vi.waitFor(() => expect(capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })).toBeDefined());
    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "diff" }, { contents: "my dirty edit\n" });

    switchToUncommitted(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [uncommittedFile], "uncommitted-rebuilt-comparison");
    await vi.waitFor(() => {
      const snapshot = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}") as { diffEditorState?: CodePaneDiffEditorState };
      expect(snapshot.diffEditorState).toMatchObject({
        content: "my dirty edit\n",
        dirty: true,
        comparisonOldContent: "working comparison\n",
      });
    });
  });

  it("writes a dirty buffer once across a scope switch and comes back clean", async () => {
    const lastCommitFile = editableFileForContent("disk before\n", "commit comparison\n");
    lastCommitFile.targetRevision = "u".repeat(40);
    const uncommittedFile = editableFileForContent("my dirty edit\n", "working comparison\n");
    INIT_PAYLOAD = { ...INIT_PAYLOAD, workspaceState: { ...INIT_PAYLOAD.workspaceState, scope: { kind: "lastCommit" } } };
    hoisted.workspaceRevisionFileRead.mockResolvedValue({
      content: "disk before\n", sha256: "sha-commit", size: 12, isWorktreeEquivalentToRevision: true,
      comparisonOldContent: "commit comparison\n",
    });
    hoisted.workspaceFileWrite.mockResolvedValue({ ok: true, sha256: "sha-switched" });

    await mountEditableDiff(lastCommitFile);
    await startEdit();
    await vi.waitFor(() => expect(capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })).toBeInstanceOf(HTMLElement));
    typeInEditor("my dirty edit\n");

    // The switch writes the buffer on its way out. That write's result belongs to this buffer even
    // though the pane stops rendering it a moment later, so the hibernated snapshot has to carry
    // the hash it produced: anything else makes the restored session write the same bytes again.
    hoisted.workspaceFileRead.mockResolvedValue({ content: "my dirty edit\n", sha256: "sha-switched", size: 15 });
    switchToUncommitted(container);
    await vi.waitFor(() => expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      content: "my dirty edit\n",
      baseSHA256: "sha-switched",
      dirty: false,
    }));
    expect(hoisted.workspaceFileWrite).toHaveBeenCalledTimes(1);

    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [uncommittedFile], "uncommitted-after-switch");

    await vi.waitFor(() => expect(capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })).toBeInstanceOf(HTMLElement));
    expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      content: "my dirty edit\n",
      baseSHA256: "sha-switched",
      dirty: false,
      comparisonOldContent: "working comparison\n",
    });
    // The restored session has nothing left to write: one buffer, one write.
    expect(hoisted.workspaceFileWrite).toHaveBeenCalledTimes(1);
  });

  it("keeps a dirty editor reachable when a completed scope change cannot read its baseline", async () => {
    const lastCommitFile = editableFileForContent("disk before\n", "commit comparison\n");
    lastCommitFile.targetRevision = "v".repeat(40);
    const uncommittedFile = editableFileForContent("disk before\n", "working comparison\n");
    INIT_PAYLOAD = { ...INIT_PAYLOAD, workspaceState: { ...INIT_PAYLOAD.workspaceState, scope: { kind: "lastCommit" } } };
    hoisted.workspaceRevisionFileRead.mockResolvedValue({
      content: "disk before\n", sha256: "sha-commit", size: 12, isWorktreeEquivalentToRevision: true,
      comparisonOldContent: "commit comparison\n",
    });

    await mountEditableDiff(lastCommitFile);
    await startEdit();
    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "diff" }, { contents: "my dirty edit\n" });
    hoisted.workspaceFileRead.mockRejectedValueOnce(new SpacesBridgeError("internalError", "baseline unavailable"));

    switchToUncommitted(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [uncommittedFile], "uncommitted-baseline-failure");

    await vi.waitFor(() => expect(container.querySelector("#code-pane-diff-edit-error")?.textContent).toContain("Your edits are kept here"));
    const header = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })!;
    expect(header.textContent).toContain("Editing");
    expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      content: "my dirty edit\n", dirty: true, comparisonOldContent: "commit comparison\n",
    });
  });

  it("restores a hibernated dirty editor when the new scope manifest fails", async () => {
    const lastCommitFile = editableFileForContent("disk before\n", "commit comparison\n");
    lastCommitFile.targetRevision = "w".repeat(40);
    INIT_PAYLOAD = { ...INIT_PAYLOAD, workspaceState: { ...INIT_PAYLOAD.workspaceState, scope: { kind: "lastCommit" } } };
    hoisted.workspaceRevisionFileRead.mockResolvedValue({
      content: "disk before\n", sha256: "sha-commit", size: 12, isWorktreeEquivalentToRevision: true,
      comparisonOldContent: "commit comparison\n",
    });

    await mountEditableDiff(lastCommitFile);
    await startEdit();
    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "diff" }, { contents: "my dirty edit\n" });
    switchToUncommitted(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    rejectDiff(1, new SpacesBridgeError("invalidArgument", "comparison unavailable"));

    await vi.waitFor(() => expect(container.querySelector("#code-pane-diff-edit-error")?.textContent).toContain("Your edits are kept here"));
    const header = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })!;
    expect(header.textContent).toContain("Editing");
    expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      content: "my dirty edit\n", dirty: true, comparisonOldContent: "commit comparison\n",
    });
  });

  it("keeps a dirty draft recoverable when entering Last Commit cannot load its manifest", async () => {
    hoisted.workspaceFileRead.mockResolvedValue({ content: "disk before\n", sha256: "sha-disk", size: 12 });
    await mountEditableDiff();
    await startEdit();
    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "diff" }, { contents: "my dirty edit\n" });

    switchToLastCommit(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    rejectDiff(1, new SpacesBridgeError("unavailable", "daemon reconnecting"));

    await vi.waitFor(() => expect(container.querySelector("#code-pane-diff-edit-error")?.textContent).toBe(
      "Couldn't load Last Commit. Switch to Uncommitted to continue editing this draft.",
    ));
    expect(capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })).toBeUndefined();
    expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      content: "my dirty edit\n", dirty: true,
    });

    switchToUncommitted(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(3));
    resolveDiff(2, [editableFile], "uncommitted-recovery-after-last-failure");
    await vi.waitFor(() => {
      const header = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })!;
      expect(header.textContent).toContain("Editing");
    });
  });

  it("restores a verified dirty Last Commit editor after its patch stream aborts", async () => {
    const lastCommitFile: DiffFileEntry = { ...editableFile, targetRevision: "x".repeat(40) };
    INIT_PAYLOAD = { ...INIT_PAYLOAD, workspaceState: { ...INIT_PAYLOAD.workspaceState, scope: { kind: "lastCommit" } } };
    hoisted.workspaceRevisionFileRead.mockResolvedValue({
      content: "disk before\n", sha256: "sha-verified", size: 12,
      isWorktreeEquivalentToRevision: true, comparisonOldContent: "before\n",
    });
    hoisted.workspaceDiffManifestRelease.mockClear();
    const beginEditSpy = vi.spyOn(DiffView.prototype, "beginEdit");

    await mountEditableDiff(lastCommitFile);
    await vi.waitFor(() => expect(hoisted.workspaceDiffManifestRelease).toHaveBeenCalledTimes(1));
    await startEdit();
    await vi.waitFor(() => expect(capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })).toBeDefined());
    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "diff" }, { contents: "my dirty edit\n" });
    expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({ dirty: true });

    useFakeTimersWithImmediatePaint();
    hoisted.workspaceDiffFileChunk.mockRejectedValueOnce(new Error("patch transport dropped"));
    fireDiffSignature();
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [lastCommitFile], "last-commit-patch-abort");
    await vi.advanceTimersByTimeAsync(0);

    expect(container.querySelector("#code-pane-diff-edit-error")?.textContent).toBe("Couldn't load diff. Try again.");
    expect(beginEditSpy).toHaveBeenCalledTimes(1);
    await vi.waitFor(() => {
      const header = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })!;
      expect(header.textContent).toContain("Editing");
    });
    beginEditSpy.mockRestore();
  });

  it("restores a dirty editor's editing surface when a scope-transition patch stream aborts", async () => {
    const lastCommitFile: DiffFileEntry = { ...editableFile, targetRevision: "y".repeat(40) };
    const uncommittedFile = editableFileForContent("disk before\n", "uncommitted comparison\n");
    INIT_PAYLOAD = { ...INIT_PAYLOAD, workspaceState: { ...INIT_PAYLOAD.workspaceState, scope: { kind: "lastCommit" } } };
    hoisted.workspaceRevisionFileRead.mockResolvedValue({
      content: "disk before\n", sha256: "sha-verified", size: 12,
      isWorktreeEquivalentToRevision: true, comparisonOldContent: "commit comparison\n",
    });
    hoisted.workspaceDiffManifestRelease.mockClear();

    await mountEditableDiff(lastCommitFile);
    await vi.waitFor(() => expect(hoisted.workspaceDiffManifestRelease).toHaveBeenCalledTimes(1));
    await startEdit();
    await vi.waitFor(() => expect(capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })).toBeDefined());
    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "diff" }, { contents: "my dirty edit\n" });

    useFakeTimersWithImmediatePaint();
    hoisted.workspaceDiffFileChunk.mockRejectedValueOnce(new Error("patch transport dropped"));
    switchToUncommitted(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [uncommittedFile], "uncommitted-patch-abort");
    await vi.advanceTimersByTimeAsync(0);

    await vi.waitFor(() => expect(container.querySelector("#code-pane-diff-edit-error")?.textContent).toContain("Your edits are kept here"));
    const header = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })!;
    expect(header.textContent).toContain("Editing");
    expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      content: "my dirty edit\n", dirty: true, comparisonOldContent: "commit comparison\n",
    });
  });

  it("restores a dirty Last Commit draft as a recovery editor when the new scope omits its path", async () => {
    const lastCommitFile = editableFileForContent("disk before\n", "commit comparison\n");
    lastCommitFile.targetRevision = "u".repeat(40);
    const saved: CodePaneDiffEditorState = {
      path: "editable.ts",
      baseSHA256: "sha-disk",
      baseContent: "disk before\n",
      comparisonOldContent: "commit comparison\n",
      content: "my dirty edit\n",
      dirty: true,
      conflict: false,
      conflictBaseSHA256: null,
    };
    INIT_PAYLOAD = {
      ...INIT_PAYLOAD,
      workspaceState: { ...INIT_PAYLOAD.workspaceState, scope: { kind: "lastCommit" }, diffEditorState: saved },
    };
    hoisted.workspaceRevisionFileRead.mockResolvedValue({
      content: "disk before\n",
      sha256: "sha-disk",
      size: 12,
      isWorktreeEquivalentToRevision: true,
      comparisonOldContent: "commit comparison\n",
    });
    // Only the following Uncommitted recovery uses an ordinary live read; Last Commit itself
    // must get its baseline from the guarded revision response above.
    // The native payload encodes no requested comparison as JSON null. When the destination
    // scope omits this path, that must still use the live disk baseline as its synthetic left side.
    hoisted.workspaceFileRead.mockResolvedValue({
      content: "disk before\n", sha256: "sha-disk", size: 12, comparisonOldContent: null,
    });

    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [lastCommitFile], "last-commit-draft");
    await mounted;
    await vi.waitFor(() => expect(editStatusChip()?.textContent).toBe("Unsaved"));

    switchToUncommitted(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [], "uncommitted-clean");
    await vi.waitFor(() => {
      const snapshot = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}") as { diffEditorState?: CodePaneDiffEditorState };
      expect(snapshot.diffEditorState).toMatchObject({
        content: "my dirty edit\n",
        dirty: true,
        comparisonOldContent: "disk before\n",
      });
    });
    const header = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })!;
    expect(header.textContent).toContain("Editing");
  });

  it("keeps a Last Commit review visible and directs an omitted dirty draft back to Uncommitted", async () => {
    hoisted.workspaceFileRead.mockResolvedValue({ content: "disk before\n", sha256: "sha-disk", size: 12 });
    await mountEditableDiff();
    await startEdit();
    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "diff" }, { contents: "my dirty edit\n" });

    switchToLastCommit(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [makeFile("other.ts")], "last-commit-omits-draft");

    await vi.waitFor(() => expect(container.querySelector("#code-pane-diff-edit-error")?.textContent).toBe(
      "This draft is not part of Last Commit. Switch to Uncommitted to continue editing this draft.",
    ));
    expect(container.textContent).toContain("other.ts");
    expect(capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })).toBeUndefined();
    expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      content: "my dirty edit\n", dirty: true,
    });

    switchToUncommitted(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(3));
    resolveDiff(2, [editableFile], "uncommitted-after-last-omission");
    await vi.waitFor(() => {
      const header = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })!;
      expect(header.textContent).toContain("Editing");
    });
  });

  it("rejects a stale Last Commit restore after its manifest generation is superseded", async () => {
    const saved: CodePaneDiffEditorState = {
      path: "editable.ts",
      baseSHA256: "sha-saved",
      baseContent: "disk before\n",
      comparisonOldContent: "before\n",
      content: "unsaved draft\n",
      dirty: true,
      conflict: false,
      conflictBaseSHA256: null,
    };
    INIT_PAYLOAD = { ...INIT_PAYLOAD, workspaceState: { ...INIT_PAYLOAD.workspaceState, scope: { kind: "lastCommit" }, diffEditorState: saved } };
    const pendingReads: Array<(result: { content: string; sha256: string; size: number; isWorktreeEquivalentToRevision: boolean; comparisonOldContent: string | null }) => void> = [];
    hoisted.workspaceRevisionFileRead.mockImplementation(
      () => new Promise((resolve) => pendingReads.push(resolve)),
    );
    const beginPreparedSpy = vi.spyOn(DiffView.prototype, "beginPreparedEdit");
    const first: DiffFileEntry = { ...editableFile, targetRevision: "f".repeat(40) };
    const second: DiffFileEntry = { ...editableFile, targetRevision: "g".repeat(40) };

    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [first], "last-commit-first-sig");
    await mounted;
    await vi.waitFor(() => expect(pendingReads).toHaveLength(1));
    fireDiffSignature();
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [second], "last-commit-second-sig");
    await vi.waitFor(() => expect(pendingReads).toHaveLength(2));

    pendingReads[0]!({ content: "disk before\n", sha256: "sha-old", size: 12, isWorktreeEquivalentToRevision: true, comparisonOldContent: "before\n" });
    await Promise.resolve();
    await Promise.resolve();
    expect(beginPreparedSpy).not.toHaveBeenCalled();

    pendingReads[1]!({ content: "disk before\n", sha256: "sha-new", size: 12, isWorktreeEquivalentToRevision: true, comparisonOldContent: "before\n" });
    await vi.waitFor(() => expect(beginPreparedSpy).toHaveBeenCalledTimes(1));
    beginPreparedSpy.mockRestore();
  });

  it("runs the same immutable-revision guard before restoring a Last Commit inline editor", async () => {
    const lastCommitFile: DiffFileEntry = {
      ...editableFile,
      targetRevision: "b".repeat(40),
    };
    INIT_PAYLOAD = {
      ...INIT_PAYLOAD,
      workspaceState: {
        ...INIT_PAYLOAD.workspaceState,
        scope: { kind: "lastCommit" },
        diffEditorState: {
          path: "editable.ts",
          baseSHA256: "sha-saved",
          baseContent: "disk before\n",
          comparisonOldContent: "before\n",
          content: "unsaved draft\n",
          dirty: true,
          conflict: false,
          conflictBaseSHA256: null,
        },
      },
    };
    hoisted.workspaceFileRead.mockResolvedValue({ content: "worktree churn\n", sha256: "sha-worktree", size: 15 });
    hoisted.workspaceRevisionFileRead.mockResolvedValue({ content: "disk before\n", sha256: "sha-commit", size: 12 });
    const beginEditSpy = vi.spyOn(DiffView.prototype, "beginPreparedEdit");

    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [lastCommitFile], "last-commit-restore-sig");
    await mounted;
    await vi.waitFor(() =>
      expect(hoisted.workspaceRevisionFileRead).toHaveBeenCalledWith({
        path: "editable.ts",
        revision: "b".repeat(40),
      }),
    );
    await vi.waitFor(() =>
      expect(container.querySelector("#code-pane-diff-edit-error")?.textContent).toBe(
        "Workspace file changed since this commit. Switch to Uncommitted to edit it.",
      ),
    );
    expect(beginEditSpy).not.toHaveBeenCalled();
    expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      path: "editable.ts",
      content: "unsaved draft\n",
      dirty: true,
    });
    beginEditSpy.mockRestore();
  });

  it("keeps a Last Commit draft dormant through a transient revision-read failure and retries its guard", async () => {
    const lastCommitFile: DiffFileEntry = {
      ...editableFile,
      targetRevision: "c".repeat(40),
    };
    INIT_PAYLOAD = {
      ...INIT_PAYLOAD,
      workspaceState: {
        ...INIT_PAYLOAD.workspaceState,
        scope: { kind: "lastCommit" },
        diffEditorState: {
          path: "editable.ts",
          baseSHA256: "sha-saved",
          baseContent: "disk before\n",
          comparisonOldContent: "before\n",
          content: "unsaved draft\n",
          dirty: true,
          conflict: false,
          conflictBaseSHA256: null,
        },
      },
    };
    hoisted.workspaceFileRead.mockResolvedValue({ content: "disk before\n", sha256: "sha-commit", size: 12 });
    hoisted.workspaceRevisionFileRead
      .mockRejectedValueOnce(new Error("revision service reconnecting"))
      .mockResolvedValue({ content: "disk before\n", sha256: "sha-commit", size: 12, isWorktreeEquivalentToRevision: true });
    const beginEditSpy = vi.spyOn(DiffView.prototype, "beginPreparedEdit");

    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [lastCommitFile], "last-commit-retry-sig");
    await mounted;
    await vi.waitFor(() =>
      expect(container.querySelector("#code-pane-diff-edit-error")?.textContent).toBe(
        "Couldn't verify this commit's file. Switch to Uncommitted to edit it.",
      ),
    );
    expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      path: "editable.ts",
      content: "unsaved draft\n",
      dirty: true,
    });
    expect(beginEditSpy).not.toHaveBeenCalled();

    hoisted.diffSignatureCallbacks.at(-1)!();
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [lastCommitFile], "last-commit-retry-success-sig");
    await vi.waitFor(() =>
      expect(beginEditSpy).toHaveBeenCalledWith(
        expect.objectContaining({ path: "editable.ts", content: "unsaved draft\n", oldContent: "before\n" }),
        true,
      ),
    );
    expect(container.querySelector("#code-pane-diff-edit-error")?.textContent).toBe("");
    beginEditSpy.mockRestore();
  });

  it("retains typing made after Save was clicked as dirty against the write's returned hash", async () => {
    hoisted.workspaceFileRead.mockResolvedValue({ content: "disk before\n", sha256: "sha-before", size: 12 });
    let resolveWrite: ((result: { ok: true; sha256: string }) => void) | undefined;
    hoisted.workspaceFileWrite.mockImplementationOnce(
      () => new Promise((resolve) => {
        resolveWrite = resolve;
      }),
    );
    await mountEditableDiff();
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));
    await vi.waitFor(() => expect(capturedCodeViewOptions.current?.renderHeaderMetadata).toBeDefined());

    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "diff" }, { contents: "saved text\n" });
    pressSaveShortcut();
    await vi.waitFor(() => expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith("editable.ts", "saved text\n", { baseSHA256: "sha-before", purpose: "inlineDiff" }));

    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "diff" }, { contents: "typed after save\n" });
    resolveWrite!({ ok: true, sha256: "sha-saved" });

    await vi.waitFor(() =>
      expect(
        hoisted.notifyWorkspaceStateChanged.mock.calls
          .map(([snapshot]) => snapshot as { diffEditorState: Record<string, unknown> | null })
          .some(
            (snapshot) =>
              snapshot.diffEditorState?.content === "typed after save\n" &&
              snapshot.diffEditorState.baseSHA256 === "sha-saved" &&
              snapshot.diffEditorState.baseContent === "saved text\n" &&
              snapshot.diffEditorState.dirty === true,
          ),
      ).toBe(true),
    );
  });

  it("ignores a stale reconciliation read after a save advances the CAS baseline", async () => {
    const testFile = editableFileForContent("before\n");
    let resolveReconcileRead: ((result: { content: string; sha256: string; size: number }) => void) | undefined;
    hoisted.workspaceFileRead
      .mockResolvedValueOnce({ content: "before\n", sha256: "sha-before", size: 7 })
      .mockImplementationOnce(
        () => new Promise((resolve) => {
          resolveReconcileRead = resolve;
        }),
      );
    let resolveWrite: ((result: { ok: true; sha256: string }) => void) | undefined;
    hoisted.workspaceFileWrite.mockImplementationOnce(
      () => new Promise((resolve) => {
        resolveWrite = resolve;
      }),
    );
    await mountEditableDiff(testFile);
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));

    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "diff" }, { contents: "saved\n" });
    // Start the signature refresh before Save. Its file read is deliberately held while the save
    // completes, so the eventual snapshot has the old CAS baseline.
    hoisted.diffSignatureCallbacks.at(-1)!();
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [testFile], "stale-reconcile");
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledTimes(2));

    pressSaveShortcut();
    await vi.waitFor(() => expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith(
      "editable.ts",
      "saved\n",
      { baseSHA256: "sha-before", purpose: "inlineDiff" },
    ));
    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "diff" }, { contents: "typed after save\n" });
    resolveWrite!({ ok: true, sha256: "sha-saved" });
    await vi.waitFor(() => expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      content: "typed after save\n",
      baseSHA256: "sha-saved",
      baseContent: "saved\n",
      dirty: true,
    }));

    // This is the old read completing after the write reply. It must not move the newly adopted
    // CAS baseline backward or merge stale disk contents into the newer edit session. Let the
    // resolved read's continuation run before checking that no reconciliation write occurred.
    const statePushesBeforeStaleRead = hoisted.notifyWorkspaceStateChanged.mock.calls.length;
    resolveReconcileRead!({ content: "stale disk\n", sha256: "sha-stale", size: 11 });
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(hoisted.notifyWorkspaceStateChanged.mock.calls.length).toBe(statePushesBeforeStaleRead);
    expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      content: "typed after save\n",
      baseSHA256: "sha-saved",
      baseContent: "saved\n",
      dirty: true,
      conflict: false,
    });
  });

  it("treats a disk refresh matching the saved buffer as clean before the CAS reply", async () => {
    const testFile = editableFileForContent("before\n");
    hoisted.workspaceFileRead
      .mockResolvedValueOnce({ content: "before\n", sha256: "sha-before", size: 7 })
      .mockResolvedValueOnce({ content: "saved\n", sha256: "sha-saved", size: 6 });
    let resolveWrite: ((result: { ok: true; sha256: string }) => void) | undefined;
    hoisted.workspaceFileWrite.mockImplementationOnce(
      () => new Promise((resolve) => {
        resolveWrite = resolve;
      }),
    );
    await mountEditableDiff(testFile);
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));

    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "diff" }, { contents: "saved\n" });
    pressSaveShortcut();
    await vi.waitFor(() => expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith(
      "editable.ts",
      "saved\n",
      { baseSHA256: "sha-before", purpose: "inlineDiff" },
    ));

    // The write has landed on disk, but its reply is still in flight. A file-signature refresh
    // therefore reconciles the exact saved buffer before saveDiffEdit can process the CAS result.
    hoisted.diffSignatureCallbacks.at(-1)!();
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [testFile], "saved-signature");
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledTimes(2));
    await vi.waitFor(() => {
      const snapshot = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}");
      expect(snapshot.diffEditorState).toMatchObject({
        path: "editable.ts",
        content: "saved\n",
        baseSHA256: "sha-saved",
        baseContent: "saved\n",
        dirty: false,
        conflict: false,
      });
    });

    // The late success belongs to the same write and must not resurrect a dirty editor or a
    // conflict after reconciliation already established that disk and the buffer agree. The
    // session stays open on that agreed baseline; saving never closes an editor.
    resolveWrite!({ ok: true, sha256: "sha-saved" });
    await vi.waitFor(() => expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      path: "editable.ts",
      content: "saved\n",
      baseSHA256: "sha-saved",
      dirty: false,
      conflict: false,
    }));
  });

  it("ignores a late save failure after a matching disk refresh proved the write landed", async () => {
    const testFile = editableFileForContent("before\n");
    hoisted.workspaceFileRead
      .mockResolvedValueOnce({ content: "before\n", sha256: "sha-before", size: 7 })
      .mockResolvedValueOnce({ content: "saved\n", sha256: "sha-saved", size: 6 });
    let rejectWrite: ((error: unknown) => void) | undefined;
    hoisted.workspaceFileWrite.mockImplementationOnce(
      () => new Promise((_, reject) => {
        rejectWrite = reject;
      }),
    );
    await mountEditableDiff(testFile);
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));

    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "diff" }, { contents: "saved\n" });
    pressSaveShortcut();
    await vi.waitFor(() => expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith(
      "editable.ts",
      "saved\n",
      { baseSHA256: "sha-before", purpose: "inlineDiff" },
    ));

    hoisted.diffSignatureCallbacks.at(-1)!();
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [testFile], "saved-before-rejection");
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledTimes(2));
    await vi.waitFor(() => expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      content: "saved\n",
      baseSHA256: "sha-saved",
      dirty: false,
      conflict: false,
    }));

    // The RPC response was lost after the signature read observed the write on disk. That late
    // rejection is superseded by the stronger disk observation and must not show a false failure.
    rejectWrite!(new SpacesBridgeError("unavailable", "response lost"));
    await vi.waitFor(() => {
      expect(container.querySelector<HTMLElement>("#code-pane-diff-edit-error")?.style.display).toBe("none");
      expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
        content: "saved\n",
        baseSHA256: "sha-saved",
        dirty: false,
        conflict: false,
      });
    });
  });

  it("reconciles a disk snapshot against typing that lands while its read is in flight", async () => {
    const testFile = editableFileForContent("line 1\nline 2\nline 3\n");
    let resolveReconcileRead: ((result: { content: string; sha256: string; size: number }) => void) | undefined;
    hoisted.workspaceFileRead
      .mockResolvedValueOnce({ content: "line 1\nline 2\nline 3\n", sha256: "sha-before", size: 21 })
      .mockImplementationOnce(
        () => new Promise((resolve) => {
          resolveReconcileRead = resolve;
        }),
      );
    await mountEditableDiff(testFile);
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));
    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "diff" }, { contents: "line 1 mine\nline 2\nline 3\n" });

    hoisted.diffSignatureCallbacks.at(-1)!();
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [testFile], "typing-during-reconcile");
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledTimes(2));

    // The disk read is still pending when the user edits the current buffer again. Reconciliation
    // must use this latest same-session content rather than discard the disk snapshot as stale.
    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "diff" }, { contents: "line 1 mine\nline 2\nline 3\n" });
    resolveReconcileRead!({ content: "line 1\nline 2\nline 3 from disk\n", sha256: "sha-disk", size: 34 });

    await vi.waitFor(() => expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      path: "editable.ts",
      content: "line 1 mine\nline 2\nline 3 from disk\n",
      baseSHA256: "sha-disk",
      baseContent: "line 1\nline 2\nline 3 from disk\n",
      comparisonOldContent: "before\n",
      dirty: true,
      conflict: false,
    }));
  });

  it("keeps reconciled content when an older in-flight save resolves afterward", async () => {
    const testFile = editableFileForContent("line 1\nline 2\nline 3\nline 4\n");
    hoisted.workspaceFileRead
      .mockResolvedValueOnce({ content: "line 1\nline 2\nline 3\nline 4\n", sha256: "sha-before", size: 28 })
      .mockResolvedValueOnce({ content: "line 1\nline 2\nline 3\nline 4 from disk\n", sha256: "sha-disk", size: 38 });
    let resolveWrite: ((result: { ok: true; sha256: string }) => void) | undefined;
    hoisted.workspaceFileWrite.mockImplementationOnce(
      () => new Promise((resolve) => {
        resolveWrite = resolve;
      }),
    );
    await mountEditableDiff(testFile);
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));

    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "diff" }, { contents: "line 1 from mine\nline 2\nline 3\nline 4\n" });
    pressSaveShortcut();
    await vi.waitFor(() => expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith(
      "editable.ts",
      "line 1 from mine\nline 2\nline 3\nline 4\n",
      { baseSHA256: "sha-before", purpose: "inlineDiff" },
    ));

    // The external refresh reconciles a non-overlapping disk edit while the old CAS write is
    // unresolved. Its generation bump must make the eventual old success retain this merge.
    hoisted.diffSignatureCallbacks.at(-1)!();
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [testFile], "reconcile-in-flight-save");
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledTimes(2));
    await vi.waitFor(() => expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      content: "line 1 from mine\nline 2\nline 3\nline 4 from disk\n",
      dirty: true,
    }));

    // The older write's success adopts the baseline it actually created on disk, but it must not
    // roll the live buffer back to the content it submitted: the merged text survives, still dirty
    // against that new baseline so the scheduler's next pass writes it.
    resolveWrite!({ ok: true, sha256: "sha-saved" });
    await vi.waitFor(() => {
      const snapshot = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}");
      expect(snapshot.diffEditorState).toMatchObject({
        path: "editable.ts",
        content: "line 1 from mine\nline 2\nline 3\nline 4 from disk\n",
        baseSHA256: "sha-saved",
        baseContent: "line 1 from mine\nline 2\nline 3\nline 4\n",
        dirty: true,
        conflict: false,
      });
    });
  });

  it("clears an already-conflicted editor when its Keep mine write lands before the reply", async () => {
    const testFile = editableFileForContent("before\n");
    hoisted.workspaceFileRead
      .mockResolvedValueOnce({ content: "before\n", sha256: "sha-before", size: 7 })
      .mockResolvedValueOnce({ content: "disk version\n", sha256: "sha-disk", size: 13 })
      .mockResolvedValueOnce({ content: "my version\n", sha256: "sha-mine", size: 11 });
    let resolveWrite: ((result: { ok: true; sha256: string }) => void) | undefined;
    hoisted.workspaceFileWrite.mockImplementationOnce(
      () => new Promise((resolve) => {
        resolveWrite = resolve;
      }),
    );
    const setConflictSpy = vi.spyOn(DiffView.prototype, "setEditConflict");
    await mountEditableDiff(testFile);
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));
    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "diff" }, { contents: "my version\n" });

    // First refresh establishes the read-only conflict comparison.
    hoisted.diffSignatureCallbacks.at(-1)!();
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [testFile], "conflict-before-keep-mine");
    await vi.waitFor(() => expect(setConflictSpy).toHaveBeenCalledWith(
      "editable.ts",
      { kind: "changed", diskContent: "disk version\n" },
    ));
    const conflictHeader = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })!;
    conflictHeader.querySelector<HTMLButtonElement>("button:last-of-type")!.click();
    await vi.waitFor(() => expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith(
      "editable.ts",
      "my version\n",
      { baseSHA256: "sha-disk", purpose: "inlineDiff" },
    ));

    // Keep mine has landed, but its reply is still in flight. The next signature refresh observes
    // disk == the frozen buffer and must rebuild the normal editable renderer before that reply.
    hoisted.diffSignatureCallbacks.at(-1)!();
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(3));
    resolveDiff(2, [editableFile], "conflict-resolved-before-reply");
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledTimes(3));
    await vi.waitFor(() => {
      const header = editHeader();
      expect(header.textContent).toContain("Editing");
      expect(header.textContent).not.toContain("Workspace changed");
      expect([...header.querySelectorAll("button")].map((button) => button.textContent)).toEqual([]);
    });

    // The reply lands on an editor the refresh already made clean, so the session simply stays open
    // on the written baseline rather than closing under the user.
    resolveWrite!({ ok: true, sha256: "sha-mine" });
    await vi.waitFor(() => expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      path: "editable.ts",
      content: "my version\n",
      baseSHA256: "sha-mine",
      dirty: false,
      conflict: false,
    }));
    setConflictSpy.mockRestore();
  });

  it("writes dirty A before opening B, against B's own baseline", async () => {
    const first = editableFileForContent("first disk\n");
    const second: DiffFileEntry = { ...editableFileForContent("second disk\n"), path: "second.ts" };
    hoisted.workspaceFileRead
      .mockResolvedValueOnce({ content: "first disk\n", sha256: "sha-first", size: 11 })
      .mockResolvedValueOnce({ content: "second disk\n", sha256: "sha-second", size: 12 });
    hoisted.workspaceFileWrite.mockResolvedValueOnce({ ok: true, sha256: "sha-first-saved" });
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [first, second], "handover-sig");
    await mounted;

    await startEdit("editable.ts");
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));
    typeInEditor("first edited\n");

    // A line click on another file is the handover: A's buffer is written first, and only then is
    // B's baseline read. Nothing is discarded and nothing is asked of the user.
    await startEdit("second.ts");

    await vi.waitFor(() =>
      expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith("editable.ts", "first edited\n", { baseSHA256: "sha-first", purpose: "inlineDiff" }),
    );
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("second.ts", "inlineDiff"));
    await vi.waitFor(() =>
      expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
        path: "second.ts",
        baseSHA256: "sha-second",
        dirty: false,
      }),
    );
  });

  it("opens B after writing dirty A, even in Last Commit where the write refreshes the diff", async () => {
    const first = { ...editableFileForContent("first disk\n"), targetRevision: "w".repeat(40) };
    const second: DiffFileEntry = { ...editableFileForContent("second disk\n"), path: "second.ts", targetRevision: "w".repeat(40) };
    INIT_PAYLOAD = { ...INIT_PAYLOAD, workspaceState: { ...INIT_PAYLOAD.workspaceState, scope: { kind: "lastCommit" } } };
    hoisted.workspaceRevisionFileRead.mockImplementation(async ({ path }: { path: string }) =>
      path === "second.ts"
        ? { content: "second disk\n", sha256: "sha-second", size: 12, isWorktreeEquivalentToRevision: true, comparisonOldContent: "second before\n" }
        : { content: "first disk\n", sha256: "sha-first", size: 11, isWorktreeEquivalentToRevision: true, comparisonOldContent: "before\n" },
    );
    hoisted.workspaceFileWrite.mockResolvedValueOnce({ ok: true, sha256: "sha-first-saved" });

    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [first, second], "last-commit-handover-first");
    await mounted;
    await startEdit("editable.ts");
    await vi.waitFor(() => expect(hoisted.workspaceRevisionFileRead).toHaveBeenCalledTimes(1));
    typeInEditor("first edited\n");

    // The write that hands the surface over also refreshes the diff, and in this scope that refresh
    // hibernates the editor on its way through. That is the pane's own bookkeeping, not the user
    // asking for something newer, so the click on B must still open B.
    await startEdit("second.ts");
    await vi.waitFor(() =>
      expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith("editable.ts", "first edited\n", { baseSHA256: "sha-first", purpose: "inlineDiff" }),
    );

    await vi.waitFor(() => expect(hoisted.workspaceRevisionFileRead).toHaveBeenCalledWith(expect.objectContaining({ path: "second.ts" })));
    await vi.waitFor(() => expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      path: "second.ts",
      baseSHA256: "sha-second",
      dirty: false,
    }));
  });

  it("keeps dirty A open and never reads B when A's write fails", async () => {
    const first = editableFileForContent("first disk\n");
    const second: DiffFileEntry = { ...editableFileForContent("second disk\n"), path: "second.ts" };
    hoisted.workspaceFileRead.mockResolvedValueOnce({ content: "first disk\n", sha256: "sha-first", size: 11 });
    hoisted.workspaceFileWrite.mockRejectedValueOnce(new SpacesBridgeError("unavailable", "daemon unavailable"));
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [first, second], "handover-failure-sig");
    await mounted;

    await startEdit("editable.ts");
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));
    typeInEditor("first edited\n");

    useFakeTimersWithImmediatePaint();
    await startEdit("second.ts");
    await vi.advanceTimersByTimeAsync(0);

    expect(hoisted.workspaceFileWrite).toHaveBeenCalledTimes(1);
    expect(hoisted.workspaceFileRead).not.toHaveBeenCalledWith("second.ts", "inlineDiff");
    expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      path: "editable.ts",
      content: "first edited\n",
      dirty: true,
    });
    expect(editStatusChip()?.textContent).toBe("Save failed: daemon unavailable · retry in 1 s");
  });

  it("ends a clean A editor before opening B", async () => {
    const first = editableFileForContent("editable.ts disk\n");
    const second: DiffFileEntry = { ...editableFileForContent("second.ts disk\n"), path: "second.ts" };
    hoisted.workspaceFileRead.mockImplementation((path: string) =>
      Promise.resolve({ content: `${path} disk\n`, sha256: `sha-${path}`, size: path.length + 6 }),
    );
    const endEditSpy = vi.spyOn(DiffView.prototype, "endEdit");
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [first, second], "two-editable-sig");
    await mounted;
    await startEdit("editable.ts");
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));

    await startEdit("second.ts");

    expect(endEditSpy).toHaveBeenCalledWith("editable.ts");
    endEditSpy.mockRestore();
  });

  it("adopts an external change into a clean inline edit without making it dirty", async () => {
    hoisted.workspaceFileRead
      .mockResolvedValueOnce({ content: "disk before\n", sha256: "sha-before", size: 12 })
      .mockResolvedValueOnce({ content: "disk changed\n", sha256: "sha-changed", size: 13 });
    await mountEditableDiff();
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));
    const replaceSpy = vi.spyOn(DiffView.prototype, "replaceEditContent");

    hoisted.diffSignatureCallbacks.at(-1)!();
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [editableFile], "editable-changed-sig");

    await vi.waitFor(() => expect(replaceSpy).toHaveBeenCalledWith("editable.ts", "disk changed\n", false));
    // A clean external adoption has nothing to report: no write is owed, and this session has not
    // written anything yet.
    expect(editStatusChip()).toBeNull();
    replaceSpy.mockRestore();
  });

  it("restores the review comparison side rather than the CAS baseline and retains it through disk reconciliation", async () => {
    INIT_PAYLOAD = {
      ...INIT_PAYLOAD,
      workspaceState: {
        ...INIT_PAYLOAD.workspaceState,
        diffEditorState: {
          path: "editable.ts",
          baseSHA256: "sha-before",
          baseContent: "disk before\n",
          comparisonOldContent: "review baseline\n",
          content: "disk before\n",
          dirty: false,
          conflict: false,
          conflictBaseSHA256: null,
        } satisfies CodePaneDiffEditorState,
      },
    };
    hoisted.workspaceFileRead.mockResolvedValueOnce({ content: "disk reset\n", sha256: "sha-reset", size: 11 });
    const beginEditSpy = vi.spyOn(DiffView.prototype, "beginEdit");
    const replaceSpy = vi.spyOn(DiffView.prototype, "replaceEditContent");

    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [], "clean-restored-omitted-sig");
    await mounted;

    expect(beginEditSpy).toHaveBeenCalledWith("editable.ts", "disk before\n", false, "review baseline\n");
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));
    expect(replaceSpy).toHaveBeenCalledWith("editable.ts", "disk reset\n", false);
    const collected = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}");
    expect(collected.diffEditorState).toMatchObject({
      path: "editable.ts",
      content: "disk reset\n",
      baseSHA256: "sha-reset",
      dirty: false,
      conflict: false,
      comparisonOldContent: "review baseline\n",
    });
    beginEditSpy.mockRestore();
    replaceSpy.mockRestore();
  });

  it("keeps a dirty inline edit reachable when a live manifest omits that path", async () => {
    hoisted.workspaceFileRead.mockResolvedValue({ content: "disk before\n", sha256: "sha-before", size: 12 });
    await mountEditableDiff();
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));
    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "diff" }, { contents: "unsaved recovery\n" });

    hoisted.diffSignatureCallbacks.at(-1)!();
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [], "omitted-edit-sig");

    await vi.waitFor(() =>
      expect(editStatusChip()?.textContent).toBe("Unsaved"),
    );
    const header = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })!;
    expect(header.textContent).toContain("Editing");
  });

  it("surfaces a manifest transport failure above a dirty editor and retries without hiding the editor", async () => {
    hoisted.workspaceFileRead.mockResolvedValue({ content: "disk before\n", sha256: "sha-before", size: 12 });
    await mountEditableDiff();
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));
    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "diff" }, { contents: "unsaved recovery\n" });

    useFakeTimersWithImmediatePaint();
    fireDiffSignature();
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2);
    rejectDiff(1, new Error("manifest transport dropped"));
    await vi.advanceTimersByTimeAsync(0);

    expect(container.querySelector("#code-pane-diff-edit-error")?.textContent).toBe("Couldn't load diff. Try again.");
    const header = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })!;
    expect(header.textContent).toContain("Editing");

    await vi.advanceTimersByTimeAsync(999);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(1);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(3);
    resolveDiff(2, [editableFile], "manifest-retry-sig");
    await vi.advanceTimersByTimeAsync(0);
  });

  it("surfaces a patch-stream failure above a dirty editor and retries without hiding the editor", async () => {
    hoisted.workspaceFileRead.mockResolvedValue({ content: "disk before\n", sha256: "sha-before", size: 12 });
    await mountEditableDiff();
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));
    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "diff" }, { contents: "unsaved recovery\n" });

    useFakeTimersWithImmediatePaint();
    hoisted.workspaceDiffFileChunk.mockRejectedValueOnce(new Error("patch transport dropped"));
    fireDiffSignature();
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2);
    resolveDiff(1, [editableFile], "patch-retry-sig");
    await vi.advanceTimersByTimeAsync(0);
    expect(hoisted.workspaceDiffFileChunk).toHaveBeenCalledTimes(2);

    expect(container.querySelector("#code-pane-diff-edit-error")?.textContent).toBe("Couldn't load diff. Try again.");
    const header = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })!;
    expect(header.textContent).toContain("Editing");

    await vi.advanceTimersByTimeAsync(999);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(1);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(3);
    resolveDiff(2, [editableFile], "patch-retry-success-sig");
    await vi.advanceTimersByTimeAsync(0);
  });

  it("freezes an overlapping external write as a disk-versus-buffer comparison and keeps mine CAS-bound to that disk snapshot", async () => {
    const testFile = editableFileForContent("before\n");
    hoisted.workspaceFileRead
      .mockResolvedValueOnce({ content: "before\n", sha256: "sha-before", size: 7 })
      .mockResolvedValueOnce({ content: "disk version\n", sha256: "sha-disk", size: 13 });
    // Keep the explicit conflict decision in flight. This test verifies the requested CAS baseline
    // rather than a later refresh triggered by a successful write.
    hoisted.workspaceFileWrite.mockImplementationOnce(() => new Promise(() => {}));
    const setConflictSpy = vi.spyOn(DiffView.prototype, "setEditConflict");
    await mountEditableDiff(testFile);
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));
    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "diff" }, { contents: "my version\n" });

    hoisted.diffSignatureCallbacks.at(-1)!();
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [testFile], "conflict-sig");

    await vi.waitFor(() =>
      expect(setConflictSpy).toHaveBeenCalledWith("editable.ts", { kind: "changed", diskContent: "disk version\n" }),
    );
    await vi.waitFor(() =>
      expect(
        hoisted.notifyWorkspaceStateChanged.mock.calls
          .map(([snapshot]) => snapshot as { diffEditorState: CodePaneDiffEditorState | null })
          .some(
            (snapshot) =>
              snapshot.diffEditorState?.conflict === true &&
              snapshot.diffEditorState.baseSHA256 === "sha-disk" &&
              snapshot.diffEditorState.baseContent === "disk version\n" &&
              snapshot.diffEditorState.content === "my version\n" &&
              snapshot.diffEditorState.comparisonOldContent === "before\n" &&
              snapshot.diffEditorState.conflictBaseSHA256 === "sha-disk",
          ),
      ).toBe(true),
    );

    const header = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })!;
    const keepMine = [...header.querySelectorAll<HTMLButtonElement>("button")].find((button) => button.textContent === "Keep mine")!;
    keepMine.click();
    await vi.waitFor(() =>
      expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith("editable.ts", "my version\n", { baseSHA256: "sha-disk", purpose: "inlineDiff" }),
    );
    setConflictSpy.mockRestore();
  });

  it("uses create-if-missing CAS when Keep mine resolves a deleted-file conflict", async () => {
    const testFile = editableFileForContent("before\n");
    hoisted.workspaceFileRead
      .mockResolvedValueOnce({ content: "before\n", sha256: "sha-before", size: 7 })
      .mockRejectedValueOnce(new SpacesBridgeError("notFound", "editable.ts was deleted"));
    hoisted.workspaceFileWrite.mockImplementationOnce(() => new Promise(() => {}));
    await mountEditableDiff(testFile);
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));
    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "diff" }, { contents: "restore mine\n" });

    hoisted.diffSignatureCallbacks.at(-1)!();
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [testFile], "deleted-edit-sig");
    const header = await vi.waitFor(() => {
      const rendered = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })!;
      expect(rendered.textContent).toContain("Keep mine");
      return rendered;
    });

    const persistedConflict = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}") as {
      diffEditorState?: CodePaneDiffEditorState;
    };
    expect(persistedConflict.diffEditorState?.conflictBaseSHA256).toBeNull();

    [...header.querySelectorAll<HTMLButtonElement>("button")].find((button) => button.textContent === "Keep mine")!.click();
    await vi.waitFor(() =>
      expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith("editable.ts", "restore mine\n", { baseSHA256: undefined, purpose: "inlineDiff" }),
    );
  });

  it("restores a changed-file conflict with its persisted disk CAS target", async () => {
    INIT_PAYLOAD = {
      ...INIT_PAYLOAD,
      workspaceState: {
        ...INIT_PAYLOAD.workspaceState,
        diffEditorState: {
          path: "editable.ts",
          baseSHA256: "sha-disk",
          baseContent: "disk version\n",
          comparisonOldContent: "before\n",
          content: "my recovered version\n",
          dirty: true,
          conflict: true,
          conflictBaseSHA256: "sha-disk",
        } satisfies CodePaneDiffEditorState,
      },
    };
    hoisted.workspaceFileWrite.mockImplementationOnce(() => new Promise(() => {}));
    await mountEditableDiff();

    const header = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })!;
    expect(header.textContent).toContain("Workspace changed");
    [...header.querySelectorAll<HTMLButtonElement>("button")].find((button) => button.textContent === "Keep mine")!.click();

    await vi.waitFor(() =>
      expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith("editable.ts", "my recovered version\n", { baseSHA256: "sha-disk", purpose: "inlineDiff" }),
    );
  });

  it("keeps a changed conflict's disk CAS target after Keep mine fails so a retry cannot overwrite a newer file", async () => {
    INIT_PAYLOAD = {
      ...INIT_PAYLOAD,
      workspaceState: {
        ...INIT_PAYLOAD.workspaceState,
        diffEditorState: {
          path: "editable.ts",
          // The conflict's displayed disk snapshot is the only CAS target that makes this Keep
          // mine confirmation safe. The ordinary edit baseline may still describe the pre-conflict
          // file after state restoration.
          baseSHA256: "sha-before-conflict",
          baseContent: "before conflict\n",
          comparisonOldContent: "before\n",
          content: "my recovered version\n",
          dirty: true,
          conflict: true,
          conflictBaseSHA256: "sha-disk",
        } satisfies CodePaneDiffEditorState,
      },
    };
    hoisted.workspaceFileWrite
      .mockRejectedValueOnce(new SpacesBridgeError("unavailable", "device reconnecting"))
      .mockResolvedValueOnce({ ok: true, sha256: "sha-after-retry" });
    await mountEditableDiff();

    useFakeTimersWithImmediatePaint();
    [...editHeader().querySelectorAll<HTMLButtonElement>("button")].find((button) => button.textContent === "Keep mine")!.click();
    await vi.advanceTimersByTimeAsync(0);
    expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith(
      "editable.ts",
      "my recovered version\n",
      { baseSHA256: "sha-disk", purpose: "inlineDiff" },
    );

    // The confirmed overwrite outlives its failure: every later attempt still targets exactly the
    // disk snapshot the user compared, never the older edit baseline the restored state carries.
    expect(editStatusChip()?.textContent).toBe("Save failed: device reconnecting · retry in 1 s");
    expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      content: "my recovered version\n",
      dirty: true,
    });

    await vi.advanceTimersByTimeAsync(1000);
    expect(hoisted.workspaceFileWrite).toHaveBeenLastCalledWith(
      "editable.ts",
      "my recovered version\n",
      { baseSHA256: "sha-disk", purpose: "inlineDiff" },
    );
    await vi.waitFor(() => expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      baseSHA256: "sha-after-retry",
      dirty: false,
    }));
  });

  it("carries a Keep mine create-if-missing target through a hibernation that interrupts its failed write", async () => {
    INIT_PAYLOAD = {
      ...INIT_PAYLOAD,
      workspaceState: {
        ...INIT_PAYLOAD.workspaceState,
        diffEditorState: {
          path: "editable.ts",
          baseSHA256: "sha-before-delete",
          baseContent: "before delete\n",
          comparisonOldContent: "before\n",
          content: "my recovered version\n",
          dirty: true,
          conflict: true,
          conflictBaseSHA256: null,
        } satisfies CodePaneDiffEditorState,
      },
    };
    // The file really is gone for the whole of this test, so every reconcile the refreshes run
    // reports it missing rather than returning a disk snapshot.
    hoisted.workspaceFileRead.mockRejectedValue(new SpacesBridgeError("notFound", "editable.ts is gone"));
    hoisted.workspaceFileWrite.mockRejectedValueOnce(new SpacesBridgeError("unavailable", "device reconnecting"));
    const firstMount = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [editableFile], "editable-sig");
    const firstRoot = await firstMount;

    [...editHeader().querySelectorAll<HTMLButtonElement>("button")].find((button) => button.textContent === "Keep mine")!.click();
    await vi.waitFor(() =>
      expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith("editable.ts", "my recovered version\n", { baseSHA256: undefined, purpose: "inlineDiff" }),
    );

    // The pane is retargeted (or the app restarted) while that create write is still failing. Only
    // what the host is holding survives, so the create-if-missing decision has to be in it.
    const hibernated = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}") as { diffEditorState: CodePaneDiffEditorState };
    firstRoot.dispose();
    hoisted.workspaceFileWrite.mockClear();
    hoisted.workspaceFileWrite.mockResolvedValueOnce({ ok: true, sha256: "sha-recreated" });
    INIT_PAYLOAD = {
      ...INIT_PAYLOAD,
      workspaceState: { ...INIT_PAYLOAD.workspaceState, diffEditorState: hibernated.diffEditorState },
    };
    container = document.createElement("div");
    const secondMount = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [editableFile], "editable-sig-restored");
    await secondMount;

    pressSaveShortcut();
    await vi.waitFor(() =>
      expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith("editable.ts", "my recovered version\n", { baseSHA256: undefined, purpose: "inlineDiff" }),
    );
  });

  it("keeps a confirmed create-if-missing decision when the file is still gone at the next reconcile", async () => {
    INIT_PAYLOAD = {
      ...INIT_PAYLOAD,
      workspaceState: {
        ...INIT_PAYLOAD.workspaceState,
        diffEditorState: {
          path: "editable.ts",
          baseSHA256: "sha-before-delete",
          baseContent: "before delete\n",
          comparisonOldContent: "before\n",
          content: "my recovered version\n",
          dirty: true,
          conflict: false,
          conflictBaseSHA256: null,
          confirmedBaseSHA256: null,
        } satisfies CodePaneDiffEditorState,
      },
    };
    // The file is still missing, which is exactly the state the user already decided about: the
    // routine reconcile a refresh runs must not demand that decision again.
    hoisted.workspaceFileRead.mockRejectedValue(new SpacesBridgeError("notFound", "editable.ts is gone"));
    hoisted.workspaceFileWrite.mockResolvedValueOnce({ ok: true, sha256: "sha-recreated" });
    await mountEditableDiff();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));

    expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      content: "my recovered version\n",
      dirty: true,
      conflict: false,
      confirmedBaseSHA256: null,
    });
    expect(editStatusChip()?.textContent).not.toContain("Save blocked");

    pressSaveShortcut();
    await vi.waitFor(() =>
      expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith("editable.ts", "my recovered version\n", { baseSHA256: undefined, purpose: "inlineDiff" }),
    );
  });

  it("retires a create-if-missing target once the file is back on disk with the pre-deletion bytes", async () => {
    INIT_PAYLOAD = {
      ...INIT_PAYLOAD,
      workspaceState: {
        ...INIT_PAYLOAD.workspaceState,
        diffEditorState: {
          path: "editable.ts",
          baseSHA256: "sha-before-delete",
          baseContent: "before delete\n",
          comparisonOldContent: "before\n",
          content: "my recovered version\n",
          dirty: true,
          conflict: false,
          conflictBaseSHA256: null,
          confirmedBaseSHA256: null,
        } satisfies CodePaneDiffEditorState,
      },
    };
    // Something else recreated the file with exactly the bytes it held before it was deleted, so
    // the reconcile's hash comparison finds nothing to do. The recreate decision still has to be
    // retired here: a create-only write would be refused because the path now exists, reconcile
    // back to this same no-op, and retry forever.
    hoisted.workspaceFileRead.mockResolvedValue({ content: "before delete\n", sha256: "sha-before-delete", size: 14 });
    hoisted.workspaceFileWrite.mockResolvedValue({ ok: true, sha256: "sha-rewritten" });
    await mountEditableDiff();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));

    pressSaveShortcut();
    await vi.waitFor(() =>
      expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith(
        "editable.ts",
        "my recovered version\n",
        { baseSHA256: "sha-before-delete", purpose: "inlineDiff" },
      ),
    );
    await vi.waitFor(() => expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      baseSHA256: "sha-rewritten",
      dirty: false,
    }));
    // One write settles it: the buffer is clean against the file that exists, with no create/refuse
    // cycle behind it.
    expect(hoisted.workspaceFileWrite).toHaveBeenCalledTimes(1);
  });

  it("restores a deleted-file conflict as create-if-missing rather than an existing-file overwrite", async () => {
    INIT_PAYLOAD = {
      ...INIT_PAYLOAD,
      workspaceState: {
        ...INIT_PAYLOAD.workspaceState,
        diffEditorState: {
          path: "editable.ts",
          baseSHA256: "sha-before-delete",
          baseContent: "before delete\n",
          comparisonOldContent: "before\n",
          content: "restore my recovered version\n",
          dirty: true,
          conflict: true,
          conflictBaseSHA256: null,
        } satisfies CodePaneDiffEditorState,
      },
    };
    hoisted.workspaceFileWrite.mockImplementationOnce(() => new Promise(() => {}));
    await mountEditableDiff();

    const header = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })!;
    expect(header.textContent).toContain("deleted on disk");
    expect([...header.querySelectorAll<HTMLButtonElement>("button")].some((button) => button.textContent === "Close without saving")).toBe(true);
    [...header.querySelectorAll<HTMLButtonElement>("button")].find((button) => button.textContent === "Keep mine")!.click();

    await vi.waitFor(() =>
      expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith("editable.ts", "restore my recovered version\n", { baseSHA256: undefined, purpose: "inlineDiff" }),
    );
  });

  it("reports a retryable save failure in the header and writes again on Retry now", async () => {
    hoisted.workspaceFileRead.mockResolvedValue({ content: "disk before\n", sha256: "sha-before", size: 12 });
    hoisted.workspaceFileWrite.mockRejectedValueOnce(new SpacesBridgeError("unavailable", "daemon unavailable"));
    await mountEditableDiff();
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));
    typeInEditor("edited\n");

    useFakeTimersWithImmediatePaint();
    pressSaveShortcut();
    await vi.advanceTimersByTimeAsync(0);
    expect(hoisted.workspaceFileWrite).toHaveBeenCalledTimes(1);

    // An automatic write that failed reports itself in the file's header, with the wait until the
    // next attempt, rather than taking over the review surface with an error banner.
    expect(container.querySelector<HTMLElement>("#code-pane-diff-edit-error")?.style.display).toBe("none");
    expect(editStatusChip()?.textContent).toBe("Save failed: daemon unavailable · retry in 1 s");
    expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      content: "edited\n",
      dirty: true,
    });

    hoisted.workspaceFileWrite.mockResolvedValueOnce({ ok: true, sha256: "sha-after-retry" });
    editHeader().querySelector<HTMLButtonElement>("#code-pane-diff-edit-retry")!.click();
    await vi.advanceTimersByTimeAsync(0);
    expect(hoisted.workspaceFileWrite).toHaveBeenCalledTimes(2);
    await vi.waitFor(() => expect(editStatusChip()?.textContent).toBe("Saved"));
  });

  it("surfaces the daemon's non-deletion read failure before opening an inline diff edit", async () => {
    hoisted.workspaceFileRead.mockRejectedValueOnce(new SpacesBridgeError("unavailable", "daemon unavailable"));
    await mountEditableDiff();
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));

    expect(container.textContent).toContain("daemon unavailable");
  });

  it("keeps the generic retry message when opening an inline diff edit fails with an unknown error", async () => {
    hoisted.workspaceFileRead.mockRejectedValueOnce(new Error("transport failed"));
    await mountEditableDiff();
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));

    expect(container.textContent).toContain("Couldn't open editable.ts for editing. Try again.");
  });

  it("coalesces a burst of typing into one write 800ms later and keeps the session open", async () => {
    hoisted.workspaceFileRead.mockResolvedValue({ content: "disk before\n", sha256: "sha-before", size: 12 });
    hoisted.workspaceFileWrite.mockResolvedValue({ ok: true, sha256: "sha-saved" });
    await mountEditableDiff();
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));

    useFakeTimersWithImmediatePaint();
    typeInEditor("edited once\n");
    typeInEditor("edited twice\n");
    await vi.advanceTimersByTimeAsync(799);
    expect(hoisted.workspaceFileWrite).not.toHaveBeenCalled();
    expect(editStatusChip()?.textContent).toBe("Unsaved");

    await vi.advanceTimersByTimeAsync(1);
    expect(hoisted.workspaceFileWrite).toHaveBeenCalledTimes(1);
    expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith("editable.ts", "edited twice\n", { baseSHA256: "sha-before", purpose: "inlineDiff" });

    // Saving is not leaving: the editor keeps the surface, now clean against the written baseline.
    await vi.waitFor(() => expect(editStatusChip()?.textContent).toBe("Saved"));
    expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      path: "editable.ts",
      content: "edited twice\n",
      baseSHA256: "sha-saved",
      dirty: false,
    });
  });

  it("writes immediately on ⌘S instead of waiting out the debounce", async () => {
    hoisted.workspaceFileRead.mockResolvedValue({ content: "disk before\n", sha256: "sha-before", size: 12 });
    hoisted.workspaceFileWrite.mockResolvedValue({ ok: true, sha256: "sha-saved" });
    await mountEditableDiff();
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));

    useFakeTimersWithImmediatePaint();
    typeInEditor("edited\n");
    pressSaveShortcut();
    await vi.advanceTimersByTimeAsync(0);

    expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith("editable.ts", "edited\n", { baseSHA256: "sha-before", purpose: "inlineDiff" });
    // The shortcut replaces the pending debounce rather than adding a second write behind it.
    await vi.advanceTimersByTimeAsync(1000);
    expect(hoisted.workspaceFileWrite).toHaveBeenCalledTimes(1);
  });

  it("ends a clean edit session on Escape and reports the diffEditEnd milestone", async () => {
    hoisted.workspaceFileRead.mockResolvedValue({ content: "disk before\n", sha256: "sha-before", size: 12 });
    await mountEditableDiff();
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));
    const endEditSpy = vi.spyOn(DiffView.prototype, "endEdit");

    pressEscape();

    expect(endEditSpy).toHaveBeenCalledWith("editable.ts");
    expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toBeNull();
    expect(hoisted.workspaceFileWrite).not.toHaveBeenCalled();
    await vi.waitFor(() =>
      expect(hoisted.notifyRenderMetric.mock.calls.some(([metric]) => (metric as { trigger: string }).trigger === "diffEditEnd")).toBe(true),
    );
    endEditSpy.mockRestore();
  });

  it("leaves the session alone when Escape closes the compare menu instead", async () => {
    hoisted.workspaceFileRead.mockResolvedValue({ content: "disk before\n", sha256: "sha-before", size: 12 });
    await mountEditableDiff();
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));
    typeInEditor("still editing\n");
    container.querySelector<HTMLButtonElement>(".compare-btn")!.click();
    expect(container.querySelector(".compare-menu")).not.toBeNull();

    // That Escape belongs to the menu the user just opened, not to the editor they left running
    // behind it.
    pressEscapeOutsideTheEditor();
    await Promise.resolve();

    expect(container.querySelector(".compare-menu")).toBeNull();
    expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      path: "editable.ts",
      content: "still editing\n",
      dirty: true,
    });
    expect(hoisted.workspaceFileWrite).not.toHaveBeenCalled();
  });

  it("writes a dirty buffer before Escape ends the session", async () => {
    hoisted.workspaceFileRead.mockResolvedValue({ content: "disk before\n", sha256: "sha-before", size: 12 });
    hoisted.workspaceFileWrite.mockResolvedValue({ ok: true, sha256: "sha-saved" });
    await mountEditableDiff();
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));
    typeInEditor("escaped edit\n");

    pressEscape();

    await vi.waitFor(() =>
      expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith("editable.ts", "escaped edit\n", { baseSHA256: "sha-before", purpose: "inlineDiff" }),
    );
    await vi.waitFor(() => expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toBeNull());
  });

  it("keeps the session open on Escape when the write fails", async () => {
    hoisted.workspaceFileRead.mockResolvedValue({ content: "disk before\n", sha256: "sha-before", size: 12 });
    hoisted.workspaceFileWrite.mockRejectedValue(new SpacesBridgeError("unavailable", "daemon unavailable"));
    await mountEditableDiff();
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));
    typeInEditor("escaped edit\n");

    useFakeTimersWithImmediatePaint();
    pressEscape();
    await vi.advanceTimersByTimeAsync(0);

    // Escape leaves an editor, it never discards one: an edit that could not be written stays on
    // screen with the reason, rather than disappearing with the user's text.
    expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      path: "editable.ts",
      content: "escaped edit\n",
      dirty: true,
    });
    expect(editStatusChip()?.textContent).toBe("Save failed: daemon unavailable · retry in 1 s");
  });

  it("writes a dirty inline edit when the comparison scope changes", async () => {
    hoisted.workspaceFileRead.mockResolvedValue({ content: "disk before\n", sha256: "sha-before", size: 12 });
    hoisted.workspaceFileWrite.mockResolvedValue({ ok: true, sha256: "sha-saved" });
    await mountEditableDiff();
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));
    typeInEditor("edited before the scope switch\n");

    switchToLastCommit(container);

    await vi.waitFor(() =>
      expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith(
        "editable.ts",
        "edited before the scope switch\n",
        { baseSHA256: "sha-before", purpose: "inlineDiff" },
      ),
    );
  });

  it("writes the confirmed buffer and keeps the session when Keep mine resolves a conflict", async () => {
    INIT_PAYLOAD = {
      ...INIT_PAYLOAD,
      workspaceState: {
        ...INIT_PAYLOAD.workspaceState,
        diffEditorState: {
          path: "editable.ts",
          baseSHA256: "sha-disk",
          baseContent: "disk version\n",
          comparisonOldContent: "before\n",
          content: "my recovered version\n",
          dirty: true,
          conflict: true,
          conflictBaseSHA256: "sha-disk",
        } satisfies CodePaneDiffEditorState,
      },
    };
    hoisted.workspaceFileWrite.mockResolvedValue({ ok: true, sha256: "sha-kept" });
    await mountEditableDiff();

    // A conflict blocks autosave until the user decides; Keep mine is that decision, and the write
    // it authorizes is the scheduler's, against the disk snapshot the comparison showed.
    expect(editStatusChip()?.textContent).toBe("Save blocked: File changed on disk");
    [...editHeader().querySelectorAll<HTMLButtonElement>("button")].find((button) => button.textContent === "Keep mine")!.click();

    await vi.waitFor(() =>
      expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith("editable.ts", "my recovered version\n", { baseSHA256: "sha-disk", purpose: "inlineDiff" }),
    );
    await vi.waitFor(() => expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      path: "editable.ts",
      content: "my recovered version\n",
      baseSHA256: "sha-kept",
      dirty: false,
      conflict: false,
    }));
    expect(editStatusChip()?.textContent).toBe("Saved");
  });

  it("answers the host's quit flush only once the pending write has settled", async () => {
    hoisted.workspaceFileRead.mockResolvedValue({ content: "disk before\n", sha256: "sha-before", size: 12 });
    let resolveWrite: ((result: { ok: true; sha256: string }) => void) | undefined;
    hoisted.workspaceFileWrite.mockImplementationOnce(
      () => new Promise((resolve) => {
        resolveWrite = resolve;
      }),
    );
    await mountEditableDiff();
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));
    typeInEditor("quit edit\n");

    window.dispatchEvent(new CustomEvent("spaces:flushEdits", { detail: { token: "quit-1" } }));

    await vi.waitFor(() =>
      expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith("editable.ts", "quit edit\n", { baseSHA256: "sha-before", purpose: "inlineDiff" }),
    );
    expect(hoisted.notifyEditsFlushed).not.toHaveBeenCalled();

    resolveWrite!({ ok: true, sha256: "sha-quit" });
    await vi.waitFor(() => expect(hoisted.notifyEditsFlushed).toHaveBeenCalledWith("quit-1"));
    expect(hoisted.notifyEditsFlushed).toHaveBeenCalledTimes(1);
  });

  it("keeps the text typed during an in-flight write when that write reports the file deleted", async () => {
    hoisted.workspaceFileRead.mockResolvedValue({ content: "disk before\n", sha256: "sha-before", size: 12 });
    let rejectWrite: ((error: unknown) => void) | undefined;
    hoisted.workspaceFileWrite.mockImplementationOnce(
      () => new Promise((_resolve, reject) => {
        rejectWrite = reject;
      }),
    );
    await mountEditableDiff();
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));
    typeInEditor("submitted\n");
    pressSaveShortcut();
    await vi.waitFor(() => expect(hoisted.workspaceFileWrite).toHaveBeenCalledTimes(1));

    // Typing continues while the write is in flight, so the buffer the deletion has to preserve is
    // this one, not the snapshot that was submitted.
    typeInEditor("typed during the write\n");
    rejectWrite!(new SpacesBridgeError("notFound", "editable.ts is gone"));

    await vi.waitFor(() => expect(editStatusChip()?.textContent).toBe("Save blocked: File deleted on disk"));
    expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      content: "typed during the write\n",
      dirty: true,
      conflict: true,
      conflictBaseSHA256: null,
    });

    hoisted.workspaceFileWrite.mockResolvedValueOnce({ ok: true, sha256: "sha-recreated" });
    [...editHeader().querySelectorAll<HTMLButtonElement>("button")].find((button) => button.textContent === "Keep mine")!.click();
    await vi.waitFor(() =>
      expect(hoisted.workspaceFileWrite).toHaveBeenLastCalledWith(
        "editable.ts",
        "typed during the write\n",
        { baseSHA256: undefined, purpose: "inlineDiff" },
      ),
    );
  });

  it("backs off instead of rewriting when a refused write's reconcile read cannot run", async () => {
    hoisted.workspaceFileRead.mockResolvedValueOnce({ content: "disk before\n", sha256: "sha-before", size: 12 });
    hoisted.workspaceFileWrite.mockResolvedValueOnce({ conflict: true, currentSHA256: "sha-other" });
    await mountEditableDiff();
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));
    typeInEditor("edited\n");
    // The reconcile the CAS rejection triggers cannot reach disk, so nothing about the refused
    // write's baseline changes and rewriting the same buffer against it could only be refused
    // again.
    hoisted.workspaceFileRead.mockRejectedValueOnce(new SpacesBridgeError("unavailable", "daemon unavailable"));

    useFakeTimersWithImmediatePaint();
    pressSaveShortcut();
    await vi.advanceTimersByTimeAsync(0);

    expect(hoisted.workspaceFileWrite).toHaveBeenCalledTimes(1);
    expect(editStatusChip()?.textContent).toBe("Save failed: The file changed on disk and could not be re-read. · retry in 1 s");

    hoisted.workspaceFileRead.mockResolvedValueOnce({ content: "disk before\n", sha256: "sha-before", size: 12 });
    hoisted.workspaceFileWrite.mockResolvedValueOnce({ ok: true, sha256: "sha-after-retry" });
    await vi.advanceTimersByTimeAsync(1000);
    expect(hoisted.workspaceFileWrite).toHaveBeenCalledTimes(2);
  });

  it("answers the host's quit flush only after writing an inline session left dirty behind a mode switch", async () => {
    hoisted.workspaceFileRead.mockResolvedValue({ content: "disk before\n", sha256: "sha-before", size: 12 });
    hoisted.workspaceFileWrite.mockResolvedValue({ ok: true, sha256: "sha-quit" });
    await mountEditableDiff();
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));
    typeInEditor("typed then switched away\n");

    // Switching modes before the debounce fires leaves the pane holding unsaved inline work while
    // Editor mode is the visible surface. Quit has to write both surfaces, not just the visible one.
    window.dispatchEvent(new CustomEvent("spaces:setMode", { detail: { mode: "editor" } }));
    window.dispatchEvent(new CustomEvent("spaces:flushEdits", { detail: { token: "quit-mixed" } }));

    await vi.waitFor(() => expect(hoisted.notifyEditsFlushed).toHaveBeenCalledWith("quit-mixed"));
    expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith(
      "editable.ts",
      "typed then switched away\n",
      { baseSHA256: "sha-before", purpose: "inlineDiff" },
    );
    expect(hoisted.workspaceFileWrite.mock.invocationCallOrder[0]!).toBeLessThan(
      hoisted.notifyEditsFlushed.mock.invocationCallOrder[0]!,
    );
    window.dispatchEvent(new CustomEvent("spaces:setMode", { detail: { mode: "diff" } }));
  });

  it("leaves a failed write's backoff running when a live refresh re-attaches the same session", async () => {
    hoisted.workspaceFileRead.mockResolvedValue({ content: "disk before\n", sha256: "sha-before", size: 12 });
    hoisted.workspaceFileWrite.mockRejectedValueOnce(new SpacesBridgeError("unavailable", "daemon unavailable"));
    await mountEditableDiff();
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));
    typeInEditor("edited\n");

    useFakeTimersWithImmediatePaint();
    pressSaveShortcut();
    await vi.advanceTimersByTimeAsync(0);
    expect(hoisted.workspaceFileWrite).toHaveBeenCalledTimes(1);
    expect(editStatusChip()?.textContent).toBe("Save failed: daemon unavailable · retry in 1 s");

    // Workspace churn re-renders the diff and re-attaches this very session. That is not a
    // keystroke, so it must not collapse the failure backoff into a fresh 800ms debounce: a daemon
    // that is refusing writes would otherwise be hammered once per refresh.
    fireDiffSignature();
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [editableFile], "editable-sig-2");
    await vi.advanceTimersByTimeAsync(800);
    expect(hoisted.workspaceFileWrite).toHaveBeenCalledTimes(1);
    expect(editStatusChip()?.textContent).toBe("Save failed: daemon unavailable · retry in 1 s");

    hoisted.workspaceFileWrite.mockResolvedValueOnce({ ok: true, sha256: "sha-after-retry" });
    await vi.advanceTimersByTimeAsync(200);
    expect(hoisted.workspaceFileWrite).toHaveBeenCalledTimes(2);
  });

  it("starts both surfaces' writes together when the host asks for a quit flush", async () => {
    // A mode switch before either debounce fired can leave the Editor buffer and the inline session
    // both dirty. The host holds its quit for a bounded window, so the two writes have to overlap:
    // running them one after the other spends that window on a single slow remote write.
    INIT_PAYLOAD = {
      ...INIT_PAYLOAD,
      workspaceState: {
        ...INIT_PAYLOAD.workspaceState,
        editorState: {
          path: "editor.ts",
          baseSHA256: "sha-editor",
          baseContent: "editor base\n",
          content: "editor edited\n",
          dirty: true,
          conflict: false,
        } satisfies CodePaneEditorState,
      },
    };
    hoisted.workspaceFileRead.mockImplementation(async (path: string) =>
      path === "editable.ts"
        ? { content: "disk before\n", sha256: "sha-before", size: 12 }
        : { content: "editor base\n", sha256: "sha-editor", size: 12 },
    );
    const writes: Array<{ path: string; resolve: (result: { ok: true; sha256: string }) => void }> = [];
    hoisted.workspaceFileWrite.mockImplementation(
      (path: string) => new Promise<{ ok: true; sha256: string }>((resolve) => {
        writes.push({ path, resolve });
      }),
    );
    await mountEditableDiff();
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));
    typeInEditor("inline edit\n");

    // Fake timers from here so neither surface's own debounce can fire: every write below is one
    // the quit flush itself issued.
    useFakeTimersWithImmediatePaint();
    expect(writes).toHaveLength(0);
    window.dispatchEvent(new CustomEvent("spaces:flushEdits", { detail: { token: "quit-both" } }));
    await vi.advanceTimersByTimeAsync(0);

    expect(writes.map((write) => write.path).sort()).toEqual(["editable.ts", "editor.ts"]);
    expect(hoisted.notifyEditsFlushed).not.toHaveBeenCalled();

    writes.find((write) => write.path === "editor.ts")!.resolve({ ok: true, sha256: "sha-editor-saved" });
    await vi.advanceTimersByTimeAsync(0);
    expect(hoisted.notifyEditsFlushed).not.toHaveBeenCalled();

    writes.find((write) => write.path === "editable.ts")!.resolve({ ok: true, sha256: "sha-inline-saved" });
    await vi.advanceTimersByTimeAsync(0);
    expect(hoisted.notifyEditsFlushed).toHaveBeenCalledWith("quit-both");
  });

  it("keeps trying past a failed write before answering the host's quit flush", async () => {
    hoisted.workspaceFileRead.mockResolvedValue({ content: "disk before\n", sha256: "sha-before", size: 12 });
    hoisted.workspaceFileWrite
      .mockRejectedValueOnce(new SpacesBridgeError("unavailable", "daemon unavailable"))
      .mockResolvedValueOnce({ ok: true, sha256: "sha-quit" });
    await mountEditableDiff();
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));
    typeInEditor("quit edit\n");

    useFakeTimersWithImmediatePaint();
    window.dispatchEvent(new CustomEvent("spaces:flushEdits", { detail: { token: "quit-retry" } }));
    await vi.advanceTimersByTimeAsync(0);

    // Acknowledging here would let the host tear the page down with the buffer unwritten and the
    // scheduled retry cancelled, inside a window that is still open.
    expect(hoisted.workspaceFileWrite).toHaveBeenCalledTimes(1);
    expect(hoisted.notifyEditsFlushed).not.toHaveBeenCalled();

    // The scheduler's own retry lands at its 1s floor; the reply follows as soon as the quit flush
    // sees that surface report itself written.
    await vi.advanceTimersByTimeAsync(1000);
    expect(hoisted.workspaceFileWrite).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(100);
    expect(hoisted.notifyEditsFlushed).toHaveBeenCalledWith("quit-retry");
    expect(hoisted.notifyEditsFlushed).toHaveBeenCalledTimes(1);
  });

  it("never answers the host's quit flush while writes keep failing, one attempt per backoff", async () => {
    hoisted.workspaceFileRead.mockResolvedValue({ content: "disk before\n", sha256: "sha-before", size: 12 });
    hoisted.workspaceFileWrite.mockRejectedValue(new SpacesBridgeError("unavailable", "daemon unavailable"));
    await mountEditableDiff();
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));
    typeInEditor("quit edit\n");

    useFakeTimersWithImmediatePaint();
    window.dispatchEvent(new CustomEvent("spaces:flushEdits", { detail: { token: "quit-doomed" } }));
    await vi.advanceTimersByTimeAsync(0);
    expect(hoisted.workspaceFileWrite).toHaveBeenCalledTimes(1);

    // 1s, then 2s, then 4s: the retries ride the scheduler's own backoff rather than spinning.
    await vi.advanceTimersByTimeAsync(1000);
    expect(hoisted.workspaceFileWrite).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(2000);
    expect(hoisted.workspaceFileWrite).toHaveBeenCalledTimes(3);
    await vi.advanceTimersByTimeAsync(3999);
    expect(hoisted.workspaceFileWrite).toHaveBeenCalledTimes(3);
    await vi.advanceTimersByTimeAsync(1);
    expect(hoisted.workspaceFileWrite).toHaveBeenCalledTimes(4);

    // The host's own timeout is what ends a page that can never write; this side simply never
    // claims the work is done.
    expect(hoisted.notifyEditsFlushed).not.toHaveBeenCalled();
  });

  it("stops watching a failing quit flush once the pane is retired", async () => {
    hoisted.workspaceFileRead.mockResolvedValue({ content: "disk before\n", sha256: "sha-before", size: 12 });
    hoisted.workspaceFileWrite.mockRejectedValue(new SpacesBridgeError("unavailable", "daemon unavailable"));
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [editableFile], "editable-sig");
    const root = await mounted;
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));
    typeInEditor("quit edit\n");

    useFakeTimersWithImmediatePaint();
    window.dispatchEvent(new CustomEvent("spaces:flushEdits", { detail: { token: "quit-retired" } }));
    await vi.advanceTimersByTimeAsync(0);
    expect(hoisted.workspaceFileWrite).toHaveBeenCalledTimes(1);

    // The pane is torn down while that write is still failing. The watcher has to go with it rather
    // than ticking forever against a retired root.
    root.dispose();
    await vi.advanceTimersByTimeAsync(60_000);

    expect(hoisted.workspaceFileWrite).toHaveBeenCalledTimes(1);
    expect(hoisted.notifyEditsFlushed).not.toHaveBeenCalled();
    expect(vi.getTimerCount()).toBe(0);
  });

  it("answers the host's quit flush right away when the buffer is blocked by a conflict", async () => {
    INIT_PAYLOAD = {
      ...INIT_PAYLOAD,
      workspaceState: {
        ...INIT_PAYLOAD.workspaceState,
        diffEditorState: {
          path: "editable.ts",
          baseSHA256: "sha-disk",
          baseContent: "disk version\n",
          comparisonOldContent: "before\n",
          content: "my version\n",
          dirty: true,
          conflict: true,
          conflictBaseSHA256: "sha-disk",
        } satisfies CodePaneDiffEditorState,
      },
    };
    hoisted.workspaceFileRead.mockResolvedValue({ content: "disk version\n", sha256: "sha-disk", size: 13 });
    await mountEditableDiff();
    expect(editStatusChip()?.textContent).toBe("Save blocked: File changed on disk");

    window.dispatchEvent(new CustomEvent("spaces:flushEdits", { detail: { token: "quit-blocked" } }));

    // A conflict is the user's to resolve, so quitting waits for nothing: nothing is written.
    await vi.waitFor(() => expect(hoisted.notifyEditsFlushed).toHaveBeenCalledWith("quit-blocked"));
    expect(hoisted.workspaceFileWrite).not.toHaveBeenCalled();
  });

  it("answers the host's quit flush immediately when nothing is unsaved", async () => {
    hoisted.workspaceFileRead.mockResolvedValue({ content: "disk before\n", sha256: "sha-before", size: 12 });
    await mountEditableDiff();
    await startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts", "inlineDiff"));

    window.dispatchEvent(new CustomEvent("spaces:flushEdits", { detail: { token: "quit-2" } }));

    await vi.waitFor(() => expect(hoisted.notifyEditsFlushed).toHaveBeenCalledWith("quit-2"));
    expect(hoisted.workspaceFileWrite).not.toHaveBeenCalled();
  });
});

describe("mountRoot's refreshDiff: coalesced diff-signature storm (round-16 Fix 1)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.diffSignatureCallbacks.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.notifyModeChanged.mockClear();
    container = document.createElement("div");
  });

  it("a storm of diff-signature events while a pull is in flight coalesces into exactly one trailing pull, not one per event", async () => {
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [makeFile("initial.ts")], "sig-0");
    await mounted;
    await vi.waitFor(() => expect(container.textContent).toContain("initial.ts"));

    // Event #1 issues pull #2 (call index 1), held open.
    fireDiffSignature();
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));

    // 3 more events while pull #2 is still held: without the gate, each would issue its own
    // `workspaceDiff` call (5 held/pending calls total, not 2): that's the bug this fix closes.
    fireDiffSignature();
    fireDiffSignature();
    fireDiffSignature();
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2); // still 2, not 5

    // Resolving pull #2 discards its own result (superseded by the 3 coalesced events' token
    // bumps) and issues exactly ONE trailing pull in its place.
    resolveDiff(1, [makeFile("superseded.ts")], "sig-1");
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(3)); // one trailing pull, not 6
    expect(container.textContent).not.toContain("superseded.ts");

    resolveDiff(2, [makeFile("trailing.ts")], "sig-2");
    await vi.waitFor(() => expect(container.textContent).toContain("trailing.ts"));
    expect(container.textContent).not.toContain("superseded.ts");
  });
});

describe("mountRoot's refreshDiff: scope switch mid-pull keeps the supersede + latest-scope guarantees (round-16 Fix 1)", () => {
  let container: HTMLElement;
  let setFilesSpy: ReturnType<typeof vi.spyOn>;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.diffSignatureCallbacks.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.notifyModeChanged.mockClear();
    container = document.createElement("div");
    // Not mocked at the module level (only @pierre/diffs's CodeView is faked): spying on the real
    // DiffView's prototype lets these tests observe the exact (files, preserveScroll) pair the
    // coalesced trailing pull renders with, without altering DiffView's own behavior.
    setFilesSpy = vi.spyOn(DiffView.prototype, "setFiles");
  });

  afterEach(() => {
    setFilesSpy.mockRestore();
  });

  it("a scope switch coalesced with signature events supersedes the in-flight pull, targets the new scope, and keeps the switch's non-preserving intent", async () => {
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [makeFile("initial.ts")], "sig-0");
    await mounted;
    await vi.waitFor(() => expect(container.textContent).toContain("initial.ts"));

    // A signature event for scope A ("uncommitted") issues a held pull.
    fireDiffSignature();
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));

    // A scope switch mid-pull must not issue a second concurrent request: its own `refreshDiff(false)`
    // call coalesces into the trailing slot exactly like a direct queue-path call would.
    switchToLastCommit(container);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2);

    // One more signature event lands (now on the newly-subscribed scope B) while still held — this
    // proves the `&&` in `trailingPreserveScroll`: a non-preserving scope switch's `false` wins over
    // any number of `true` signature events coalesced alongside it.
    fireDiffSignature();
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2);

    // Resolve scope A's original held pull with distinguishable files: it was superseded by the two
    // coalesced token bumps above, so these files must never render.
    resolveDiff(1, [makeFile("scope-a-only.ts")], "sig-a");
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(3)); // the trailing pull fires
    expect(container.textContent).not.toContain("scope-a-only.ts");

    // The trailing pull re-reads `state.scope` at run time, so it targets scope B (the current
    // scope), not scope A (whatever was selected when it was queued).
    resolveDiff(2, [makeFile("scope-b-only.ts")], "sig-b");
    await vi.waitFor(() => expect(container.textContent).toContain("scope-b-only.ts"));
    expect(container.textContent).not.toContain("scope-a-only.ts");

    // And the render that actually applied scope B's files used preserveScroll === false: the scope
    // switch's non-preserving intent survived being coalesced with the preserving signature events.
    const finalCall = setFilesSpy.mock.calls[setFilesSpy.mock.calls.length - 1]!;
    expect(finalCall[0]).toEqual([expect.objectContaining({ ...makeFile("scope-b-only.ts"), patchState: "ready" })]);
    expect(finalCall[1]).toBe(false);
  });
});

describe("mountRoot's refreshDiff — permanent vs. transient failure classification (round-7 Fix 2)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.notifyModeChanged.mockClear();
    container = document.createElement("div");
    useFakeTimersWithImmediatePaint();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("a SpacesBridgeError clears the file list and diff area and renders its message, with no retry scheduled", async () => {
    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0);
    resolveDiff(0, [makeFile("a.ts")], "sig-a");
    await mounted;
    expect(container.textContent).toContain("a.ts");

    // A scope switch's own fresh refreshDiff call is the one that fails permanently.
    switchToLastCommit(container);
    await vi.advanceTimersByTimeAsync(0);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2);

    rejectDiff(1, new SpacesBridgeError("notFound", "ref totally-bogus not found"));
    await vi.advanceTimersByTimeAsync(0);

    expect(container.textContent).toContain("ref totally-bogus not found");
    expect(container.textContent).not.toContain("a.ts"); // the prior scope's stale file list is gone, not left on screen

    // Advance well past every backoff step in the transient loop: a permanent error must never
    // schedule a retry, so no further workspaceDiff call ever fires on its own.
    await vi.advanceTimersByTimeAsync(60000);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2);
  });

  it("a plain rejection keeps retrying exactly as an untyped transport failure always has", async () => {
    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0);
    rejectDiff(0, new Error("socket hung up"));
    await mounted;

    // Not classified as permanent: nothing is rendered from it, and the bounded-backoff retry
    // (covered in full by the describe block above) still fires at the floor.
    await vi.advanceTimersByTimeAsync(1000);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2);
  });

  it("a scope switch out of a rendered permanent error fetches the new scope normally", async () => {
    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0);
    rejectDiff(0, new SpacesBridgeError("notFound", "ref totally-bogus not found"));
    await mounted;
    expect(container.textContent).toContain("ref totally-bogus not found");

    switchToLastCommit(container); // no new recovery plumbing needed: setScope's own refreshDiff call recovers it
    await vi.advanceTimersByTimeAsync(0);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2);

    resolveDiff(1, [makeFile("b.ts")], "sig-b");
    await vi.advanceTimersByTimeAsync(0);
    expect(container.textContent).toContain("b.ts");
    expect(container.textContent).not.toContain("ref totally-bogus not found");
  });

  it("resets the backoff floor on a permanent error, so a later transient failure starts at 1s again", async () => {
    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0);
    rejectDiff(0, new Error("boom 1")); // transient: bumps diffRetryFailures to 1, first retry due at 1s
    await mounted;

    await vi.advanceTimersByTimeAsync(1000);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2);
    rejectDiff(1, new SpacesBridgeError("notFound", "ref totally-bogus not found")); // permanent: resets the counter
    await vi.advanceTimersByTimeAsync(0);
    expect(container.textContent).toContain("ref totally-bogus not found");

    switchToLastCommit(container); // fresh scope; this refresh fails transiently again
    await vi.advanceTimersByTimeAsync(0);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(3);
    rejectDiff(2, new Error("boom 2"));
    await vi.advanceTimersByTimeAsync(0);

    // If the permanent error hadn't reset diffRetryFailures, this retry would be due at 2s, not 1s.
    await vi.advanceTimersByTimeAsync(999);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(3);
    await vi.advanceTimersByTimeAsync(1);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(4);
  });
});

describe("mountRoot's refreshDiff — `unavailable` is a retried exception within the typed set (round-8 Fix 1)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.notifyModeChanged.mockClear();
    container = document.createElement("div");
    useFakeTimersWithImmediatePaint();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("renders the unavailable message and still schedules a retry at the floor", async () => {
    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0);
    resolveDiff(0, [makeFile("a.ts")], "sig-a");
    await mounted;
    expect(container.textContent).toContain("a.ts");

    switchToLastCommit(container);
    await vi.advanceTimersByTimeAsync(0);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2);

    rejectDiff(1, new SpacesBridgeError("unavailable", "daemon not reachable"));
    await vi.advanceTimersByTimeAsync(0);

    expect(container.textContent).toContain("daemon not reachable");
    expect(container.textContent).not.toContain("a.ts"); // stale file list cleared, same as a permanent error

    // Unlike a permanent typed error, this must retry — at the same 1s floor as an untyped failure.
    await vi.advanceTimersByTimeAsync(999);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2); // not yet due
    await vi.advanceTimersByTimeAsync(1);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(3); // retried
  });

  it("recovers automatically once the retry succeeds", async () => {
    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0);
    rejectDiff(0, new SpacesBridgeError("unavailable", "daemon not reachable"));
    await mounted;
    expect(container.textContent).toContain("daemon not reachable");

    await vi.advanceTimersByTimeAsync(1000); // the scheduled retry fires
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2);

    resolveDiff(1, [makeFile("a.ts")], "sig-a");
    await vi.advanceTimersByTimeAsync(0);

    expect(container.textContent).toContain("a.ts");
    expect(container.textContent).not.toContain("daemon not reachable");
  });

  it("a durable typed error (invalidArgument) still schedules no retry", async () => {
    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0);
    rejectDiff(0, new SpacesBridgeError("invalidArgument", "bad scope"));
    await mounted;
    expect(container.textContent).toContain("bad scope");

    await vi.advanceTimersByTimeAsync(60000);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1); // still never retried
  });
});

describe("mountRoot's refreshDiff — `internalError` joins `unavailable` as a retried exception (round-12 Fix 2)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.notifyModeChanged.mockClear();
    container = document.createElement("div");
    useFakeTimersWithImmediatePaint();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  // Per the daemon-side split (SpacesDeviceWorkspaceDiffEngine.assertRefIsResolvable): a bad ref is
  // now rejected as a durable `invalidArgument`, and `internalError` is reserved for the daemon's own
  // transient git trouble — so unlike before this fix, `internalError` must be retried the same way
  // `unavailable` already is.
  it("renders the internalError message and still schedules a retry at the floor", async () => {
    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0);
    rejectDiff(0, new SpacesBridgeError("internalError", "git command timed out"));
    await mounted;

    expect(container.textContent).toContain("git command timed out");

    // Unlike a permanent typed error, this must retry — at the same 1s floor as an untyped failure.
    await vi.advanceTimersByTimeAsync(999);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1); // not yet due
    await vi.advanceTimersByTimeAsync(1);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2); // retried
  });

  it("recovers automatically once the retry succeeds", async () => {
    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0);
    rejectDiff(0, new SpacesBridgeError("internalError", "git command timed out"));
    await mounted;
    expect(container.textContent).toContain("git command timed out");

    await vi.advanceTimersByTimeAsync(1000); // the scheduled retry fires
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2);

    resolveDiff(1, [makeFile("a.ts")], "sig-a");
    await vi.advanceTimersByTimeAsync(0);

    expect(container.textContent).toContain("a.ts");
    expect(container.textContent).not.toContain("git command timed out");
  });

  it("a bad-ref invalidArgument error still schedules no retry", async () => {
    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0);
    rejectDiff(0, new SpacesBridgeError("invalidArgument", "Ref 'nope' could not be resolved in this workspace."));
    await mounted;
    expect(container.textContent).toContain("could not be resolved");

    await vi.advanceTimersByTimeAsync(60000);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1); // still never retried
  });
});

describe("mountRoot's refreshDiff — a typed error that clears the diff also clears the comments controller's anchor input (round-21 Fix 1)", () => {
  let container: HTMLElement;
  let setCommentsSpy: ReturnType<typeof vi.spyOn>;
  const defaultInitPayload = INIT_PAYLOAD;
  // A provisional (never round-tripped) draft anchored to "a.ts" — same seeding shape as the
  // round-16 Fix 1a test above (`comments.restorePendingState` runs synchronously during init, so
  // this draft exists in the controller's mirror before the first `workspaceDiff` call settles).
  const pendingEntry: PendingReviewCommentEntry = {
    id: "pending-1",
    provisional: true,
    filePath: "a.ts",
    side: "new",
    lineNumber: 3,
    lineText: "const x = 1;",
    body: "seed comment",
  };

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.diffSignatureCallbacks.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.notifyModeChanged.mockClear();
    container = document.createElement("div");
    INIT_PAYLOAD = { ...defaultInitPayload, workspaceState: { ...defaultInitPayload.workspaceState, pendingReviewComments: [pendingEntry] } };
    // Not mocked at the module level (only @pierre/diffs's CodeView is faked): spying on the real
    // CommentsController's own `DiffView.setComments` calls (round-16 Fix 1's same technique, see
    // its doc comment above) is the only place `comments.setFiles([])`'s effect is externally
    // observable — `CommentsController.files` itself is a private field with no getter, and
    // `reanchorComments` only clears a draft's `position` (not its body/tray visibility) when its
    // `filePath` is missing from the file list it was last given.
    setCommentsSpy = vi.spyOn(DiffView.prototype, "setComments");
    useFakeTimersWithImmediatePaint();
  });

  afterEach(() => {
    vi.useRealTimers();
    setCommentsSpy.mockRestore();
    INIT_PAYLOAD = defaultInitPayload;
  });

  /** `undefined` means "a.ts" is missing from whatever file list `comments.setFiles` was last
   *  called with (i.e. the clearing branch under test ran); any defined `position` — even an
   *  "outdated" one — means "a.ts" is still in the controller's file list (`reanchorComments`
   *  only produces `position: undefined` when the file itself isn't present at all). */
  function seededDraftPosition(): unknown {
    const lastCall = setCommentsSpy.mock.calls[setCommentsSpy.mock.calls.length - 1]!;
    const anchored = lastCall[0] as Array<{ comment: { filePath: string }; position: unknown }>;
    return anchored.find((ac) => ac.comment.filePath === "a.ts")?.position;
  }

  it("clears comments' anchor input on the retryable branch (unavailable/internalError), then restores it once the retry succeeds", async () => {
    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0);
    resolveDiff(0, [makeFile("a.ts")], "sig-a");
    await mounted;
    expect(container.textContent).toContain("a.ts");
    expect(seededDraftPosition()).toBeDefined(); // anchored against the loaded "a.ts"

    fireDiffSignature(); // e.g. an agent editing the workspace while this pane is open
    await vi.advanceTimersByTimeAsync(0);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2);

    rejectDiff(1, new SpacesBridgeError("internalError", "git command timed out"));
    await vi.advanceTimersByTimeAsync(0);

    // The seeded draft's own filePath still appears in the tray row's location text (the tray
    // shows a comment's `comment.filePath` regardless of anchoring — see `renderTray`), so "a.ts"
    // presence/absence in `container.textContent` is not a reliable signal here; the file-list/diff
    // area's own clearing is already covered by the round-8/round-12 describe blocks above. What
    // this fix changes is `seededDraftPosition()` below.
    expect(container.textContent).toContain("git command timed out");
    expect(seededDraftPosition()).toBeUndefined(); // comments' anchor input cleared alongside the diff

    await vi.advanceTimersByTimeAsync(1000); // the scheduled retry fires at the floor
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(3);
    resolveDiff(2, [makeFile("a.ts")], "sig-a2");
    await vi.advanceTimersByTimeAsync(0);

    expect(seededDraftPosition()).toBeDefined(); // re-anchored once the files came back
  });

  it("clears comments' anchor input on the durable branch (invalidArgument), and schedules no retry", async () => {
    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0);
    resolveDiff(0, [makeFile("a.ts")], "sig-a");
    await mounted;
    expect(seededDraftPosition()).toBeDefined();

    fireDiffSignature();
    await vi.advanceTimersByTimeAsync(0);
    rejectDiff(1, new SpacesBridgeError("invalidArgument", "Ref 'nope' could not be resolved in this workspace."));
    await vi.advanceTimersByTimeAsync(0);

    expect(container.textContent).toContain("could not be resolved");
    expect(seededDraftPosition()).toBeUndefined(); // comments' anchor input cleared

    // Existing durable-branch expectation (round-8/round-12 blocks above): no retry is scheduled.
    await vi.advanceTimersByTimeAsync(60000);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2); // still never retried
  });

  it("does NOT clear comments' anchor input on an untyped/transport error (the silent retry keeps the old diff and anchors as-is)", async () => {
    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0);
    resolveDiff(0, [makeFile("a.ts")], "sig-a");
    await mounted;
    expect(seededDraftPosition()).toBeDefined();

    fireDiffSignature();
    await vi.advanceTimersByTimeAsync(0);
    rejectDiff(1, new Error("transient transport failure"));
    await vi.advanceTimersByTimeAsync(0);

    expect(container.textContent).toContain("a.ts"); // old diff stays rendered while it silently retries
    expect(seededDraftPosition()).toBeDefined(); // anchors untouched

    await vi.advanceTimersByTimeAsync(1000); // the silent retry fires
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(3);
  });
});

describe("mountRoot's dispatch — a scope switch synchronously clears the previous scope's diff (round-13 Fix 2)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.notifyModeChanged.mockClear();
    container = document.createElement("div");
  });

  it("clears the file list and diff area to a loading state synchronously, with no comments rendered inline, before the new scope's fetch even settles", async () => {
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [makeFile("a.ts")], "sig-a");
    await vi.waitFor(() => expect(container.textContent).toContain("a.ts"));

    switchToLastCommit(container); // dispatches setScope
    // No await/waitFor between the click and these assertions: the clear (file list, diff area,
    // comments collapsed to the tray) happens synchronously inside dispatch itself, not after the
    // fresh refreshDiff's fetch resolves — proving it, rather than a slow poll that would also pass
    // if the clear only happened moments later.
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2); // the new scope's fetch is already in flight
    expect(container.textContent).not.toContain("a.ts");
    expect(container.textContent).toContain("Loading diff…");
    expect(container.querySelector(".comment-card")).toBeNull();

    resolveDiff(1, [makeFile("b.ts")], "sig-b");
    await mounted;
  });

  it("renders the new scope's files correctly once its fetch resolves", async () => {
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [makeFile("a.ts")], "sig-a");
    await vi.waitFor(() => expect(container.textContent).toContain("a.ts"));

    switchToLastCommit(container);
    expect(container.textContent).toContain("Loading diff…");

    resolveDiff(1, [makeFile("b.ts")], "sig-b");
    await vi.waitFor(() => expect(container.textContent).toContain("b.ts"));
    // The manifest sidebar appears before its patch body; the diff surface keeps its loading
    // affordance until that file reaches the append-only ready transition.
    expect(container.textContent).toContain("Loading diff…");
    await mounted;
  });

  it("a rejected fetch (transport-classified error) shows the error, and the old scope's files never reappear at any point", async () => {
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [makeFile("a.ts")], "sig-a");
    await vi.waitFor(() => expect(container.textContent).toContain("a.ts"));

    switchToLastCommit(container);
    // Already cleared synchronously, well before the reject below is even issued.
    expect(container.textContent).not.toContain("a.ts");

    rejectDiff(1, new SpacesBridgeError("notFound", "ref totally-bogus not found"));
    await vi.waitFor(() => expect(container.textContent).toContain("ref totally-bogus not found"));

    expect(container.textContent).not.toContain("a.ts");
    await mounted;
  });
});

describe("mountRoot's spaces:agents wiring", () => {
  let container: HTMLElement;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.notifyModeChanged.mockClear();
    container = document.createElement("div");
  });

  it("re-runs the auto-default rule and updates the toolbar when the running-agent set changes", async () => {
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [], "sig-a");
    await mounted;

    // Zero agents at startup (INIT_PAYLOAD.agents === []): "Send batch" is disabled with the
    // no-agent reason.
    let sendBatchBtn = [...container.querySelectorAll("button")].find((b) =>
      b.textContent?.startsWith("Send batch"),
    ) as HTMLButtonElement;
    expect(sendBatchBtn.disabled).toBe(true);
    expect(sendBatchBtn.title).toBe("No agent is running in this workspace.");

    // spaces:agents reports exactly one running agent: selectDefaultAgentId auto-selects it, and
    // the toolbar re-renders to reflect that (no agent picker needed for a single agent).
    window.dispatchEvent(
      new CustomEvent("spaces:agents", {
        detail: { agents: [{ id: "a1", label: "claude · main", sessionId: "s1" }] },
      }),
    );
    await vi.waitFor(() => {
      const selector = container.querySelector<HTMLSelectElement>("#code-pane-agent-selector");
      expect(selector?.selectedOptions[0]?.textContent).toBe("Send to: claude · main");
    });
    sendBatchBtn = [...container.querySelectorAll("button")].find((b) =>
      b.textContent?.startsWith("Send batch"),
    ) as HTMLButtonElement;
    // Still disabled: an agent is now selected, but there are zero drafts to send.
    expect(sendBatchBtn.title).toBe("No comments to send.");
  });

  it("waits for its keyed detected status before assigning a restored starting session", async () => {
    const defaultInitPayload = INIT_PAYLOAD;
    const launchingAgent = { id: "launching", label: "claude · starting", sessionId: "launch-session" };
    INIT_PAYLOAD = {
      ...defaultInitPayload,
      agents: [launchingAgent],
      workspaceState: {
        ...defaultInitPayload.workspaceState,
        pendingAgentLaunch: {
          sessionId: launchingAgent.sessionId,
          command: "claude",
          status: "starting",
          message: null,
          deadlineEpochMilliseconds: Date.now() + 60_000,
        },
        pendingReviewComments: [
          {
            id: "waiting-for-detection",
            provisional: true,
            filePath: "draft.ts",
            side: "new",
            lineNumber: 1,
            lineText: "draft line",
            body: "please review",
          },
        ],
      },
    };
    hoisted.reviewCommentList.mockReset().mockResolvedValue([]);
    hoisted.resumeWorkspaceCommandTracking.mockResolvedValueOnce({
      sessionId: launchingAgent.sessionId,
      status: "starting",
      deadlineEpochMilliseconds: INIT_PAYLOAD.workspaceState.pendingAgentLaunch!.deadlineEpochMilliseconds,
    });
    try {
      const mounted = mountRoot(container);
      await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
      resolveDiff(0, [], "restored-starting-agent-sig");
      await mounted;

      let sendBatch = [...container.querySelectorAll<HTMLButtonElement>("button")].find(
        (button) => button.textContent === "Send batch · 1",
      )!;
      expect(container.querySelector(".agent-label")?.textContent).toBe("Starting agent…");
      expect(sendBatch.disabled).toBe(true);
      expect(sendBatch.title).toBe("Pick an agent to send to.");
      expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").selectedAgentSessionId).toBeNull();

      // A full running-agent overview can include the terminal before its hook-backed readiness
      // event. It stays visible, but is not assignable until the matching keyed event arrives.
      window.dispatchEvent(new CustomEvent("spaces:agents", { detail: { agents: [launchingAgent] } }));
      await vi.waitFor(() => expect(sendBatch.disabled).toBe(true));
      expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").selectedAgentSessionId).toBeNull();

      window.dispatchEvent(
        new CustomEvent("spaces:agentStartStatus", {
          detail: { sessionId: launchingAgent.sessionId, status: "detected", agent: launchingAgent },
        }),
      );
      await vi.waitFor(() => {
        const selector = container.querySelector<HTMLSelectElement>("#code-pane-agent-selector");
        expect(selector?.selectedOptions[0]?.textContent).toBe("Send to: claude · starting");
      });
      sendBatch = [...container.querySelectorAll<HTMLButtonElement>("button")].find(
        (button) => button.textContent === "Send batch · 1",
      )!;
      expect(sendBatch.disabled).toBe(false);
      expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").selectedAgentSessionId).toBe(launchingAgent.sessionId);
    } finally {
      INIT_PAYLOAD = defaultInitPayload;
      hoisted.reviewCommentList.mockReset().mockResolvedValue([]);
    }
  });

  it("keeps a different restored assignment usable while another session is still starting", async () => {
    const defaultInitPayload = INIT_PAYLOAD;
    const assignedAgent = { id: "assigned", label: "codex · review", sessionId: "assigned-session" };
    const launchingAgent = { id: "launching", label: "claude · starting", sessionId: "launch-session" };
    INIT_PAYLOAD = {
      ...defaultInitPayload,
      agents: [assignedAgent, launchingAgent],
      workspaceState: {
        ...defaultInitPayload.workspaceState,
        selectedAgentSessionId: assignedAgent.sessionId,
        pendingAgentLaunch: {
          sessionId: launchingAgent.sessionId,
          command: "claude",
          status: "starting",
          message: null,
          deadlineEpochMilliseconds: Date.now() + 60_000,
        },
        pendingReviewComments: [
          {
            id: "send-with-existing-agent",
            provisional: true,
            filePath: "draft.ts",
            side: "new",
            lineNumber: 1,
            lineText: "draft line",
            body: "please review",
          },
        ],
      },
    };
    hoisted.reviewCommentList.mockReset().mockResolvedValue([]);
    hoisted.resumeWorkspaceCommandTracking.mockResolvedValueOnce({
      sessionId: launchingAgent.sessionId,
      status: "starting",
      deadlineEpochMilliseconds: INIT_PAYLOAD.workspaceState.pendingAgentLaunch!.deadlineEpochMilliseconds,
    });
    try {
      const mounted = mountRoot(container);
      await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
      resolveDiff(0, [], "starting-with-assigned-agent-sig");
      await mounted;

      const sendBatch = [...container.querySelectorAll<HTMLButtonElement>("button")].find(
        (button) => button.textContent === "Send batch · 1",
      )!;
      expect(container.querySelector(".agent-label")?.textContent).toBe("Starting agent…");
      expect(sendBatch.disabled).toBe(false);
      expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").selectedAgentSessionId).toBe(assignedAgent.sessionId);

      window.dispatchEvent(new CustomEvent("spaces:agents", { detail: { agents: [assignedAgent, launchingAgent] } }));
      await vi.waitFor(() => expect(sendBatch.disabled).toBe(false));
      expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").selectedAgentSessionId).toBe(assignedAgent.sessionId);
    } finally {
      INIT_PAYLOAD = defaultInitPayload;
      hoisted.reviewCommentList.mockReset().mockResolvedValue([]);
    }
  });

  it("keeps an assigned agent's Send batch available through a 90-second new-agent detection wait", async () => {
    const defaultInitPayload = INIT_PAYLOAD;
    const agent = { id: "a1", label: "claude · main", sessionId: "s1" };
    INIT_PAYLOAD = {
      ...defaultInitPayload,
      agents: [agent],
      workspaceState: {
        ...defaultInitPayload.workspaceState,
        selectedAgentSessionId: agent.sessionId,
        pendingReviewComments: [
          {
            id: "pending-sendable",
            provisional: true,
            filePath: "draft.ts",
            side: "new",
            lineNumber: 1,
            lineText: "draft line",
            body: "please review",
          },
        ],
      },
    };
    hoisted.reviewCommentList.mockReset().mockResolvedValue([]);
    useFakeTimersWithImmediatePaint();
    try {
      const mounted = mountRoot(container);
      await vi.advanceTimersByTimeAsync(0);
      resolveDiff(0, [], "starting-agent-sig");
      await vi.advanceTimersByTimeAsync(0);
      await mounted;

      const selector = container.querySelector<HTMLSelectElement>("#code-pane-agent-selector")!;
      selector.value = "__start_new_agent__";
      selector.dispatchEvent(new Event("change"));
      const input = container.querySelector<HTMLInputElement>("#code-pane-start-agent-command")!;
      input.value = "sleep 90";
      input.dispatchEvent(new Event("input"));
      input.closest("form")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
      await vi.advanceTimersByTimeAsync(0);

      const sendBatch = [...container.querySelectorAll<HTMLButtonElement>("button")].find(
        (button) => button.textContent === "Send batch · 1",
      )!;
      expect(container.querySelector(".agent-label")?.textContent).toBe("Starting agent…");
      expect(sendBatch.disabled).toBe(false);

      // The launch may legitimately take a long time to emit a hook. It is a separate target from
      // the already assigned running agent, so ordinary comment sending remains available.
      await vi.advanceTimersByTimeAsync(90_000);
      expect(container.querySelector(".agent-label")?.textContent).toBe("Starting agent…");
      expect(sendBatch.disabled).toBe(false);
    } finally {
      INIT_PAYLOAD = defaultInitPayload;
      hoisted.reviewCommentList.mockReset().mockResolvedValue([]);
      vi.useRealTimers();
      window.requestAnimationFrame = nativeRequestAnimationFrame;
    }
  });

  it("merges a detected agent before selecting it when status arrives ahead of the agents overview", async () => {
    const defaultInitPayload = INIT_PAYLOAD;
    const existingAgent = { id: "a1", label: "claude · main", sessionId: "s1" };
    const detectedAgent = { id: "a2", label: "codex · review", sessionId: "s2" };
    INIT_PAYLOAD = {
      ...defaultInitPayload,
      agents: [existingAgent],
      workspaceState: {
        ...defaultInitPayload.workspaceState,
        selectedAgentSessionId: existingAgent.sessionId,
        pendingReviewComments: [
          {
            id: "status-before-overview",
            provisional: true,
            filePath: "draft.ts",
            side: "new",
            lineNumber: 1,
            lineText: "draft line",
            body: "please review",
          },
        ],
      },
    };
    hoisted.reviewCommentList.mockReset().mockResolvedValue([]);
    hoisted.startWorkspaceCommand.mockClear();
    try {
      const mounted = mountRoot(container);
      await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
      resolveDiff(0, [], "detected-before-overview-sig");
      await mounted;

      const selector = container.querySelector<HTMLSelectElement>("#code-pane-agent-selector")!;
      selector.value = "__start_new_agent__";
      selector.dispatchEvent(new Event("change"));
      const input = container.querySelector<HTMLInputElement>("#code-pane-start-agent-command")!;
      input.value = "codex review";
      input.dispatchEvent(new Event("input"));
      input.closest("form")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
      await vi.waitFor(() => expect(hoisted.startWorkspaceCommand).toHaveBeenCalledTimes(1));

      hoisted.notifyWorkspaceStateChanged.mockClear();
      window.dispatchEvent(
        new CustomEvent("spaces:agentStartStatus", {
          detail: { sessionId: "command-1", status: "detected", agent: detectedAgent },
        }),
      );

      await vi.waitFor(() => {
        const detectedSelector = container.querySelector<HTMLSelectElement>("#code-pane-agent-selector");
        expect(detectedSelector?.selectedOptions[0]?.textContent).toBe("Send to: codex · review");
      });
      const selected = container.querySelector<HTMLSelectElement>("#code-pane-agent-selector")!;
      expect([...selected.options].map((option) => option.value)).toEqual(expect.arrayContaining([existingAgent.id, detectedAgent.id]));
      const sendBatch = [...container.querySelectorAll<HTMLButtonElement>("button")].find(
        (button) => button.textContent === "Send batch · 1",
      )!;
      expect(sendBatch.disabled).toBe(false);
      expect(hoisted.notifyWorkspaceStateChanged).toHaveBeenLastCalledWith(
        expect.objectContaining({ selectedAgentSessionId: detectedAgent.sessionId }),
      );
    } finally {
      INIT_PAYLOAD = defaultInitPayload;
      hoisted.reviewCommentList.mockReset().mockResolvedValue([]);
    }
  });

  it("restores a failed Start Agent command and its feedback when retrying after restart", async () => {
    const defaultInitPayload = INIT_PAYLOAD;
    const command = "claude --resume";
    const failure = "The command exited (failed) before its agent hooks registered.";
    INIT_PAYLOAD = {
      ...defaultInitPayload,
      workspaceState: {
        ...defaultInitPayload.workspaceState,
        pendingAgentLaunch: {
          sessionId: "command-failed",
          command,
          status: "failed",
          message: failure,
          deadlineEpochMilliseconds: null,
        },
      },
    };
    try {
      const mounted = mountRoot(container);
      await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
      resolveDiff(0, [], "failed-launch-sig");
      await mounted;

      (container.querySelector<HTMLButtonElement>("#code-pane-start-agent"))!.click();

      const dialog = container.querySelector<HTMLElement>("#code-pane-start-agent-dialog")!;
      expect(dialog.hidden).toBe(false);
      expect(dialog.getAttribute("aria-labelledby")).toBe("code-pane-start-agent-title");
      expect(container.querySelector<HTMLElement>("#code-pane-start-agent-title")?.textContent).toBe(
        "Start an agent to receive review comments",
      );
      const commandInput = container.querySelector<HTMLInputElement>("#code-pane-start-agent-command")!;
      expect(commandInput.value).toBe(command);
      expect(commandInput.getAttribute("autocapitalize")).toBe("none");
      const status = container.querySelector<HTMLElement>("#code-pane-start-agent-status")!;
      expect(status.textContent).toContain("No agent detected");
      expect(status.textContent).toContain(failure);
    } finally {
      INIT_PAYLOAD = defaultInitPayload;
    }
  });

  it("keeps the Editor focused when a started command reports no agent", async () => {
    const defaultInitPayload = INIT_PAYLOAD;
    INIT_PAYLOAD = defaultInitPayload;
    hoisted.startWorkspaceCommand.mockResolvedValueOnce({
      sessionId: "command-no-agent",
      status: "starting",
      deadlineEpochMilliseconds: 90_000,
    });
    try {
      document.body.appendChild(container);
      const mounted = mountRoot(container);
      await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
      resolveDiff(0, [], "start-no-agent-focus-sig");
      await mounted;
      const codeBody = container.querySelector<HTMLElement>(".code-body")!;
      expect(container.querySelectorAll("#code-pane-editor-focus")).toHaveLength(1);
      expect(container.querySelector("#code-pane-editor-focus")).toBe(codeBody.lastElementChild);

      const startButton = container.querySelector<HTMLButtonElement>("#code-pane-start-agent")!;
      startButton.click();
      const status = container.querySelector<HTMLElement>("#code-pane-start-agent-status")!;
      expect(status.getAttribute("role")).toBe("status");
      expect(status.getAttribute("aria-live")).toBe("polite");
      expect(status.getAttribute("aria-atomic")).toBe("true");
      const input = container.querySelector<HTMLInputElement>("#code-pane-start-agent-command")!;
      input.value = "sleep 1";
      input.dispatchEvent(new Event("input"));
      input.closest("form")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
      await vi.waitFor(() => expect(hoisted.startWorkspaceCommand).toHaveBeenCalledWith("sleep 1"));
      await vi.waitFor(() => expect(container.querySelector<HTMLElement>("#code-pane-start-agent-dialog")?.hidden).toBe(true));
      expect(document.activeElement).toBe(container.querySelector<HTMLElement>("#code-pane-editor-focus"));

      window.dispatchEvent(
        new CustomEvent("spaces:agentStartStatus", {
          detail: { sessionId: "command-no-agent", status: "failed", message: "No agent detected" },
        }),
      );
      await vi.waitFor(() => expect(container.querySelector<HTMLElement>("#code-pane-start-agent-dialog")?.hidden).toBe(false));
      expect(document.activeElement).toBe(container.querySelector<HTMLElement>("#code-pane-editor-focus"));
      expect(status.getAttribute("aria-label")).toContain("No agent detected");

      window.dispatchEvent(new CustomEvent("spaces:setMode", { detail: { mode: "editor" } }));
      expect(container.querySelectorAll("#code-pane-editor-focus")).toHaveLength(1);
      expect(container.querySelector("#code-pane-editor-focus")).toBe(codeBody.lastElementChild);
      container.querySelector<HTMLButtonElement>("#code-pane-start-agent-cancel")!.click();
      expect(document.activeElement).toBe(container.querySelector<HTMLElement>("#code-pane-editor-focus"));

      window.dispatchEvent(new CustomEvent("spaces:setMode", { detail: { mode: "diff" } }));
      expect(container.querySelectorAll("#code-pane-editor-focus")).toHaveLength(1);
      expect(container.querySelector("#code-pane-editor-focus")).toBe(codeBody.lastElementChild);
    } finally {
      container.remove();
      INIT_PAYLOAD = defaultInitPayload;
    }
  });

  it("validates a Start Agent command without trimming the command it launches or persists", async () => {
    const command = "  env FOO=bar codex review  ";
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [], "start-agent-verbatim-command");
    await mounted;

    container.querySelector<HTMLButtonElement>("#code-pane-start-agent")!.click();
    const input = container.querySelector<HTMLInputElement>("#code-pane-start-agent-command")!;
    input.value = command;
    input.dispatchEvent(new Event("input"));
    input.closest("form")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));

    await vi.waitFor(() => expect(hoisted.startWorkspaceCommand).toHaveBeenCalledWith(command));
    await vi.waitFor(() =>
      expect(hoisted.notifyWorkspaceStateChanged).toHaveBeenLastCalledWith(
        expect.objectContaining({ pendingAgentLaunch: expect.objectContaining({ command }) }),
      ),
    );
  });

  it("persists the host-minted readiness deadline when a command starts", async () => {
    const deadlineEpochMilliseconds = 1_756_420_000_000;
    hoisted.startWorkspaceCommand.mockResolvedValueOnce({
      sessionId: "command-with-deadline",
      status: "starting",
      deadlineEpochMilliseconds,
    });
    hoisted.notifyWorkspaceStateChanged.mockClear();
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [], "start-deadline-sig");
    await mounted;

    (container.querySelector<HTMLButtonElement>("#code-pane-start-agent"))!.click();
    const input = container.querySelector<HTMLInputElement>("#code-pane-start-agent-command")!;
    input.value = "claude --resume";
    input.dispatchEvent(new Event("input"));
    input.closest("form")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));

    await vi.waitFor(() => expect(hoisted.startWorkspaceCommand).toHaveBeenCalledWith("claude --resume"));
    await vi.waitFor(() =>
      expect(
        hoisted.notifyWorkspaceStateChanged.mock.calls
          .map(([snapshot]) => snapshot as CodePaneWorkspaceState)
          .some(
            (snapshot) =>
              snapshot.pendingAgentLaunch?.sessionId === "command-with-deadline" &&
              snapshot.pendingAgentLaunch.deadlineEpochMilliseconds === deadlineEpochMilliseconds,
          ),
      ).toBe(true),
    );
  });

  it("does not launch a second command while the first Start Agent request is in flight", async () => {
    hoisted.startWorkspaceCommand.mockClear();
    let resolveFirst!: (result: { sessionId: string; status: "starting"; deadlineEpochMilliseconds: number }) => void;
    hoisted.startWorkspaceCommand.mockImplementationOnce(
      () => new Promise((resolve) => { resolveFirst = resolve; }),
    );
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [], "start-in-flight-sig");
    await mounted;

    const startButton = container.querySelector<HTMLButtonElement>("#code-pane-start-agent")!;
    startButton.click();
    const input = container.querySelector<HTMLInputElement>("#code-pane-start-agent-command")!;
    input.value = "claude";
    input.dispatchEvent(new Event("input"));
    input.closest("form")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
    expect(hoisted.startWorkspaceCommand).toHaveBeenCalledTimes(1);

    // Cancelling only hides the dialog; it cannot cancel the already-issued bridge request. Reopen
    // it and submit another command to reproduce the duplicate-launch race.
    (container.querySelector<HTMLButtonElement>("#code-pane-start-agent-cancel")!).click();
    container.querySelector<HTMLButtonElement>("#code-pane-start-agent")!.click();
    const reopenedInput = container.querySelector<HTMLInputElement>("#code-pane-start-agent-command")!;
    reopenedInput.value = "codex";
    reopenedInput.dispatchEvent(new Event("input"));
    expect(container.querySelector<HTMLButtonElement>("#code-pane-start-agent-submit")!.disabled).toBe(true);
    reopenedInput.closest("form")!.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
    expect(hoisted.startWorkspaceCommand).toHaveBeenCalledTimes(1);

    resolveFirst({ sessionId: "first-session", status: "starting", deadlineEpochMilliseconds: 90_000 });
    await vi.waitFor(() => expect(hoisted.notifyWorkspaceStateChanged).toHaveBeenCalled());
  });
});

describe("mountRoot's restored Start Agent tracking", () => {
  const defaultInitPayload = INIT_PAYLOAD;
  let container: HTMLElement;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.resumeWorkspaceCommandTracking.mockClear();
    hoisted.notifyWorkspaceStateChanged.mockClear();
    container = document.createElement("div");
    useFakeTimersWithImmediatePaint();
    vi.setSystemTime(new Date("2026-08-26T00:00:00.000Z"));
  });

  afterEach(() => {
    INIT_PAYLOAD = defaultInitPayload;
    vi.useRealTimers();
    window.requestAnimationFrame = nativeRequestAnimationFrame;
  });

  it("retries an unavailable restored tracker before its original deadline and keeps the launch starting on recovery", async () => {
    const deadlineEpochMilliseconds = Date.now() + 10_000;
    const launch = {
      sessionId: "resume-session",
      command: "claude --resume",
      status: "starting" as const,
      message: null,
      deadlineEpochMilliseconds,
    };
    INIT_PAYLOAD = {
      ...defaultInitPayload,
      workspaceState: { ...defaultInitPayload.workspaceState, pendingAgentLaunch: launch },
    };
    hoisted.resumeWorkspaceCommandTracking
      .mockRejectedValueOnce(new SpacesBridgeError("unavailable", "device reconnecting"))
      .mockResolvedValueOnce({ sessionId: launch.sessionId, status: "starting", deadlineEpochMilliseconds });

    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0);
    expect(hoisted.resumeWorkspaceCommandTracking).toHaveBeenCalledTimes(1);
    resolveDiff(0, [], "resume-retry-sig");
    await vi.advanceTimersByTimeAsync(0);
    await mounted;

    await vi.advanceTimersByTimeAsync(999);
    expect(hoisted.resumeWorkspaceCommandTracking).toHaveBeenCalledTimes(1);
    await vi.advanceTimersByTimeAsync(1);
    await vi.waitFor(() => expect(hoisted.resumeWorkspaceCommandTracking).toHaveBeenCalledTimes(2));

    const snapshot = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}");
    expect(snapshot.pendingAgentLaunch).toEqual(launch);
    expect(container.querySelector(".agent-label")?.textContent).toBe("Starting agent…");
  });

  it("treats a timeout-shaped tracker rejection as transient before the original deadline", async () => {
    const deadlineEpochMilliseconds = Date.now() + 10_000;
    const launch = {
      sessionId: "timeout-resume-session",
      command: "codex --resume",
      status: "starting" as const,
      message: null,
      deadlineEpochMilliseconds,
    };
    INIT_PAYLOAD = {
      ...defaultInitPayload,
      workspaceState: { ...defaultInitPayload.workspaceState, pendingAgentLaunch: launch },
    };
    hoisted.resumeWorkspaceCommandTracking
      .mockRejectedValueOnce(new Error("resume request timed out"))
      .mockResolvedValueOnce({ sessionId: launch.sessionId, status: "starting", deadlineEpochMilliseconds });

    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0);
    resolveDiff(0, [], "resume-timeout-retry-sig");
    await vi.advanceTimersByTimeAsync(0);
    await mounted;
    await vi.advanceTimersByTimeAsync(1000);

    expect(hoisted.resumeWorkspaceCommandTracking).toHaveBeenCalledTimes(2);
    expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").pendingAgentLaunch).toEqual(launch);
  });

  it("reconciles an expired restored session once so native can still detect and assign its agent", async () => {
    const launch = {
      sessionId: "already-expired-session",
      command: "claude --resume",
      status: "starting" as const,
      message: null,
      deadlineEpochMilliseconds: Date.now() - 1,
    };
    const detectedAgent = { id: "detected-after-deadline", label: "Claude", sessionId: launch.sessionId };
    INIT_PAYLOAD = {
      ...defaultInitPayload,
      workspaceState: { ...defaultInitPayload.workspaceState, pendingAgentLaunch: launch },
    };
    hoisted.resumeWorkspaceCommandTracking.mockResolvedValue({
      sessionId: launch.sessionId,
      status: "starting",
      deadlineEpochMilliseconds: launch.deadlineEpochMilliseconds,
    });

    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0);
    expect(hoisted.resumeWorkspaceCommandTracking).toHaveBeenCalledExactlyOnceWith(launch.sessionId);
    resolveDiff(0, [], "resume-expired-detected-sig");
    await vi.advanceTimersByTimeAsync(0);
    await mounted;

    // Native owns the terminal conclusion after the original deadline. It can still find a hook
    // that registered while this pane was absent, and the normal keyed event assigns it.
    window.dispatchEvent(
      new CustomEvent("spaces:agentStartStatus", {
        detail: { sessionId: launch.sessionId, status: "detected", agent: detectedAgent },
      }),
    );
    await vi.waitFor(() =>
      expect(container.querySelector<HTMLSelectElement>("#code-pane-agent-selector")?.selectedOptions[0]?.textContent).toBe("Send to: Claude"),
    );
    expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").pendingAgentLaunch).toBeNull();

    await vi.advanceTimersByTimeAsync(100_000);
    expect(hoisted.resumeWorkspaceCommandTracking).toHaveBeenCalledTimes(1);
  });

  it("fails a restored launch at its original deadline after transient tracker errors and retains its command", async () => {
    const deadlineEpochMilliseconds = Date.now() + 500;
    const launch = {
      sessionId: "expired-resume-session",
      command: "claude --resume",
      status: "starting" as const,
      message: null,
      deadlineEpochMilliseconds,
    };
    INIT_PAYLOAD = {
      ...defaultInitPayload,
      workspaceState: { ...defaultInitPayload.workspaceState, pendingAgentLaunch: launch },
    };
    hoisted.resumeWorkspaceCommandTracking.mockRejectedValue(new SpacesBridgeError("unavailable", "device reconnecting"));

    const mounted = mountRoot(container);
    await vi.advanceTimersByTimeAsync(0);
    expect(hoisted.resumeWorkspaceCommandTracking).toHaveBeenCalledTimes(1);
    resolveDiff(0, [], "resume-expiry-sig");
    await vi.advanceTimersByTimeAsync(0);
    await mounted;

    await vi.advanceTimersByTimeAsync(500);
    const snapshot = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}");
    expect(snapshot.pendingAgentLaunch).toEqual({
      sessionId: launch.sessionId,
      command: launch.command,
      status: "failed",
      message: "Timed out waiting for an agent to start.",
      deadlineEpochMilliseconds: null,
    });
    // The first transient resume used the remaining readiness window; expiry gets exactly one
    // terminal native reconciliation and never schedules another retry window.
    expect(hoisted.resumeWorkspaceCommandTracking).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(100_000);
    expect(hoisted.resumeWorkspaceCommandTracking).toHaveBeenCalledTimes(2);
  });
});

describe("mountRoot's mode toggle — notifyModeChanged push (round-5 hibernation fix)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.notifyModeChanged.mockClear();
    container = document.createElement("div");
  });

  it("pushes the live mode to the host on every toolbar toggle, so a hibernated pane restores to it", async () => {
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [], "sig-a");
    await mounted;

    hoisted.notifyModeChanged.mockClear();

    clickButton(container, "Editor");
    expect(hoisted.notifyModeChanged).toHaveBeenCalledExactlyOnceWith("editor");

    clickButton(container, "Diff");
    expect(hoisted.notifyModeChanged).toHaveBeenNthCalledWith(2, "diff");
  });
});

describe("mountRoot's mode-switch position persistence", () => {
  let container: HTMLElement;
  const defaultInitPayload = INIT_PAYLOAD;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    INIT_PAYLOAD = defaultInitPayload;
    container = document.createElement("div");
  });

  afterEach(() => {
    INIT_PAYLOAD = defaultInitPayload;
    container.remove();
  });

  it("keeps each view's durable position through repeated state pushes after the other view detaches", async () => {
    document.body.appendChild(container);
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [], "mode-position-sig");
    await mounted;

    const diffRoot = container.querySelector<HTMLElement>("#code-pane-diff-scroll")!;
    const diffLine = document.createElement("div");
    diffLine.dataset.line = "17";
    diffLine.dataset.diffPath = "diff-visible.ts";
    diffLine.dataset.diffSide = "old";
    Object.defineProperty(diffRoot, "getBoundingClientRect", { value: () => ({ top: 0 }) });
    Object.defineProperty(diffLine, "getBoundingClientRect", {
      value: () => ({ bottom: container.contains(diffLine) ? 1 : -1 }),
    });
    diffRoot.appendChild(diffLine);

    clickButton(container, "Editor");
    let snapshot = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}");
    expect(snapshot).toMatchObject({
      mode: "editor",
      diffSelectedPath: "diff-visible.ts",
      diffScrollLine: 17,
      diffScrollSide: "old",
    });

    const editorRoot = container.querySelector<HTMLElement>("#code-pane-editor-scroll")!;
    const editorLine = document.createElement("div");
    editorLine.dataset.line = "29";
    Object.defineProperty(editorRoot, "getBoundingClientRect", { value: () => ({ top: 0 }) });
    Object.defineProperty(editorLine, "getBoundingClientRect", {
      value: () => ({ bottom: container.contains(editorLine) ? 1 : -1 }),
    });
    editorRoot.appendChild(editorLine);

    clickButton(container, "Diff");
    snapshot = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}");
    expect(snapshot).toMatchObject({
      mode: "diff",
      diffSelectedPath: "diff-visible.ts",
      diffScrollLine: 17,
      editorScrollLine: 29,
    });

    clickButton(container, "Editor");
    snapshot = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}");
    expect(snapshot).toMatchObject({
      mode: "editor",
      diffSelectedPath: "diff-visible.ts",
      diffScrollLine: 17,
      editorScrollLine: 29,
    });
  });

  it("clears the prior scope's diff position before persisting a new comparison scope", async () => {
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [makeFile("old-scope.ts")], "old-scope-position-sig");
    await mounted;

    capturedCodeViewOptions.current!.onLineClick!(
      { type: "diff-line", lineNumber: 10, annotationSide: "deletions" },
      { type: "diff", item: { id: "old-scope.ts" } },
    );

    const diffRoot = container.querySelector<HTMLElement>("#code-pane-diff-scroll")!;
    const diffLine = document.createElement("div");
    diffLine.dataset.line = "9";
    diffLine.dataset.diffPath = "old-scope.ts";
    diffLine.dataset.diffSide = "new";
    Object.defineProperty(diffRoot, "getBoundingClientRect", { value: () => ({ top: 0 }) });
    Object.defineProperty(diffLine, "getBoundingClientRect", { value: () => ({ bottom: 1 }) });
    diffRoot.appendChild(diffLine);

    switchToLastCommit(container);
    const snapshot = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}");
    expect(snapshot).toMatchObject({
      scope: { kind: "lastCommit" },
      diffSelectedPath: null,
      diffScrollLine: null,
      diffScrollSide: null,
      diffFocusedPath: null,
      diffFocusedLine: null,
      diffFocusedSide: null,
    });

    resolveDiff(1, [], "new-scope-position-sig");
    await vi.waitFor(() => expect(container.textContent).not.toContain("Loading diff…"));
  });
});

describe("mountRoot's spaces:setMode wiring", () => {
  let container: HTMLElement;
  const defaultInitPayload = INIT_PAYLOAD;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.notifyModeChanged.mockClear();
    container = document.createElement("div");
  });

  afterEach(() => {
    INIT_PAYLOAD = defaultInitPayload;
  });

  // `window.dispatchEvent` is global and every pane mounted anywhere in this test file (jsdom
  // shares one `window` for the whole run — real usage is one pane per WKWebView, each with its
  // own `window`) keeps its `spaces:setMode` listener attached forever, so a dispatch here also
  // reaches every stale pane from earlier tests. Every stale pane is left in `initialMode: "diff"`
  // (nothing before this describe block ever switches a pane to editor and leaves it there — see
  // the mode-toggle block above, which always ends back on "diff"), so this no-op case is ordered
  // BEFORE the real-switch case below: dispatching `{mode: "diff"}` while every currently-attached
  // pane (including this test's own) is already in "diff" is a true zero-calls no-op for all of
  // them, not just this test's pane. Reversing the order would poison every later pane's mode and
  // make this assertion meaningless (see the real-switch test's own comment on the same issue).
  it("no-ops when the pane is already in the requested mode", async () => {
    const mounted = mountRoot(container); // INIT_PAYLOAD.initialMode === "diff"
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [], "sig-a");
    await mounted;

    const diffCallsBefore = hoisted.workspaceDiff.mock.calls.length;

    window.dispatchEvent(new CustomEvent("spaces:setMode", { detail: { mode: "diff" } }));

    expect(hoisted.workspaceDiff.mock.calls.length).toBe(diffCallsBefore); // no extra refreshDiff
  });

  it("switches the live mode and pushes notifyModeChanged, the same as a toolbar click, leaving in-progress editor state untouched", async () => {
    const dirtyEditorState: CodePaneEditorState = {
      path: "/repo/src/foo.ts",
      baseSHA256: "deadbeef",
      baseContent: "let x = 0;\n",
      content: "let x = 1;\n",
      dirty: true,
      conflict: false,
    };
    INIT_PAYLOAD = { ...defaultInitPayload, workspaceState: { ...defaultInitPayload.workspaceState, editorState: dirtyEditorState } };

    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [], "sig-a");
    await mounted;

    // This dispatch also reaches every stale pane still attached from earlier tests (see the
    // no-op test's comment above), so it fires more than once — but `addEventListener` invokes
    // listeners in registration order, and this pane is always the most-recently mounted, so its
    // call is always the LAST one recorded for this dispatch regardless of how many stale panes
    // also fire.
    window.dispatchEvent(new CustomEvent("spaces:setMode", { detail: { mode: "editor" } }));

    expect(hoisted.notifyModeChanged).toHaveBeenCalled();
    expect(hoisted.notifyModeChanged.mock.calls.at(-1)).toEqual(["editor"]);
    // `.file-list` is shared across both modes (Design K); what swaps is its single child — Editor
    // mode's Files/Changes sidebar (`.editor-sidebar`) replaces Diff mode's bare changed-files list.
    expect(container.querySelector(".editor-sidebar")).not.toBeNull();

    // The dirty snapshot restored at startup is still live in EditorView, untouched by the mode
    // switch — collectStateForFlush would return null/empty if the switch had reset it.
    // `window.__spacesCollectEditorState` is instance-safe even under the shared-`window` pollution
    // above: every mount overwrites it to point at that exact instance (see its wiring in root.ts).
    const collected = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}");
    expect(collected.editorState).toEqual(dirtyEditorState);
  });

  it("reports the restored Editor path instead of a stale diff selection", async () => {
    const editorState: CodePaneEditorState = {
      path: ".spaces-e2e-stream/stream-state.txt",
      baseSHA256: "deadbeef",
      baseContent: "let x = 0;\n",
      content: "let x = 1;\n",
      dirty: true,
      conflict: false,
    };
    INIT_PAYLOAD = {
      ...defaultInitPayload,
      workspaceState: {
        ...defaultInitPayload.workspaceState,
        mode: "editor",
        diffSelectedPath: ".spaces-e2e-stream/stream-edit.txt",
        editorState,
      },
    };

    await mountRoot(container);
    await vi.waitFor(() => {
      const metric = hoisted.notifyRenderMetric.mock.calls
        .map(([value]) => value as { trigger?: string; mode?: string; path?: string; dirty?: boolean })
        .find((value) => value.trigger === "workspaceStateRestored" && value.mode === "editor");
      expect(metric).toEqual(expect.objectContaining({ path: editorState.path, dirty: true }));
    });
  });
});

describe("mountRoot's init ordering — the hibernated editor snapshot is restored before any teardown-vulnerable await (round-11 Fix 1)", () => {
  let container: HTMLElement;
  const defaultInitPayload = INIT_PAYLOAD;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.notifyModeChanged.mockClear();
    container = document.createElement("div");
  });

  afterEach(() => {
    INIT_PAYLOAD = defaultInitPayload;
  });

  it("a teardown flush while refreshDiff is still pending reflects the real dirty snapshot, not an empty placeholder", async () => {
    const dirtyEditorState: CodePaneEditorState = {
      path: "/repo/src/foo.ts",
      baseSHA256: "deadbeef",
      baseContent: "let x = 0;\n",
      content: "let x = 1;\n",
      dirty: true,
      conflict: false,
    };
    INIT_PAYLOAD = { ...defaultInitPayload, workspaceState: { ...defaultInitPayload.workspaceState, editorState: dirtyEditorState } };

    const mounted = mountRoot(container);
    // `refreshDiff`'s own `workspaceDiff` call is this init's first network await (mode is "diff"
    // by default) — it parks here per this file's controllable-bridge mechanism, standing in for
    // the Swift host tearing this pane down before init has fully settled.
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));

    // Before Fix 1, `editorView.restoreState` ran after this await, so `EditorView` would still be
    // empty here and this flush would return `null` — silently overwriting the host's hibernated
    // snapshot with nothing. Fix 1 moves the restore above every network await in the init tail, so
    // the buffer is already live by the time this synchronous teardown pull can fire.
    const collected = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}");
    expect(collected.editorState).toEqual(dirtyEditorState);

    resolveDiff(0, [], "sig-a");
    await mounted;
  });

  it("seeds the inactive diff position before an Editor-mode startup can be torn down", async () => {
    INIT_PAYLOAD = {
      ...defaultInitPayload,
      workspaceState: {
        ...defaultInitPayload.workspaceState,
        mode: "editor",
        diffSelectedPath: "inactive.ts",
        diffScrollLine: 17,
        diffScrollSide: "new",
        diffFocusedPath: "inactive.ts",
        diffFocusedLine: 18,
        diffFocusedSide: "new",
      },
    };

    window.__spacesCollectWorkspaceState = undefined;
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(window.__spacesCollectWorkspaceState).toBeDefined());

    const collected = JSON.parse(window.__spacesCollectWorkspaceState!());
    expect(collected).toMatchObject({
      diffSelectedPath: "inactive.ts",
      diffScrollLine: 17,
      diffScrollSide: "new",
      diffFocusedPath: "inactive.ts",
      diffFocusedLine: 18,
      diffFocusedSide: "new",
    });

    await mounted;
  });
});

describe("mountRoot's init ordering — the seeded pending comment state is restored before any teardown-vulnerable await (round-16 Fix 1a)", () => {
  let container: HTMLElement;
  const defaultInitPayload = INIT_PAYLOAD;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.notifyModeChanged.mockClear();
    container = document.createElement("div");
  });

  afterEach(() => {
    INIT_PAYLOAD = defaultInitPayload;
  });

  it("a teardown flush while refreshDiff is still pending reflects the seeded pending comment, not an empty snapshot", async () => {
    // A still-provisional pending entry (never round-tripped to the daemon — see
    // `CommentsController`'s class doc comment) is the shape `restorePendingState` can prove this
    // early: its branch recreates a local draft (and seeds `liveBodies`) synchronously, no network
    // round trip involved. A *persisted* (`provisional: false`) entry's branch only seeds
    // `liveBodies` — the matching draft object itself only reappears once `loadInitial()`'s
    // `reviewCommentList` reply lands and merges it in, which happens strictly after this checkpoint
    // (see root.ts's sequential `await refreshDiff(...)` -> `await comments.loadInitial()` tail), so
    // a persisted entry can't be observed via `collectStateForFlush` this early — only the
    // provisional case is the direct analog of the editor test's synchronous dirty-restore above.
    const pendingEntry: PendingReviewCommentEntry = {
      id: "pending-1",
      provisional: true,
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 12,
      lineText: "  const y = 2;",
      body: "unsaved comment text",
    };
    INIT_PAYLOAD = { ...defaultInitPayload, workspaceState: { ...defaultInitPayload.workspaceState, pendingReviewComments: [pendingEntry] } };

    const mounted = mountRoot(container);
    // Same checkpoint as the editor test above: `refreshDiff`'s own `workspaceDiff` call is this
    // init's first network await, parked here to stand in for a teardown mid-init.
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));

    // Before Fix 1a, `comments.restorePendingState` ran after this await (or after `loadInitial`'s
    // own await), so this flush would return `null` here — silently discarding the seeded comment
    // text. Fix 1a moves the restore above every network await in the init tail (see root.ts), so
    // the draft is already live in the controller's mirror by the time this synchronous teardown
    // pull can fire.
    const collected = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}");
    const parsedEntries = collected.pendingReviewComments as PendingReviewCommentEntry[];
    expect(parsedEntries).toHaveLength(1);
    // The id itself is not preserved: `restorePendingState` mints a fresh provisional id for the
    // recreated draft (`provisionalSequence` restarts at 0 every page load — see its doc comment)
    // rather than reusing the pre-teardown one, so only the rest of the anchor plus the live body
    // are checked against what was seeded.
    expect(parsedEntries[0]).toMatchObject({
      provisional: true,
      filePath: pendingEntry.filePath,
      side: pendingEntry.side,
      lineNumber: pendingEntry.lineNumber,
      lineText: pendingEntry.lineText,
      body: pendingEntry.body,
    });

    resolveDiff(0, [], "sig-a");
    await mounted;
  });
});

describe("mountRoot's file-list-signature push — sidebar refresh gated to Editor mode", () => {
  let container: HTMLElement;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.diffSignatureCallbacks.length = 0;
    hoisted.fileListSignatureCallbacks.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.notifyModeChanged.mockClear();
    hoisted.workspaceFileList.mockClear();
    hoisted.workspaceFileList.mockResolvedValue({ paths: ["a.ts"], truncated: false });
    container = document.createElement("div");
  });

  it("a push while in Diff mode invalidates the cache without fetching; switching to Editor mode afterward fetches fresh", async () => {
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [], "sig-a");
    await mounted;
    // EditorSidebar's constructor never fires a listing fetch on its own (Finding 1): a pane
    // mounted (and, here, still sitting) in Diff mode must not pay for a hidden `workspaceFileList`
    // RPC merely for the sidebar existing, unattached, off-screen.
    expect(hoisted.workspaceFileList).not.toHaveBeenCalled();

    // The pane is still in its default initial mode (Diff) here.
    fireFileListSignature();

    // Give a (wrongly) triggered fetch a couple of microtask turns to happen before asserting it
    // didn't — the bug this closes was an unconditional `editorSidebar.refreshFilesListing()` call
    // on every file-list push, firing a full `workspaceFileList` RPC even while the sidebar isn't in the DOM.
    await Promise.resolve();
    await Promise.resolve();
    expect(hoisted.workspaceFileList).not.toHaveBeenCalled();
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1);

    clickButton(container, "Editor");
    // The cache was invalidated by the push above, so returning to Editor mode re-fetches instead of
    // reusing a stale (possibly now-wrong) cached listing.
    await vi.waitFor(() => expect(hoisted.workspaceFileList).toHaveBeenCalledTimes(1));
  });
});

describe("mountRoot's file-list-signature push — ⌘P overlay refresh is not mode-gated", () => {
  let container: HTMLElement;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.diffSignatureCallbacks.length = 0;
    hoisted.fileListSignatureCallbacks.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.workspaceFileList.mockClear();
    hoisted.workspaceFileList.mockResolvedValue({ paths: ["a.ts"], truncated: false });
    container = document.createElement("div");
  });

  it("a push while the overlay is open still refetches the listing even though the pane is in Diff mode", async () => {
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [], "sig-a");
    await mounted;

    // Opening ⌘P (pane stays in its default initial mode, Diff) starts the overlay's own listing
    // fetch via QuickOpen.show()'s getFresh() call through the shared cache. QuickOpen's ⌘P listener
    // is global (window-level, by design — see its own doc comment), so earlier tests' still-mounted
    // overlays react to this same keydown too; wait on this test's own container instead of an
    // absolute `workspaceFileList` call count, which cross-test leakage would make unreliable.
    window.dispatchEvent(new KeyboardEvent("keydown", { key: "p", metaKey: true }));
    // Typing narrows to a fuzzy-match result (an empty query shows "recents", which is empty here —
    // nothing has been opened yet) — the same technique Finding E's test above uses to get a row.
    const input = container.querySelector(".quick-open input") as HTMLInputElement;
    input.value = "a.ts";
    input.dispatchEvent(new Event("input"));
    await vi.waitFor(() => expect(container.querySelector('.quick-open .row[data-path="a.ts"]')).not.toBeNull());

    // `fireFileListSignature` (unlike the keydown above) only invokes THIS mount's own subscription —
    // `hoisted.fileListSignatureCallbacks` was reset in `beforeEach` — so exactly one more call here is
    // attributable to this pane alone. The sidebar's own refresh is gated to Editor mode (previous
    // describe block) and must not fire; but the ⌘P overlay works in both modes, so
    // `quickOpen.refreshListing()` must still fire, ungated, with the pane still in Diff mode.
    hoisted.workspaceFileList.mockClear();
    fireFileListSignature();
    await vi.waitFor(() => expect(hoisted.workspaceFileList).toHaveBeenCalledTimes(1));
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1);
  });
});

describe("mountRoot's editor-mode-only startup triggers the sidebar's first fetch (Finding 1)", () => {
  let container: HTMLElement;
  const defaultInitPayload = INIT_PAYLOAD;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.workspaceFileList.mockClear();
    hoisted.workspaceFileList.mockResolvedValue({ paths: ["a.ts"], truncated: false });
    container = document.createElement("div");
  });

  afterEach(() => {
    INIT_PAYLOAD = defaultInitPayload;
  });

  it("a pane starting (or rehydrating) directly into editor mode fetches the Files tab's listing without ever going through a dispatch", async () => {
    INIT_PAYLOAD = { ...defaultInitPayload, workspaceState: { ...defaultInitPayload.workspaceState, mode: "editor" } };

    const mounted = mountRoot(container);
    await mounted;

    // This path never touches dispatch's "setMode" branch (renderBody() mounted the sidebar
    // straight from the initial `state.mode`, with no action ever dispatched) — root.ts's own
    // explicit `editorSidebar.reattach()` call right after the initial render is what has to
    // trigger this fetch, since EditorSidebar's constructor no longer starts one on its own.
    await vi.waitFor(() => expect(hoisted.workspaceFileList).toHaveBeenCalledTimes(1));
    await vi.waitFor(() => expect(container.querySelector('.row[data-path="a.ts"]')).not.toBeNull());
  });
});

describe("mountRoot's init ordering — rehydrating into editor mode reads the restored buffer before the sidebar's Files listing (review fix)", () => {
  let container: HTMLElement;
  const defaultInitPayload = INIT_PAYLOAD;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.notifyModeChanged.mockClear();
    hoisted.workspaceFileList.mockClear();
    hoisted.workspaceFileRead.mockClear();
    hoisted.workspaceFileList.mockResolvedValue({ paths: ["a.ts"], truncated: false });
    hoisted.workspaceFileRead.mockResolvedValue({ content: "let x = 0;\n", sha256: "deadbeef", size: 11 });
    container = document.createElement("div");
  });

  afterEach(() => {
    INIT_PAYLOAD = defaultInitPayload;
  });

  it("issues the restored file's workspaceFileRead before the reattach-triggered workspaceFileList scan", async () => {
    const cleanEditorState: CodePaneEditorState = {
      path: "/repo/src/foo.ts",
      baseSHA256: "deadbeef",
      baseContent: "let x = 0;\n",
      content: "let x = 0;\n",
      dirty: false,
      conflict: false,
    };
    // No `editorUIState` in the payload — absent defaults to the Files tab (see
    // `CodePaneInitPayload.editorUIState`'s doc comment), the tab whose `reattach()` fires the
    // listing scan this ordering is about.
    INIT_PAYLOAD = {
      ...defaultInitPayload,
      workspaceState: { ...defaultInitPayload.workspaceState, mode: "editor", editorState: cleanEditorState },
    };

    const mounted = mountRoot(container);
    await mounted;

    // `restoreState`'s clean-restoration branch (state.dirty === false) fires `handleExternalChange`,
    // whose own `workspaceFileRead` call is that method's first statement — invoked synchronously,
    // before root.ts's own `await editorView.restoreState(...)` line even returns. The relocated
    // `editorSidebar.reattach()` call now runs after that await, so its `workspaceFileList` scan is
    // queued on the daemon's serial per-workspace git queue strictly after the restored file's read,
    // not ahead of it (the bug this fix closes). `invocationCallOrder` is what proves the ordering,
    // the same technique the Diff-mode ⌘P out-of-diff-jump test above uses for `openInEditor`.
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith(cleanEditorState.path, "editor"));
    await vi.waitFor(() => expect(hoisted.workspaceFileList).toHaveBeenCalledTimes(1));
    const readOrder = hoisted.workspaceFileRead.mock.invocationCallOrder[0]!;
    const listOrder = hoisted.workspaceFileList.mock.invocationCallOrder[0]!;
    expect(readOrder).toBeLessThan(listOrder);
  });
});

describe("mountRoot's Diff→Editor round trip re-attaches the sidebar's current list (Finding B)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.notifyModeChanged.mockClear();
    container = document.createElement("div");
  });

  it("the Changes tab survives a round trip through Diff mode instead of coming back blank", async () => {
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [makeFile("a.ts")], "sig-a");
    await mounted;
    await vi.waitFor(() => expect(container.textContent).toContain("a.ts"));

    clickButton(container, "Editor");
    clickButton(container, "Changes");
    await vi.waitFor(() => expect(container.querySelector(".editor-sidebar-list")!.textContent).toContain("a.ts"));

    // Diff mode's own renderBody reparents `changesListEl` out of the sidebar's list host — without
    // Finding B's fix, coming back to Editor mode on the Changes tab would show a blank list until
    // the user manually toggled tabs, since the sidebar never re-renders on that reparent.
    clickButton(container, "Diff");
    clickButton(container, "Editor");

    expect(container.querySelector(".editor-sidebar-list")!.textContent).toContain("a.ts");
  });
});

describe("mountRoot's Diff-mode ⌘P jump records into recents (Finding E)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.notifyModeChanged.mockClear();
    hoisted.notifyEditorUIStateChanged.mockClear();
    hoisted.workspaceFileList.mockClear();
    hoisted.workspaceFileList.mockResolvedValue({ paths: ["a.ts"], truncated: false });
    container = document.createElement("div");
  });

  it("jumping to an in-diff file via the ⌘P overlay records it, unlike a plain scrollToFile call which has no seam of its own", async () => {
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [makeFile("a.ts")], "sig-a");
    await mounted;
    await vi.waitFor(() => expect(container.textContent).toContain("a.ts"));

    // The pane is in its default initial mode (Diff); "a.ts" is already part of the current diff, so
    // this jump stays in Diff mode instead of switching to Editor (see QuickOpen's own doc comment).
    window.dispatchEvent(new KeyboardEvent("keydown", { key: "p", metaKey: true }));
    const input = container.querySelector(".quick-open input") as HTMLInputElement;
    input.value = "a.ts";
    input.dispatchEvent(new Event("input"));

    const row = await vi.waitFor(() => {
      const el = container.querySelector('.quick-open .row[data-path="a.ts"]') as HTMLElement | null;
      expect(el).not.toBeNull();
      return el!;
    });
    row.click();

    await vi.waitFor(() =>
      expect(
        hoisted.notifyEditorUIStateChanged.mock.calls
          .map(([state]) => state as { sidebarMode: string; recentPaths: string[] })
          .some((state) => state.sidebarMode === "files" && state.recentPaths[0] === "a.ts"),
      ).toBe(true),
    );
  });
});

describe("mountRoot's Diff-mode ⌘P jump to an out-of-diff file opens it before the mode switch's sidebar revalidation (Fix 2)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.workspaceFileList.mockClear();
    hoisted.workspaceFileRead.mockClear();
    hoisted.workspaceFileList.mockResolvedValue({ paths: ["a.ts", "b.ts"], truncated: false });
    hoisted.workspaceFileRead.mockResolvedValueOnce({ content: "b content", sha256: "sha-b", size: 9 });
    container = document.createElement("div");
  });

  it("issues workspaceFileRead for the picked file before the workspaceFileList call the resulting editor-mode switch triggers", async () => {
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [makeFile("a.ts")], "sig-a");
    await mounted;
    await vi.waitFor(() => expect(container.textContent).toContain("a.ts"));

    // "b.ts" is outside the current diff, so — unlike Finding E's in-diff jump, which stays in Diff
    // mode — picking it goes through `openInEditor` and switches the pane to Editor mode. Opening
    // the overlay itself issues its own listing fetch via `QuickOpen.show()`; wait for that to
    // settle (the row only renders once it has) and clear both mocks so only the calls the click
    // below triggers are being measured.
    window.dispatchEvent(new KeyboardEvent("keydown", { key: "p", metaKey: true }));
    const input = container.querySelector(".quick-open input") as HTMLInputElement;
    input.value = "b.ts";
    input.dispatchEvent(new Event("input"));
    const row = await vi.waitFor(() => {
      const el = container.querySelector('.quick-open .row[data-path="b.ts"]') as HTMLElement | null;
      expect(el).not.toBeNull();
      return el!;
    });
    hoisted.workspaceFileList.mockClear();
    hoisted.workspaceFileRead.mockClear();

    row.click();

    // Both calls fire synchronously within the click: `editorView.open` issues its
    // `workspaceFileRead` call before returning (its `await` is inside `loadFile`, past this point),
    // and the `setMode` dispatch that follows it runs `editorSidebar.reattach()` synchronously too
    // (the sidebar defaults to the Files tab, so reattach always revalidates it). Their relative
    // `invocationCallOrder` is what proves the reorder — without it, the mode dispatch's listing
    // scan would be queued on the daemon's serial git queue ahead of the file the user just picked.
    expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("b.ts", "editor");
    expect(hoisted.workspaceFileList).toHaveBeenCalledTimes(1);
    const readOrder = hoisted.workspaceFileRead.mock.invocationCallOrder[0]!;
    const listOrder = hoisted.workspaceFileList.mock.invocationCallOrder[0]!;
    expect(readOrder).toBeLessThan(listOrder);
  });
});

describe("mountRoot's cross-mode Quick Open scope preservation", () => {
  let container: HTMLElement;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.workspaceFileList.mockClear();
    hoisted.workspaceFileRead.mockClear();
    hoisted.notifyWorkspaceStateChanged.mockClear();
    hoisted.workspaceFileList.mockResolvedValue({ paths: ["committed.ts", "untracked.ts"], truncated: false });
    hoisted.workspaceFileRead.mockResolvedValue({ content: "untracked content", sha256: "untracked-sha", size: 17 });
    container = document.createElement("div");
  });

  it("keeps Last Commit selected after Quick Open switches to Editor and the user returns to Diff", async () => {
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [makeFile("committed.ts")], "uncommitted-sig");
    await mounted;

    switchToLastCommit(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [makeFile("committed.ts")], "last-commit-sig");
    await vi.waitFor(() => expect(container.querySelector(".compare-btn")?.textContent).toBe("Last commit"));
    await vi.waitFor(() =>
      expect(hoisted.notifyRenderMetric).toHaveBeenCalledWith(
        expect.objectContaining({ kind: "diff", trigger: "manifest", scope: "lastCommit" }),
      ),
    );

    window.dispatchEvent(new KeyboardEvent("keydown", { key: "p", metaKey: true }));
    const input = container.querySelector(".quick-open input") as HTMLInputElement;
    input.value = "untracked.ts";
    input.dispatchEvent(new Event("input"));
    const row = await vi.waitFor(() => {
      const el = container.querySelector('.quick-open .row[data-path="untracked.ts"]') as HTMLElement | null;
      expect(el).not.toBeNull();
      return el!;
    });

    row.click();
    await vi.waitFor(() => expect(container.querySelector("#code-pane-mode-editor")?.classList.contains("on")).toBe(true));

    clickButton(container, "Diff");

    // Returning to Diff is only a mode change. In particular it must not turn the user's Last
    // Commit comparison into Uncommitted just because the file opened from Quick Open is absent
    // from that comparison.
    expect(container.querySelector(".compare-btn")?.textContent).toBe("Last commit");
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2);
    const snapshots = hoisted.notifyWorkspaceStateChanged.mock.calls.map(([state]) =>
      state as { mode: string; scope: { kind: string } },
    );
    expect(snapshots.at(-1)).toMatchObject({ mode: "diff", scope: { kind: "lastCommit" } });
  });
});

describe("mountRoot's Editor mode — Files/Changes sidebar and recent-files recording (Design K/O)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.notifyModeChanged.mockClear();
    hoisted.notifyEditorUIStateChanged.mockClear();
    hoisted.workspaceFileList.mockClear();
    hoisted.workspaceFileRead.mockReset();
    // A successful open is now the norm for this block (Finding C's recording only fires once
    // `workspaceFileRead` actually resolves) — individual tests override with a rejection or a
    // controllable pending promise where they need to exercise the refused/failed paths instead.
    hoisted.workspaceFileRead.mockImplementation((path: string) =>
      Promise.resolve({ content: `${path} content`, sha256: `sha-${path}`, size: 1 }),
    );
    capturedCodeViewOptions.current = undefined;
    container = document.createElement("div");
  });

  /** Mounts (in the default Diff mode, so `EditorSidebar`'s constructor fires no fetch of its own —
   *  see its doc comment), seeds the Files tab's listing with `paths`, settles the initial diff pull
   *  (empty — these tests don't care about diff content) so `mountRoot`'s own promise resolves, then
   *  switches to Editor mode and waits for the Files tree to actually render. Entering Editor mode is
   *  what triggers the sidebar's first-ever listing fetch here, via dispatch's `setMode` branch
   *  calling `editorSidebar.reattach()`. `mockResolvedValue` (not `-Once`) since a later reattach in
   *  the same test (e.g. a Diff→Editor round trip) would otherwise starve on an exhausted `-Once`
   *  queue — these tests want the same listing back every time, not to count individual calls. */
  async function mountWithFiles(paths: readonly string[]): Promise<void> {
    hoisted.workspaceFileList.mockResolvedValue({ paths, truncated: false });
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [], "sig-a");
    await mounted;
    clickButton(container, "Editor");
    await vi.waitFor(() => expect(container.querySelector(`.row[data-path="${paths[0]}"]`)).not.toBeNull());
  }

  function clickFileRow(path: string): void {
    const row = container.querySelector(`.row[data-path="${path}"]`);
    if (!row) throw new Error(`no Files-tree row for "${path}"`);
    (row as HTMLElement).click();
  }

  function lastPushedState(): { sidebarMode: string; recentPaths: string[] } {
    const snapshots = hoisted.notifyEditorUIStateChanged.mock.calls.map(
      ([snapshot]) => snapshot as { sidebarMode: string; recentPaths: string[] },
    );
    for (let index = snapshots.length - 1; index >= 0; index -= 1) {
      if (snapshots[index]!.recentPaths.length > 0) return snapshots[index]!;
    }
    return { sidebarMode: "files", recentPaths: [] };
  }

  /** Opens `path` via the Files tree and waits for the resulting recording push to land — recording
   *  now happens asynchronously, after `workspaceFileRead` resolves (Finding C), rather than
   *  synchronously on click. */
  async function openFileRowAndWait(path: string): Promise<void> {
    clickFileRow(path);
    await vi.waitFor(() =>
      expect(
        hoisted.notifyEditorUIStateChanged.mock.calls
          .map(([snapshot]) => snapshot as { recentPaths: string[] })
          .some((snapshot) => snapshot.recentPaths[0] === path),
      ).toBe(true),
    );
  }

  it("opening a file via the Files tree records it as the sole recent path and pushes the update", async () => {
    await mountWithFiles(["a.ts", "b.ts"]);

    await openFileRowAndWait("a.ts");

    expect(hoisted.notifyEditorUIStateChanged).toHaveBeenCalled();
    expect(lastPushedState()).toEqual({ sidebarMode: "files", recentPaths: ["a.ts"] });
  });

  it("opening a second, different file puts it first without dropping the one already recorded", async () => {
    await mountWithFiles(["a.ts", "b.ts"]);

    await openFileRowAndWait("a.ts");
    await openFileRowAndWait("b.ts");

    expect(lastPushedState()).toEqual({ sidebarMode: "files", recentPaths: ["b.ts", "a.ts"] });
  });

  it("re-opening an already-recent path moves it to the front instead of duplicating it", async () => {
    await mountWithFiles(["a.ts", "b.ts"]);

    await openFileRowAndWait("a.ts");
    await openFileRowAndWait("b.ts");
    await openFileRowAndWait("a.ts");

    expect(lastPushedState()).toEqual({ sidebarMode: "files", recentPaths: ["a.ts", "b.ts"] });
  });

  it("caps the recent-files list at 12, dropping the oldest", async () => {
    const paths = Array.from({ length: 13 }, (_, i) => `file${i}.ts`);
    await mountWithFiles(paths);

    for (const path of paths) await openFileRowAndWait(path);

    const { recentPaths } = lastPushedState();
    expect(recentPaths).toHaveLength(12);
    // Most-recently-opened first; file0.ts (opened first, so the 13th-oldest once file12.ts opens)
    // is the one that falls out of the cap.
    expect(recentPaths[0]).toBe("file12.ts");
    expect(recentPaths).not.toContain("file0.ts");
  });

  it("toggling Files/Changes pushes the updated sidebarMode, independent of the recent-files list", async () => {
    await mountWithFiles(["a.ts"]);
    hoisted.notifyEditorUIStateChanged.mockClear(); // drop mountWithFiles' own setup noise, if any

    clickButton(container, "Changes");
    expect(
      hoisted.notifyEditorUIStateChanged.mock.calls
        .map(([snapshot]) => snapshot as { sidebarMode: string; recentPaths: string[] })
        .some((snapshot) => snapshot.sidebarMode === "changes" && snapshot.recentPaths.length === 0),
    ).toBe(true);

    clickButton(container, "Files");
    expect(
      hoisted.notifyEditorUIStateChanged.mock.calls
        .map(([snapshot]) => snapshot as { sidebarMode: string; recentPaths: string[] })
        .some((snapshot) => snapshot.sidebarMode === "files" && snapshot.recentPaths.length === 0),
    ).toBe(true);
  });

  // Finding C: `openInEditor` no longer records unconditionally — only `EditorView`'s `onFileOpened`
  // success callback does, so a refused (dirty-buffer) or failed open must not pollute `recentPaths`
  // or move the Files tree's selection.
  describe("Finding C — recording only follows a successful open", () => {
    /** Opens `path`, then dirties its buffer via the fake CodeView's captured `onItemEditChange` —
     *  the same technique editorView.test.ts uses to simulate an edit without a real `@pierre/diffs`
     *  editor. `ensureCodeView` (and so this capture) only happens on the first successful open. */
    async function openAndDirty(path: string): Promise<void> {
      await openFileRowAndWait(path);
      capturedCodeViewOptions.current!.onItemEditChange(undefined, { contents: `${path} content edited` });
    }

    it("an open whose pending write fails records nothing and says why", async () => {
      await mountWithFiles(["a.ts", "b.ts"]);
      await openAndDirty("a.ts");
      hoisted.workspaceFileWrite.mockRejectedValueOnce(new SpacesBridgeError("unavailable", "daemon unavailable"));
      hoisted.notifyEditorUIStateChanged.mockClear();

      // Fake timers from here so the failure's retry backoff belongs to this test rather than
      // firing into a later one.
      useFakeTimersWithImmediatePaint();
      try {
        clickFileRow("b.ts");
        await vi.advanceTimersByTimeAsync(0);

        // Opening another file writes the dirty buffer first, so a write that fails refuses the
        // open and says why instead of recording a file that never opened.
        expect(container.querySelector(".banner.error")!.textContent).toContain("daemon unavailable");
        expect(
          hoisted.notifyEditorUIStateChanged.mock.calls
            .map(([snapshot]) => snapshot as { recentPaths: string[] })
            .some((snapshot) => snapshot.recentPaths[0] === "b.ts"),
        ).toBe(false);
      } finally {
        vi.useRealTimers();
      }
    });

    it("a failed read records nothing", async () => {
      await mountWithFiles(["a.ts", "b.ts"]);
      hoisted.notifyEditorUIStateChanged.mockClear();
      hoisted.workspaceFileRead.mockImplementationOnce(() => Promise.reject(new Error("read failed")));

      clickFileRow("a.ts");

      await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("a.ts", "editor"));
      // Give the rejected promise's microtask a turn to (not) call back before asserting.
      await Promise.resolve();
      await Promise.resolve();
      expect(hoisted.notifyEditorUIStateChanged).not.toHaveBeenCalled();
    });

    it("records the target only once the dirty buffer's write lands and the open succeeds", async () => {
      await mountWithFiles(["a.ts", "b.ts"]);
      await openAndDirty("a.ts");
      let resolveWrite: ((result: { ok: true; sha256: string }) => void) | undefined;
      hoisted.workspaceFileWrite.mockImplementationOnce(
        () => new Promise((resolve) => {
          resolveWrite = resolve;
        }),
      );
      hoisted.notifyEditorUIStateChanged.mockClear();

      clickFileRow("b.ts");
      await vi.waitFor(() => expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith("a.ts", "a.ts content edited", expect.anything()));
      expect(hoisted.notifyEditorUIStateChanged).not.toHaveBeenCalled(); // the open is still waiting on that write

      resolveWrite!({ ok: true, sha256: "sha-a-saved" });

      await vi.waitFor(() => expect(lastPushedState().recentPaths[0]).toBe("b.ts"));
      expect(lastPushedState()).toEqual({ sidebarMode: "files", recentPaths: ["b.ts", "a.ts"] });
    });
  });
});

describe("mountRoot's teardown of a root left mid-initialization", () => {
  let container: HTMLElement;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.notifyWorkspaceStateChanged.mockClear();
    hoisted.notifyEditsFlushed.mockClear();
    container = document.createElement("div");
    document.body.appendChild(container);
  });

  afterEach(() => {
    container.remove();
  });

  // These two cases are one assertion split across the teardown between them: the first leaves a
  // root parked on a manifest pull that never settles, and the second proves that root is gone.
  it("mounts a root whose first manifest pull never settles", async () => {
    mountRoot(container);

    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
  });

  it("retires that root, so its host listeners answer nothing in the next test", async () => {
    // A live root answers all three: it reloads the diff it never loaded, pushes the mode it just
    // changed, and replies to the host's quit handshake. A retired one has no listener left to hear
    // any of them.
    window.dispatchEvent(new CustomEvent("spaces:setMode", { detail: { mode: "editor" } }));
    window.dispatchEvent(new CustomEvent("spaces:setMode", { detail: { mode: "diff" } }));
    window.dispatchEvent(new CustomEvent("spaces:flushEdits", { detail: { token: "quit-after-teardown" } }));
    await Promise.resolve();
    await Promise.resolve();

    expect(hoisted.notifyEditsFlushed).not.toHaveBeenCalled();
    expect(hoisted.notifyWorkspaceStateChanged).not.toHaveBeenCalled();
    expect(hoisted.workspaceDiff).not.toHaveBeenCalled();
  });
});
