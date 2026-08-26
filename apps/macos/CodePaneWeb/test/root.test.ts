import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { DiffView } from "../src/app/diffView";
import { mountRoot } from "../src/app/root";
import {
  CodePaneEditorState,
  CodePaneInitPayload,
  DiffFileEntry,
  PendingReviewCommentEntry,
  SpacesBridgeError,
} from "../src/bridge/types";

// Captures the options the most recently constructed (fake) CodeView was built with — DiffView and
// EditorView share the same `CodeView` class, but only EditorView's instance ever exercises
// `onItemEditChange` (Finding C's tests dirty the editor buffer this way, the same technique
// editorView.test.ts's own `capturedCodeViewOptions` uses). EditorView constructs its CodeView
// lazily, on the first successful open (see `ensureCodeView`), which is always after DiffView's own
// construction at mount — so by the time a test needs it, `.current` is the editor's instance.
const capturedCodeViewOptions = vi.hoisted(() => ({
  current: undefined as undefined | { onItemEditChange: (item: unknown, file: { contents: string }) => void },
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
    scrollTo(): void {}
    cleanUp(): void {}
    // Models an attach that completed instantly so `completeEditorAttach`'s poll resolves
    // on its first frame (see the matching fake in editorView.test.ts).
    getEditor(): object {
      return {};
    }
    updateItem(): void {}
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

// Mutable (not `const`) so Fix 1's describe block below can substitute a payload carrying a dirty
// `editorState` for its one test, then restore the default afterward — the bridge mock's
// `notifyReady` reads this binding at call time, not at module-evaluation time, so reassigning it
// before `mountRoot` is called is enough; no `vi.hoisted` indirection needed.
let INIT_PAYLOAD: CodePaneInitPayload = {
  workspaceId: "w1",
  workspaceName: "Test workspace",
  initialMode: "diff",
  initialScope: { kind: "uncommitted" },
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
  const notifyRenderMetric = vi.fn();
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
    workspaceFileList,
    workspaceFileRead,
    workspaceRefList,
    notifyModeChanged,
    notifyEditorUIStateChanged,
    notifyRenderMetric,
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
    workspaceDiff: hoisted.workspaceDiff,
    workspaceFileRead: hoisted.workspaceFileRead,
    workspaceRefList: hoisted.workspaceRefList,
    workspaceFileWrite: vi.fn().mockRejectedValue(new Error("not used")),
    workspaceFileList: hoisted.workspaceFileList,
    subscribeDiffSignature: hoisted.subscribeDiffSignature,
    subscribeFileSignature: vi.fn(() => () => {}),
    notifyEditorStateChanged: vi.fn(),
    notifyEditorUIStateChanged: hoisted.notifyEditorUIStateChanged,
    notifyModeChanged: hoisted.notifyModeChanged,
    notifyRenderMetric: hoisted.notifyRenderMetric,
    reviewCommentList: vi.fn().mockResolvedValue([]),
    reviewCommentUpsert: vi.fn().mockRejectedValue(new Error("not used")),
    reviewCommentDelete: vi.fn().mockRejectedValue(new Error("not used")),
    reviewCommentsSend: vi.fn().mockRejectedValue(new Error("not used")),
  }),
}));

