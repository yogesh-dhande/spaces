import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { DiffView } from "../src/app/diffView";
import { mountRoot } from "../src/app/root";
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
        onLineClick?: (range: { start: number; side?: string }, context: { type: string; item: { id: string } }) => void;
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
afterEach(() => {
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
  const workspaceDiffFileChunk = vi.fn((_scope: unknown, request: { manifestID: string; relativePath: string }) => {
    const manifest = manifests.get(request.manifestID);
    const file = manifest?.files.find((entry) => entry.path === request.relativePath);
    if (file && manifest) return Promise.resolve({ scopeSignature: manifest.scopeSignature, file });
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
    workspaceRefList,
    workspaceFileWrite,
    startWorkspaceCommand,
    resumeWorkspaceCommandTracking,
    notifyModeChanged,
    notifyEditorUIStateChanged,
    notifyWorkspaceStateChanged,
    notifyRenderMetric,
    reviewCommentList,
    diffSignatureCallbacks,
    subscribeDiffSignature,
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
    workspaceRefList: hoisted.workspaceRefList,
    workspaceFileWrite: hoisted.workspaceFileWrite,
    workspaceFileList: hoisted.workspaceFileList,
    subscribeDiffSignature: hoisted.subscribeDiffSignature,
    subscribeFileSignature: vi.fn(() => () => {}),
    notifyWorkspaceStateChanged: hoisted.notifyWorkspaceStateChanged,
    notifyRenderMetric: hoisted.notifyRenderMetric,
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

/** Simulates a diff-signature push event on whichever scope is currently subscribed (see
 *  `hoisted.diffSignatureCallbacks`'s doc comment). */
function fireDiffSignature(): void {
  const callbacks = hoisted.diffSignatureCallbacks;
  if (callbacks.length === 0) throw new Error("no diff-signature subscription registered yet");
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

    expect(scrollToFile.mock.calls.filter(([path]) => path === "50.ts")).toHaveLength(3);
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
    expect(scrollToFile.mock.calls.filter(([path]) => path === "50.ts")).toHaveLength(3);
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
    expect(capturedCodeViewOptions.selectedLineCalls).toContainEqual({
      id: "restored.ts",
      range: { start: 8, end: 8, side: "deletions", endSide: "deletions" },
    });
  });

  it("keeps the queued restored position in a teardown snapshot until a concrete visible line supersedes it", async () => {
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

    // Once a concrete rendered line is visible it is authoritative, independent of sidebar
    // selection or focus. This is the value a later state collection must carry forward.
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
      diffSelectedPath: "concrete.ts",
      diffScrollLine: 3,
      diffScrollSide: "new",
    });

    resolveChunk!({ scopeSignature: "restore-snapshot-sig", file: delayedFile });
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
      { start: 12, side: "deletions" },
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
    expect(capturedCodeViewOptions.selectedLineCalls).toContainEqual({
      id: file.path,
      range: { start: 12, end: 12, side: "deletions", endSide: "deletions" },
    });
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
    patch: "diff --git a/editable.ts b/editable.ts\n--- a/editable.ts\n+++ b/editable.ts\n@@ -1 +1 @@\n-before\n+after\n",
  };

  async function mountEditableDiff(): Promise<void> {
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [editableFile], "editable-sig");
    await mounted;
  }

  function startEdit(path = editableFile.path): void {
    capturedCodeViewOptions.current!.onLineClick!(
      { start: 1, side: "additions" },
      { type: "diff", item: { id: path } },
    );
  }

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.workspaceDiff.mockClear();
    hoisted.workspaceDiffFileChunk.mockClear();
    hoisted.workspaceFileRead.mockReset();
    hoisted.workspaceFileWrite.mockReset();
    hoisted.notifyWorkspaceStateChanged.mockClear();
    capturedCodeViewOptions.current = undefined;
    INIT_PAYLOAD = defaultInitPayload;
    container = document.createElement("div");
  });

  afterEach(() => {
    INIT_PAYLOAD = defaultInitPayload;
    hoisted.workspaceFileRead.mockReset().mockRejectedValue(new Error("not used"));
    hoisted.workspaceFileWrite.mockReset().mockRejectedValue(new Error("not used"));
    vi.useRealTimers();
    window.requestAnimationFrame = nativeRequestAnimationFrame;
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
    startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts"));
    await vi.waitFor(() => expect(capturedCodeViewOptions.current?.renderHeaderMetadata).toBeDefined());

    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "file" }, { contents: "saved text\n" });
    const header = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })!;
    header.querySelector<HTMLButtonElement>("#code-pane-diff-edit-save")!.click();
    await vi.waitFor(() => expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith("editable.ts", "saved text\n", { baseSHA256: "sha-before" }));

    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "file" }, { contents: "typed after save\n" });
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

  it("keeps reconciled content when an older in-flight save resolves afterward", async () => {
    hoisted.workspaceFileRead
      .mockResolvedValueOnce({ content: "line 1\nline 2\nline 3\nline 4\n", sha256: "sha-before", size: 28 })
      .mockResolvedValueOnce({ content: "line 1\nline 2\nline 3\nline 4 from disk\n", sha256: "sha-disk", size: 38 });
    let resolveWrite: ((result: { ok: true; sha256: string }) => void) | undefined;
    hoisted.workspaceFileWrite.mockImplementationOnce(
      () => new Promise((resolve) => {
        resolveWrite = resolve;
      }),
    );
    await mountEditableDiff();
    startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts"));

    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "file" }, { contents: "line 1 from mine\nline 2\nline 3\nline 4\n" });
    const header = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })!;
    header.querySelector<HTMLButtonElement>("#code-pane-diff-edit-save")!.click();
    await vi.waitFor(() => expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith(
      "editable.ts",
      "line 1 from mine\nline 2\nline 3\nline 4\n",
      { baseSHA256: "sha-before" },
    ));

    // The external refresh reconciles a non-overlapping disk edit while the old CAS write is
    // unresolved. Its generation bump must make the eventual old success retain this merge.
    hoisted.diffSignatureCallbacks.at(-1)!();
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [editableFile], "reconcile-in-flight-save");
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledTimes(2));
    await vi.waitFor(() => expect(capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })?.textContent).toContain("Unsaved changes"));

    resolveWrite!({ ok: true, sha256: "sha-saved" });
    await vi.waitFor(() => {
      const snapshot = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}");
      expect(snapshot.diffEditorState).toMatchObject({
        path: "editable.ts",
        content: "line 1 from mine\nline 2\nline 3\nline 4 from disk\n",
        baseSHA256: "sha-disk",
        baseContent: "line 1\nline 2\nline 3\nline 4 from disk\n",
        dirty: true,
        conflict: false,
      });
    });
  });

  it("keeps dirty A when discarding it to open B fails", async () => {
    const second: DiffFileEntry = { ...editableFile, path: "second.ts" };
    hoisted.workspaceFileRead
      .mockResolvedValueOnce({ content: "first disk\n", sha256: "sha-first", size: 11 })
      .mockRejectedValueOnce(new SpacesBridgeError("unavailable", "daemon unavailable"));
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [editableFile, second], "discard-failure-sig");
    await mounted;

    startEdit("editable.ts");
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts"));
    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "file" }, { contents: "first edited\n" });

    startEdit("second.ts");
    const pendingHeader = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })!;
    [...pendingHeader.querySelectorAll<HTMLButtonElement>("button")].find((button) => button.textContent === "Discard edits and open")!.click();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("second.ts"));

    await vi.waitFor(() => expect(container.textContent).toContain("Couldn't open second.ts for editing. Try again."));
    expect(JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}").diffEditorState).toMatchObject({
      path: "editable.ts",
      content: "first edited\n",
      dirty: true,
    });
  });

  it("ignores a delayed A save after discard-and-open replaces it with B", async () => {
    const second: DiffFileEntry = { ...editableFile, path: "second.ts" };
    hoisted.workspaceFileRead
      .mockResolvedValueOnce({ content: "first disk\n", sha256: "sha-first", size: 11 })
      .mockResolvedValueOnce({ content: "second disk\n", sha256: "sha-second", size: 12 });
    let resolveFirstWrite: ((result: { ok: true; sha256: string }) => void) | undefined;
    hoisted.workspaceFileWrite
      .mockImplementationOnce(
        () => new Promise((resolve) => {
          resolveFirstWrite = resolve;
        }),
      )
      .mockResolvedValueOnce({ ok: true, sha256: "sha-second-saved" });

    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [editableFile, second], "two-file-save-sig");
    await mounted;

    startEdit("editable.ts");
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts"));
    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "file" }, { contents: "first edited\n" });
    const firstHeader = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })!;
    firstHeader.querySelector<HTMLButtonElement>("#code-pane-diff-edit-save")!.click();
    await vi.waitFor(() => expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith("editable.ts", "first edited\n", { baseSHA256: "sha-first" }));

    // The explicit discard flow makes B the active editor while A's write is still unresolved.
    startEdit("second.ts");
    const pendingFirstHeader = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })!;
    const discard = [...pendingFirstHeader.querySelectorAll<HTMLButtonElement>("button")].find((button) =>
      button.textContent?.includes("Discard edits and open"),
    );
    discard!.click();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("second.ts"));
    capturedCodeViewOptions.current!.onItemEditChange({ id: "second.ts", type: "file" }, { contents: "second edited\n" });

    resolveFirstWrite!({ ok: true, sha256: "sha-first-saved" });
    await vi.waitFor(() =>
      expect(
        (hoisted.notifyWorkspaceStateChanged.mock.calls.at(-1)?.[0] as { diffEditorState: { path?: string } | null }).diffEditorState?.path,
      ).toBe("second.ts"),
    );

    const secondHeader = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "second.ts" })!;
    secondHeader.querySelector<HTMLButtonElement>("#code-pane-diff-edit-save")!.click();
    await vi.waitFor(() =>
      expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith("second.ts", "second edited\n", { baseSHA256: "sha-second" }),
    );
  });

  it("ends a clean A editor before opening B", async () => {
    const second: DiffFileEntry = { ...editableFile, path: "second.ts" };
    hoisted.workspaceFileRead.mockImplementation((path: string) =>
      Promise.resolve({ content: `${path} disk\n`, sha256: `sha-${path}`, size: path.length + 6 }),
    );
    const endEditSpy = vi.spyOn(DiffView.prototype, "endEdit");
    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [editableFile, second], "two-editable-sig");
    await mounted;
    startEdit("editable.ts");
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts"));

    startEdit("second.ts");

    expect(endEditSpy).toHaveBeenCalledWith("editable.ts");
    endEditSpy.mockRestore();
  });

  it("adopts an external change into a clean inline edit without making it dirty", async () => {
    hoisted.workspaceFileRead
      .mockResolvedValueOnce({ content: "disk before\n", sha256: "sha-before", size: 12 })
      .mockResolvedValueOnce({ content: "disk changed\n", sha256: "sha-changed", size: 13 });
    await mountEditableDiff();
    startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts"));
    const replaceSpy = vi.spyOn(DiffView.prototype, "replaceEditContent");

    hoisted.diffSignatureCallbacks.at(-1)!();
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [editableFile], "editable-changed-sig");

    await vi.waitFor(() => expect(replaceSpy).toHaveBeenCalledWith("editable.ts", "disk changed\n", false));
    const header = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })!;
    expect(header.querySelector<HTMLButtonElement>("#code-pane-diff-edit-save")?.disabled).toBe(true);
    replaceSpy.mockRestore();
  });

  it("reconciles a restored clean diff editor even when its path is absent from the manifest", async () => {
    INIT_PAYLOAD = {
      ...INIT_PAYLOAD,
      workspaceState: {
        ...INIT_PAYLOAD.workspaceState,
        diffEditorState: {
          path: "editable.ts",
          baseSHA256: "sha-before",
          baseContent: "disk before\n",
          content: "disk before\n",
          dirty: false,
          conflict: false,
          conflictBaseSHA256: null,
        } satisfies CodePaneDiffEditorState,
      },
    };
    hoisted.workspaceFileRead.mockResolvedValueOnce({ content: "disk reset\n", sha256: "sha-reset", size: 11 });
    const replaceSpy = vi.spyOn(DiffView.prototype, "replaceEditContent");

    const mounted = mountRoot(container);
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));
    resolveDiff(0, [], "clean-restored-omitted-sig");
    await mounted;

    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts"));
    expect(replaceSpy).toHaveBeenCalledWith("editable.ts", "disk reset\n", false);
    const collected = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}");
    expect(collected.diffEditorState).toMatchObject({
      path: "editable.ts",
      content: "disk reset\n",
      baseSHA256: "sha-reset",
      dirty: false,
      conflict: false,
    });
    replaceSpy.mockRestore();
  });

  it("keeps a dirty inline edit reachable when a live manifest omits that path", async () => {
    hoisted.workspaceFileRead.mockResolvedValue({ content: "disk before\n", sha256: "sha-before", size: 12 });
    await mountEditableDiff();
    startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts"));
    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "file" }, { contents: "unsaved recovery\n" });

    hoisted.diffSignatureCallbacks.at(-1)!();
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [], "omitted-edit-sig");

    await vi.waitFor(() =>
      expect(capturedCodeViewOptions.current?.renderHeaderMetadata?.({ name: "editable.ts" })?.textContent).toContain("Unsaved changes"),
    );
    const header = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })!;
    expect(header.querySelector("#code-pane-diff-edit-save")).not.toBeNull();
    expect(header.querySelector("#code-pane-diff-edit-cancel")).not.toBeNull();
  });

  it("surfaces a manifest transport failure above a dirty editor and retries without hiding Save/Cancel", async () => {
    hoisted.workspaceFileRead.mockResolvedValue({ content: "disk before\n", sha256: "sha-before", size: 12 });
    await mountEditableDiff();
    startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts"));
    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "file" }, { contents: "unsaved recovery\n" });

    useFakeTimersWithImmediatePaint();
    fireDiffSignature();
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2);
    rejectDiff(1, new Error("manifest transport dropped"));
    await vi.advanceTimersByTimeAsync(0);

    expect(container.querySelector("#code-pane-diff-edit-error")?.textContent).toBe("Couldn't load diff. Try again.");
    const header = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })!;
    expect(header.textContent).toContain("Unsaved changes");
    expect(header.querySelector("#code-pane-diff-edit-save")).not.toBeNull();
    expect(header.querySelector("#code-pane-diff-edit-cancel")).not.toBeNull();

    await vi.advanceTimersByTimeAsync(999);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(1);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(3);
    resolveDiff(2, [editableFile], "manifest-retry-sig");
    await vi.advanceTimersByTimeAsync(0);
  });

  it("surfaces a patch-stream failure above a dirty editor and retries without hiding Save/Cancel", async () => {
    hoisted.workspaceFileRead.mockResolvedValue({ content: "disk before\n", sha256: "sha-before", size: 12 });
    await mountEditableDiff();
    startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts"));
    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "file" }, { contents: "unsaved recovery\n" });

    useFakeTimersWithImmediatePaint();
    hoisted.workspaceDiffFileChunk.mockRejectedValueOnce(new Error("patch transport dropped"));
    fireDiffSignature();
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2);
    resolveDiff(1, [editableFile], "patch-retry-sig");
    await vi.advanceTimersByTimeAsync(0);
    expect(hoisted.workspaceDiffFileChunk).toHaveBeenCalledTimes(2);

    expect(container.querySelector("#code-pane-diff-edit-error")?.textContent).toBe("Couldn't load diff. Try again.");
    const header = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })!;
    expect(header.textContent).toContain("Unsaved changes");
    expect(header.querySelector("#code-pane-diff-edit-save")).not.toBeNull();
    expect(header.querySelector("#code-pane-diff-edit-cancel")).not.toBeNull();

    await vi.advanceTimersByTimeAsync(999);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2);
    await vi.advanceTimersByTimeAsync(1);
    expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(3);
    resolveDiff(2, [editableFile], "patch-retry-success-sig");
    await vi.advanceTimersByTimeAsync(0);
  });

  it("freezes an overlapping external write as a disk-versus-buffer comparison and keeps mine CAS-bound to that disk snapshot", async () => {
    hoisted.workspaceFileRead
      .mockResolvedValueOnce({ content: "before\n", sha256: "sha-before", size: 7 })
      .mockResolvedValueOnce({ content: "disk version\n", sha256: "sha-disk", size: 13 });
    // Keep the explicit conflict decision in flight. This test verifies the requested CAS baseline
    // rather than a later refresh triggered by a successful write.
    hoisted.workspaceFileWrite.mockImplementationOnce(() => new Promise(() => {}));
    const setConflictSpy = vi.spyOn(DiffView.prototype, "setEditConflict");
    await mountEditableDiff();
    startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts"));
    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "file" }, { contents: "my version\n" });

    hoisted.diffSignatureCallbacks.at(-1)!();
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [editableFile], "conflict-sig");

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
              snapshot.diffEditorState.conflictBaseSHA256 === "sha-disk",
          ),
      ).toBe(true),
    );

    const header = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })!;
    const keepMine = [...header.querySelectorAll<HTMLButtonElement>("button")].find((button) => button.textContent === "Keep mine")!;
    keepMine.click();
    await vi.waitFor(() =>
      expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith("editable.ts", "my version\n", { baseSHA256: "sha-disk" }),
    );
    setConflictSpy.mockRestore();
  });

  it("uses create-if-missing CAS when Keep mine resolves a deleted-file conflict", async () => {
    hoisted.workspaceFileRead
      .mockResolvedValueOnce({ content: "before\n", sha256: "sha-before", size: 7 })
      .mockRejectedValueOnce(new SpacesBridgeError("notFound", "editable.ts was deleted"));
    hoisted.workspaceFileWrite.mockImplementationOnce(() => new Promise(() => {}));
    await mountEditableDiff();
    startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts"));
    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "file" }, { contents: "restore mine\n" });

    hoisted.diffSignatureCallbacks.at(-1)!();
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2));
    resolveDiff(1, [editableFile], "deleted-edit-sig");
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
      expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith("editable.ts", "restore mine\n", { baseSHA256: undefined }),
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
      expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith("editable.ts", "my recovered version\n", { baseSHA256: "sha-disk" }),
    );
  });

  it("keeps a changed conflict's disk CAS target after Keep mine fails so retry cannot overwrite a newer file", async () => {
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

    let header = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })!;
    [...header.querySelectorAll<HTMLButtonElement>("button")].find((button) => button.textContent === "Keep mine")!.click();
    await vi.waitFor(() =>
      expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith("editable.ts", "my recovered version\n", { baseSHA256: "sha-disk" }),
    );

    const afterFailure = JSON.parse(window.__spacesCollectWorkspaceState?.() ?? "{}") as {
      diffEditorState?: CodePaneDiffEditorState;
    };
    expect(afterFailure.diffEditorState).toMatchObject({
      conflict: true,
      conflictBaseSHA256: "sha-disk",
    });

    header = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })!;
    [...header.querySelectorAll<HTMLButtonElement>("button")].find((button) => button.textContent === "Keep mine")!.click();
    await vi.waitFor(() =>
      expect(hoisted.workspaceFileWrite).toHaveBeenLastCalledWith(
        "editable.ts",
        "my recovered version\n",
        { baseSHA256: "sha-disk" },
      ),
    );
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
      expect(hoisted.workspaceFileWrite).toHaveBeenCalledWith("editable.ts", "restore my recovered version\n", { baseSHA256: undefined }),
    );
  });

  it("surfaces a retryable inline-diff save failure without discarding the edit", async () => {
    hoisted.workspaceFileRead.mockResolvedValue({ content: "disk before\n", sha256: "sha-before", size: 12 });
    hoisted.workspaceFileWrite.mockRejectedValueOnce(new SpacesBridgeError("unavailable", "daemon unavailable"));
    await mountEditableDiff();
    startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts"));
    capturedCodeViewOptions.current!.onItemEditChange({ id: "editable.ts", type: "file" }, { contents: "edited\n" });
    const header = capturedCodeViewOptions.current!.renderHeaderMetadata!({ name: "editable.ts" })!;
    const save = header.querySelector<HTMLButtonElement>("#code-pane-diff-edit-save")!;
    save.click();
    await vi.waitFor(() => expect(hoisted.workspaceFileWrite).toHaveBeenCalledTimes(1));

    expect(container.textContent).toContain("Couldn't save editable.ts. Try again.");
    expect(save.disabled).toBe(false);

    hoisted.workspaceFileWrite.mockResolvedValueOnce({ ok: true, sha256: "sha-after-retry" });
    save.click();
    await vi.waitFor(() => expect(hoisted.workspaceFileWrite).toHaveBeenCalledTimes(2));
  });

  it("surfaces a non-deletion workspace read failure before opening an inline diff edit", async () => {
    hoisted.workspaceFileRead.mockRejectedValueOnce(new SpacesBridgeError("unavailable", "daemon unavailable"));
    await mountEditableDiff();
    startEdit();
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("editable.ts"));

    expect(container.textContent).toContain("Couldn't open editable.ts for editing. Try again.");
  });
});

