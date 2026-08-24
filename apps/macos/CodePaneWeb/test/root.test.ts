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

// mountRoot pulls in DiffView and EditorView, both of which construct a real
// `@pierre/diffs` CodeView on non-empty content — replaced with a no-op fake
// here since these tests are about root.ts's own stale-response guard (Fix
// B), not the diff-rendering library. Every other export passes through.
vi.mock("@pierre/diffs", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@pierre/diffs")>();
  class FakeCodeView {
    setup(): void {}
    setItems(): void {}
    setOptions(): void {}
    getScrollTop(): number {
      return 0;
    }
    scrollTo(): void {}
    cleanUp(): void {}
  }
  return { ...actual, CodeView: FakeCodeView };
});
vi.mock("@pierre/diffs/edit", () => ({
  Editor: class {},
}));

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
  // These tests use the "vs base branch" button purely as a scope-switch trigger (Fix B is about
  // stale-response ordering, not about base branches) — it must be enabled for that click to do
  // anything, per round-4 Fix 5's disabled-when-absent toolbar behavior.
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
  const workspaceDiff = vi.fn(() => new Promise((resolve, reject) => pendingDiffCalls.push({ resolve, reject })));
  const notifyModeChanged = vi.fn();
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
  return { pendingDiffCalls, workspaceDiff, notifyModeChanged, diffSignatureCallbacks, subscribeDiffSignature };
});

vi.mock("../src/bridge", () => ({
  createBridge: async () => ({
    notifyReady: () => {
      queueMicrotask(() => {
        window.dispatchEvent(new CustomEvent("spaces:init", { detail: INIT_PAYLOAD }));
      });
    },
    workspaceDiff: hoisted.workspaceDiff,
    workspaceFileRead: vi.fn().mockRejectedValue(new Error("not used")),
    workspaceFileWrite: vi.fn().mockRejectedValue(new Error("not used")),
    workspaceFileList: vi.fn().mockRejectedValue(new Error("not used")),
    subscribeDiffSignature: hoisted.subscribeDiffSignature,
    subscribeFileSignature: vi.fn(() => () => {}),
    notifyEditorStateChanged: vi.fn(),
    notifyModeChanged: hoisted.notifyModeChanged,
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

/** Simulates a diff-signature push event on whichever scope is currently subscribed (see
 *  `hoisted.diffSignatureCallbacks`'s doc comment). */
function fireDiffSignature(): void {
  const callbacks = hoisted.diffSignatureCallbacks;
  if (callbacks.length === 0) throw new Error("no diff-signature subscription registered yet");
  callbacks[callbacks.length - 1]!();
}

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
    clickButton(container, "vs main"); // dispatches setScope -> refreshDiff (scope B), coalesced
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
    clickButton(container, "vs main");
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

    clickButton(container, "vs main"); // dispatches setScope -> a fresh refreshDiff call for scope B
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

    clickButton(container, "vs main"); // fresh scope, fresh refreshDiff call
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
    clickButton(container, "vs main");
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
    clickButton(container, "vs main");
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
    clickButton(container, "vs main");
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

    clickButton(container, "vs main"); // no new recovery plumbing needed: setScope's own refreshDiff call recovers it
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

    clickButton(container, "vs main"); // fresh scope; this refresh fails transiently again
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

    clickButton(container, "vs main");
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

    clickButton(container, "vs main"); // dispatches setScope
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

    clickButton(container, "vs main");
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

    clickButton(container, "vs main");
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