function makeFile(path: string): DiffFileEntry {
  // isBinary skips patch parsing entirely (buildItem short-circuits to a
  // placeholder item), which keeps these tests independent of the diff patch
  // format — they only care which scope's file list won.
  return { path, status: "modified", isBinary: true, truncated: false };
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

    expect(hoisted.notifyRenderMetric).not.toHaveBeenCalled();
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
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
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

  it("a scope change resets the backoff floor even without an intervening success (round-14 fix)", async () => {
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
    expect(finalCall[0]).toEqual([makeFile("scope-b-only.ts")]);
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
    vi.useFakeTimers();
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
    vi.useFakeTimers();
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
    vi.useFakeTimers();
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
    INIT_PAYLOAD = { ...defaultInitPayload, pendingReviewComments: [pendingEntry] };
    // Not mocked at the module level (only @pierre/diffs's CodeView is faked): spying on the real
    // CommentsController's own `DiffView.setComments` calls (round-16 Fix 1's same technique, see
    // its doc comment above) is the only place `comments.setFiles([])`'s effect is externally
    // observable — `CommentsController.files` itself is a private field with no getter, and
    // `reanchorComments` only clears a draft's `position` (not its body/tray visibility) when its
    // `filePath` is missing from the file list it was last given.
    setCommentsSpy = vi.spyOn(DiffView.prototype, "setComments");
    vi.useFakeTimers();
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
    expect(container.textContent).not.toContain("Loading diff…");
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
      const label = container.querySelector(".agent-label");
      expect(label?.textContent).toBe("claude · main");
    });
    sendBatchBtn = [...container.querySelectorAll("button")].find((b) =>
      b.textContent?.startsWith("Send batch"),
    ) as HTMLButtonElement;
    // Still disabled: an agent is now selected, but there are zero drafts to send.
    expect(sendBatchBtn.title).toBe("No comments to send.");
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

    expect(hoisted.notifyModeChanged).not.toHaveBeenCalled(); // startup alone pushes nothing

    clickButton(container, "Editor");
    expect(hoisted.notifyModeChanged).toHaveBeenCalledExactlyOnceWith("editor");

    clickButton(container, "Diff");
    expect(hoisted.notifyModeChanged).toHaveBeenNthCalledWith(2, "diff");
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

    const modeCallsBefore = hoisted.notifyModeChanged.mock.calls.length;
    const diffCallsBefore = hoisted.workspaceDiff.mock.calls.length;

    window.dispatchEvent(new CustomEvent("spaces:setMode", { detail: { mode: "diff" } }));

    expect(hoisted.notifyModeChanged.mock.calls.length).toBe(modeCallsBefore);
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
    INIT_PAYLOAD = { ...defaultInitPayload, editorState: dirtyEditorState };

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
    const collected = window.__spacesCollectEditorState?.();
    expect(JSON.parse(collected!)).toEqual(dirtyEditorState);
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
    INIT_PAYLOAD = { ...defaultInitPayload, editorState: dirtyEditorState };

    const mounted = mountRoot(container);
    // `refreshDiff`'s own `workspaceDiff` call is this init's first network await (mode is "diff"
    // by default) — it parks here per this file's controllable-bridge mechanism, standing in for
    // the Swift host tearing this pane down before init has fully settled.
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));

    // Before Fix 1, `editorView.restoreState` ran after this await, so `EditorView` would still be
    // empty here and this flush would return `null` — silently overwriting the host's hibernated
    // snapshot with nothing. Fix 1 moves the restore above every network await in the init tail, so
    // the buffer is already live by the time this synchronous teardown pull can fire.
    const collected = window.__spacesCollectEditorState?.();
    expect(collected).not.toBeNull();
    expect(JSON.parse(collected!)).toEqual(dirtyEditorState);

    resolveDiff(0, [], "sig-a");
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
    INIT_PAYLOAD = { ...defaultInitPayload, pendingReviewComments: [pendingEntry] };

    const mounted = mountRoot(container);
    // Same checkpoint as the editor test above: `refreshDiff`'s own `workspaceDiff` call is this
    // init's first network await, parked here to stand in for a teardown mid-init.
    await vi.waitFor(() => expect(hoisted.workspaceDiff).toHaveBeenCalledTimes(1));

    // Before Fix 1a, `comments.restorePendingState` ran after this await (or after `loadInitial`'s
    // own await), so this flush would return `null` here — silently discarding the seeded comment
    // text. Fix 1a moves the restore above every network await in the init tail (see root.ts), so
    // the draft is already live in the controller's mirror by the time this synchronous teardown
    // pull can fire.
    const collected = window.__spacesCollectReviewCommentState?.();
    expect(collected).not.toBeNull();
    const parsedEntries = JSON.parse(collected!) as PendingReviewCommentEntry[];
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
    INIT_PAYLOAD = { ...defaultInitPayload, initialMode: "editor" };

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
    INIT_PAYLOAD = { ...defaultInitPayload, initialMode: "editor", editorState: cleanEditorState };

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

    await vi.waitFor(() => expect(hoisted.notifyEditorUIStateChanged).toHaveBeenCalled());
    const calls = hoisted.notifyEditorUIStateChanged.mock.calls;
    expect(calls[calls.length - 1]![0]).toEqual({ sidebarMode: "files", recentPaths: ["a.ts"] });
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
    const calls = hoisted.notifyEditorUIStateChanged.mock.calls;
    return calls[calls.length - 1]![0] as { sidebarMode: string; recentPaths: string[] };
  }

  /** Opens `path` via the Files tree and waits for the resulting recording push to land — recording
   *  now happens asynchronously, after `workspaceFileRead` resolves (Finding C), rather than
   *  synchronously on click. */
  async function openFileRowAndWait(path: string): Promise<void> {
    clickFileRow(path);
    await vi.waitFor(() => expect(lastPushedState().recentPaths[0]).toBe(path));
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
    expect(lastPushedState()).toEqual({ sidebarMode: "changes", recentPaths: [] });

    clickButton(container, "Files");
    expect(lastPushedState()).toEqual({ sidebarMode: "files", recentPaths: [] });
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