describe("mountRoot's refreshDiff — coalesced diff-signature storm (round-16 Fix 1)", () => {
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
    // `workspaceDiff` call (5 held/pending calls total, not 2) — that's the bug this fix closes.
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

describe("mountRoot's refreshDiff — scope switch mid-pull keeps the supersede + latest-scope guarantees (round-16 Fix 1)", () => {
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
      expect((container.querySelector<HTMLInputElement>("#code-pane-start-agent-command"))!.value).toBe(command);
      const status = container.querySelector<HTMLElement>("#code-pane-start-agent-status")!;
      expect(status.textContent).toContain("No agent detected");
      expect(status.textContent).toContain(failure);
    } finally {
      INIT_PAYLOAD = defaultInitPayload;
    }
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
      { start: 10, side: "deletions" },
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

describe("mountRoot's diff-signature push — sidebar refresh gated to Editor mode (Finding A)", () => {
  let container: HTMLElement;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.diffSignatureCallbacks.length = 0;
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
    fireDiffSignature();
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(2)); // refreshDiff(true) still runs
    resolveDiff(1, [], "sig-b");

    // Give a (wrongly) triggered fetch a couple of microtask turns to happen before asserting it
    // didn't — the bug this closes was an unconditional `editorSidebar.refreshFilesListing()` call
    // on every push, firing a full `workspaceFileList` RPC even while the sidebar isn't in the DOM.
    await Promise.resolve();
    await Promise.resolve();
    expect(hoisted.workspaceFileList).not.toHaveBeenCalled();

    clickButton(container, "Editor");
    // The cache was invalidated by the push above, so returning to Editor mode re-fetches instead of
    // reusing a stale (possibly now-wrong) cached listing.
    await vi.waitFor(() => expect(hoisted.workspaceFileList).toHaveBeenCalledTimes(1));
  });
});

describe("mountRoot's diff-signature push — ⌘P overlay refresh is not mode-gated", () => {
  let container: HTMLElement;

  beforeEach(() => {
    hoisted.pendingDiffCalls.length = 0;
    hoisted.diffSignatureCallbacks.length = 0;
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

    // `fireDiffSignature` (unlike the keydown above) only invokes THIS mount's own subscription —
    // `hoisted.diffSignatureCallbacks` was reset in `beforeEach` — so exactly one more call here is
    // attributable to this pane alone. The sidebar's own refresh is gated to Editor mode (Finding A,
    // previous describe block) and must not fire; but the ⌘P overlay works in both modes, so
    // `quickOpen.refreshListing()` must still fire, ungated, with the pane still in Diff mode.
    hoisted.workspaceFileList.mockClear();
    fireDiffSignature();
    await vi.waitFor(() => expect(hoisted.workspaceFileList).toHaveBeenCalledTimes(1));
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
    await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith(cleanEditorState.path));
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
    expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("b.ts");
    expect(hoisted.workspaceFileList).toHaveBeenCalledTimes(1);
    const readOrder = hoisted.workspaceFileRead.mock.invocationCallOrder[0]!;
    const listOrder = hoisted.workspaceFileList.mock.invocationCallOrder[0]!;
    expect(readOrder).toBeLessThan(listOrder);
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

    it("a refused open (dirty buffer) records nothing and leaves the discard banner up", async () => {
      await mountWithFiles(["a.ts", "b.ts"]);
      await openAndDirty("a.ts");
      hoisted.notifyEditorUIStateChanged.mockClear();

      clickFileRow("b.ts");

      // The discard-consent banner appears instead of a silent open.
      await vi.waitFor(() => expect(container.querySelector(".banner.conflict")!.textContent).toContain("b.ts"));
      expect(hoisted.notifyEditorUIStateChanged).not.toHaveBeenCalled();
    });

    it("a failed read records nothing", async () => {
      await mountWithFiles(["a.ts", "b.ts"]);
      hoisted.notifyEditorUIStateChanged.mockClear();
      hoisted.workspaceFileRead.mockImplementationOnce(() => Promise.reject(new Error("read failed")));

      clickFileRow("a.ts");

      await vi.waitFor(() => expect(hoisted.workspaceFileRead).toHaveBeenCalledWith("a.ts"));
      // Give the rejected promise's microtask a turn to (not) call back before asserting.
      await Promise.resolve();
      await Promise.resolve();
      expect(hoisted.notifyEditorUIStateChanged).not.toHaveBeenCalled();
    });

    it("clicking 'Discard edits and open' records the target only once that open actually succeeds", async () => {
      await mountWithFiles(["a.ts", "b.ts"]);
      await openAndDirty("a.ts");
      hoisted.notifyEditorUIStateChanged.mockClear();

      clickFileRow("b.ts");
      const discardBtn = await vi.waitFor(() => {
        const btn = container.querySelector(".banner.conflict button") as HTMLButtonElement | null;
        expect(btn).not.toBeNull();
        return btn!;
      });
      expect(hoisted.notifyEditorUIStateChanged).not.toHaveBeenCalled(); // not yet — only the click below commits it

      discardBtn.click();

      await vi.waitFor(() => expect(lastPushedState().recentPaths[0]).toBe("b.ts"));
      expect(lastPushedState()).toEqual({ sidebarMode: "files", recentPaths: ["b.ts", "a.ts"] });
    });
  });
});
