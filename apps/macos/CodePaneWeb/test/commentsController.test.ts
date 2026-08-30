import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { CommentsController, CommentsToolbarState } from "../src/app/commentsController";
import type { DiffView } from "../src/app/diffView";
import {
  CodePaneAgentSummary,
  DiffFileEntry,
  PendingReviewCommentEntry,
  ReviewCommentSendEntry,
  ReviewCommentUpsertInput,
  SpacesBridge,
  SpacesBridgeError,
  SpacesReviewComment,
} from "../src/bridge/types";

/**
 * `CommentsController` only calls the four `reviewComment*` RPCs, so every other `SpacesBridge`
 * method is stubbed to reject — a test that accidentally exercises one fails loudly instead of
 * hanging.
 */
function makeBridge(): SpacesBridge & {
  drafts: Map<string, SpacesReviewComment>;
  sendCalls: Array<{ sessionId: string; text: string; comments: ReviewCommentSendEntry[] }>;
  failNextSend: SpacesBridgeError | undefined;
  failNextUpsert: SpacesBridgeError | undefined;
  /** round-16 Fix 2: mirrors `failNextUpsert`'s one-shot check-then-clear-then-throw pattern, for
   *  `reviewCommentDelete` — used by the Fix 2 tests to force a typed rejection distinct from the
   *  RPC's own `notFound`-for-unknown-id behavior. */
  failNextDelete: SpacesBridgeError | undefined;
  /** Round-3 codex Fix 3: same one-shot check-then-clear-then-throw pattern, for `reviewCommentList`
   *  — used by the `loadInitial` retry tests to simulate a transient failure distinct from a
   *  parked/held call. Unlike `failNextUpsert`/`failNextDelete` this is settable to reject more than
   *  once in a row (tests reassign it between attempts) to exercise the retry backoff itself. */
  failNextList: SpacesBridgeError | undefined;
  upsertCallCount: number;
  /** When true, the next `reviewCommentUpsert` call parks on an internally-created promise instead
   *  of resolving immediately, and stashes that promise's `resolve` on `releaseHeldUpsert` — set by
   *  Fix 1's tests to simulate a blur's fire-and-forget persist still being in flight when a card
   *  action (Send/Delete) fires. Reset to `false` as soon as the held call is made (a *later*
   *  upsert call within the same test resolves normally unless this is set again). */
  holdNextUpsert: boolean;
  releaseHeldUpsert: (() => void) | undefined;
  /** Same mechanism as `holdNextUpsert`, for `reviewCommentList` — used by Fix 4's tests to hold
   *  `loadInitial`'s RPC open while a provisional draft is created locally. */
  holdNextList: boolean;
  releaseHeldList: (() => void) | undefined;
  /** Same one-shot mechanism as `holdNextUpsert`, for `reviewCommentDelete` — used by round-13's
   *  Fix 2 tests to hold a blur-time auto-discard's delete RPC open while `sendBatch` is invoked. */
  holdNextDelete: boolean;
  releaseHeldDelete: (() => void) | undefined;
  /** Same one-shot mechanism as `holdNextUpsert`, for `reviewCommentsSend` — used by Fix 1 (P2)'s
   *  tests to hold a send open while simulating text typed into the card after the click (`sendOne`)
   *  or into a still-focused card mid-batch (`sendBatch`). */
  holdNextSend: boolean;
  releaseHeldSend: (() => void) | undefined;
} {
  let nextId = 0;
  const drafts = new Map<string, SpacesReviewComment>();
  const sendCalls: Array<{ sessionId: string; text: string; comments: ReviewCommentSendEntry[] }> = [];
  const notUsed = () => Promise.reject(new Error("not used in this test"));
  const bridge = {
    drafts,
    sendCalls,
    failNextSend: undefined as SpacesBridgeError | undefined,
    failNextUpsert: undefined as SpacesBridgeError | undefined,
    failNextDelete: undefined as SpacesBridgeError | undefined,
    failNextList: undefined as SpacesBridgeError | undefined,
    upsertCallCount: 0,
    holdNextUpsert: false,
    releaseHeldUpsert: undefined as (() => void) | undefined,
    holdNextList: false,
    releaseHeldList: undefined as (() => void) | undefined,
    holdNextDelete: false,
    releaseHeldDelete: undefined as (() => void) | undefined,
    holdNextSend: false,
    releaseHeldSend: undefined as (() => void) | undefined,
    workspaceDiffManifestChunk: notUsed,
    workspaceDiffFileChunk: notUsed,
    workspaceDiffFileChunkCancel: notUsed,
    workspaceDiffManifestRelease: notUsed,
    workspaceFileRead: notUsed,
    workspaceRevisionFileRead: notUsed,
    workspaceFileWrite: notUsed,
    workspaceFileList: notUsed,
    workspaceRefList: notUsed,
    subscribeDiffSignature: () => () => {},
    subscribeFileListSignature: () => () => {},
    subscribeFileSignature: () => () => {},
    notifyWorkspaceStateChanged: () => {},
    notifyRenderMetric: () => {},
    notifyReady: () => {},
    startWorkspaceCommand: notUsed,
    resumeWorkspaceCommandTracking: notUsed,
    async reviewCommentList() {
      if (bridge.failNextList) {
        const err = bridge.failNextList;
        bridge.failNextList = undefined;
        throw err;
      }
      if (bridge.holdNextList) {
        bridge.holdNextList = false;
        await new Promise<void>((resolve) => {
          bridge.releaseHeldList = resolve;
        });
      }
      return [...drafts.values()];
    },
    async reviewCommentUpsert(input: ReviewCommentUpsertInput) {
      bridge.upsertCallCount += 1;
      if (bridge.failNextUpsert) {
        const err = bridge.failNextUpsert;
        bridge.failNextUpsert = undefined;
        throw err;
      }
      if (bridge.holdNextUpsert) {
        bridge.holdNextUpsert = false;
        await new Promise<void>((resolve) => {
          bridge.releaseHeldUpsert = resolve;
        });
      }
      // Mirrors the real daemon (see `reviewCommentUpsert`'s JSDoc in ../src/bridge/types.ts): an
      // explicit id that doesn't already name a row is rejected, never recreated. Without this, a
      // stale post-delete upsert would silently resurrect the deleted row instead of failing the way
      // the real daemon does, making the round-23 divergent-commit-loop regression test impossible to
      // write correctly.
      if (input.id !== undefined && !drafts.has(input.id)) {
        throw new SpacesBridgeError("notFound", `no such draft: ${input.id}`);
      }
      const now = "2026-08-20T00:00:00.000Z";
      const id = input.id ?? `c${++nextId}`;
      const existing = drafts.get(id);
      const comment: SpacesReviewComment = {
        id,
        filePath: input.filePath,
        side: input.side,
        lineNumber: input.lineNumber,
        lineText: input.lineText,
        body: input.body,
        createdAt: existing?.createdAt ?? now,
        // Mirrors the daemon store's `ON CONFLICT` bump: a fresh draft starts at `0`, every update
        // increments the existing row's own value (never a re-derived timestamp).
        revision: existing === undefined ? 0 : existing.revision + 1,
      };
      drafts.set(id, comment);
      return comment;
    },
    async reviewCommentDelete(id: string) {
      if (bridge.failNextDelete) {
        const err = bridge.failNextDelete;
        bridge.failNextDelete = undefined;
        throw err;
      }
      if (bridge.holdNextDelete) {
        bridge.holdNextDelete = false;
        await new Promise<void>((resolve) => {
          bridge.releaseHeldDelete = resolve;
        });
      }
      if (!drafts.delete(id)) throw new SpacesBridgeError("notFound", `no such draft: ${id}`);
    },
    async reviewCommentsSend(sessionId: string, text: string, comments: ReviewCommentSendEntry[]) {
      if (bridge.failNextSend) {
        const err = bridge.failNextSend;
        bridge.failNextSend = undefined;
        throw err;
      }
      if (bridge.holdNextSend) {
        bridge.holdNextSend = false;
        await new Promise<void>((resolve) => {
          bridge.releaseHeldSend = resolve;
        });
      }
      sendCalls.push({ sessionId, text, comments });
      for (const entry of comments) drafts.delete(entry.id);
    },
  };
  return bridge;
}

/** Reads the first anchored comment out of the latest `setComments` call — used by the Fix 1/2/3/4
 *  describe blocks below, each of which builds its own bridge/controller/diffViewFake rather than
 *  sharing the first describe block's `beforeEach` state. */
function firstAnchoredComment(diffViewFake: ReturnType<typeof makeFakeDiffView>): SpacesReviewComment {
  const calls = diffViewFake.setComments.mock.calls;
  const anchored = calls.at(-1)![0] as { comment: SpacesReviewComment }[];
  return anchored[0]!.comment;
}

const AGENT: CodePaneAgentSummary = { id: "a1", label: "claude · main", sessionId: "s1" };

const FILE: DiffFileEntry = {
  path: "src/foo.ts",
  status: "modified",
  isBinary: false,
  patch: `diff --git a/src/foo.ts b/src/foo.ts
index 1111111..2222222 100644
--- a/src/foo.ts
+++ b/src/foo.ts
@@ -1,1 +1,1 @@
-old line
+const x = compute();
`,
};

/** Same file, one line shifted: `const x = compute();` sits at new-side line 2 instead of 1 — used
 *  by the Fix 3 tests below to prove a comment's re-anchored position (not its original stored
 *  `lineNumber`) is what gets sent. */
const SHIFTED_FILE: DiffFileEntry = {
  path: "src/foo.ts",
  status: "modified",
  isBinary: false,
  patch: `diff --git a/src/foo.ts b/src/foo.ts
index 1111111..3333333 100644
--- a/src/foo.ts
+++ b/src/foo.ts
@@ -1,1 +1,2 @@
+const extra = 1;
-old line
+const x = compute();
`,
};

/** A minimal stand-in for `DiffView`'s public surface, cast to the real type. */
function makeFakeDiffView() {
  const setComments = vi.fn();
  const updateCommentsForFile = vi.fn();
  const scrollToLine = vi.fn();
  const scrollToFile = vi.fn();
  const fake = { setComments, updateCommentsForFile, scrollToLine, scrollToFile } as unknown as DiffView;
  return { fake, setComments, updateCommentsForFile, scrollToLine, scrollToFile };
}

function lastToolbarState(spy: ReturnType<typeof vi.fn>): CommentsToolbarState {
  return spy.mock.calls.at(-1)![0] as CommentsToolbarState;
}

describe("CommentsController — progressive patch updates", () => {
  it("does not re-anchor or publish unchanged comment state for an unrelated completed file", () => {
    const bridge = makeBridge();
    const onToolbarStateChange = vi.fn<(state: CommentsToolbarState) => void>();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    const other = { ...FILE, path: "src/other.ts", patch: "@@ -1 +1 @@\n-old\n+new" };
    controller.setFiles([FILE, other]);
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const renderedBefore = diffViewFake.setComments.mock.calls.length;
    const toolbarBefore = onToolbarStateChange.mock.calls.length;

    controller.updateFile({ ...other, patch: "@@ -1 +1 @@\n-old\n+newer" });

    expect(diffViewFake.setComments).toHaveBeenCalledTimes(renderedBefore);
    expect(onToolbarStateChange).toHaveBeenCalledTimes(toolbarBefore);
  });

  it("re-anchors only the completed file's affected comment when its line moves", () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });

    controller.updateFile(SHIFTED_FILE);

    expect(diffViewFake.setComments).toHaveBeenCalledTimes(2); // manifest + draft creation only
    const anchored = diffViewFake.updateCommentsForFile.mock.calls.at(-1)![1] as { position?: { lineNumber: number } }[];
    expect(anchored[0]!.position?.lineNumber).toBe(2);
  });

  it("preserves a completed anchor through queued and streaming manifest refreshes until ready", () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });

    // A live refresh has already moved the comment to line 2. The next manifest only carries
    // metadata, so it must not replace that confirmed position with the draft's original line 1.
    controller.updateFile(SHIFTED_FILE);
    const queued = { ...SHIFTED_FILE, patch: undefined, patchState: "queued" as const };
    controller.setFiles([queued]);
    const afterQueued = diffViewFake.setComments.mock.calls.at(-1)![0] as { position?: { lineNumber: number } }[];
    expect(afterQueued[0]!.position?.lineNumber).toBe(2);

    controller.updateFile({ ...queued, patchState: "streaming" });
    const afterStreaming = diffViewFake.setComments.mock.calls.at(-1)![0] as { position?: { lineNumber: number } }[];
    expect(afterStreaming[0]!.position?.lineNumber).toBe(2);

    // Only the completed patch is authoritative enough to recompute the anchor.
    controller.updateFile(FILE);
    const afterReady = diffViewFake.updateCommentsForFile.mock.calls.at(-1)![1] as { position?: { lineNumber: number } }[];
    expect(afterReady[0]!.position?.lineNumber).toBe(1);
  });
});

describe("CommentsController — card create/edit/delete RPC round-trips", () => {
  let bridge: ReturnType<typeof makeBridge>;
  let onToolbarStateChange: ReturnType<typeof vi.fn<(state: CommentsToolbarState) => void>>;
  let controller: CommentsController;
  let diffViewFake: ReturnType<typeof makeFakeDiffView>;

  beforeEach(() => {
    bridge = makeBridge();
    onToolbarStateChange = vi.fn<(state: CommentsToolbarState) => void>();
    controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange });
    diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
  });

  /** Reads the just-opened provisional card back out of the latest `setComments` call — the
   *  controller never returns a draft's id directly from `onRequestNewComment`, since the whole
   *  point of a provisional card is that nothing round-trips to learn one at open time. */
  function latestRenderedDraft(): SpacesReviewComment {
    const calls = diffViewFake.setComments.mock.calls;
    const anchored = calls.at(-1)![0] as { comment: SpacesReviewComment }[];
    return anchored[0]!.comment;
  }

  it("opens a provisional card on gutter click, with no upsert RPC", () => {
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });

    expect(bridge.drafts.size).toBe(0); // nothing round-tripped to the bridge
    const draft = latestRenderedDraft();
    expect(draft.filePath).toBe("src/foo.ts");
    expect(draft.body).toBe("");
  });

  it("saves the body on blur (creating the provisional card server-side), not on every keystroke", async () => {
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const provisionalDraft = latestRenderedDraft();

    const card = controller.hooks.renderCard({ comment: provisionalDraft, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "Why is this recomputed?";
    // Typing alone (input event) must not persist anything.
    textarea.dispatchEvent(new Event("input"));
    expect(bridge.drafts.size).toBe(0);

    textarea.dispatchEvent(new Event("blur"));
    await vi.waitFor(() => expect(bridge.drafts.size).toBe(1));
    const [saved] = [...bridge.drafts.values()];
    expect(saved!.body).toBe("Why is this recomputed?");
    expect(saved!.id).not.toBe(provisionalDraft.id); // provisional key replaced by the server id
    expect(latestRenderedDraft().id).toBe(saved!.id); // and the re-rendered card now carries it
  });

  it("removes a provisional card locally on blur with an empty body, with no RPC", () => {
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const provisionalDraft = latestRenderedDraft();

    const card = controller.hooks.renderCard({ comment: provisionalDraft, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.dispatchEvent(new Event("blur")); // never typed into

    expect(bridge.drafts.size).toBe(0); // nothing ever existed server-side to delete
    expect(lastToolbarState(onToolbarStateChange).draftCount).toBe(0);
  });

  it("deleting a still-provisional card is local-only, with no reviewCommentDelete RPC", () => {
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const provisionalDraft = latestRenderedDraft();

    const card = controller.hooks.renderCard({ comment: provisionalDraft, position: { lineNumber: 1, outdated: false } });
    const deleteBtn = [...card.querySelectorAll("button")].find((b) => b.textContent === "Delete")!;
    deleteBtn.click();

    expect(lastToolbarState(onToolbarStateChange).draftCount).toBe(0);
    expect(bridge.drafts.size).toBe(0); // nothing to have been deleted server-side
  });

  it("Add to batch is a no-op on a still-provisional (empty-body) card", () => {
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const provisionalDraft = latestRenderedDraft();

    const card = controller.hooks.renderCard({ comment: provisionalDraft, position: { lineNumber: 1, outdated: false } });
    const batchBtn = [...card.querySelectorAll("button")].find((b) => b.textContent === "Add to batch")!;
    batchBtn.click();

    // An empty-body card has nothing to batch — `addToBatch`'s own empty-body guard rejects the
    // click before it ever touches `batchedIds`, the same guard `sendOne` uses for an empty send.
    expect(lastToolbarState(onToolbarStateChange).draftCount).toBe(0);
    expect(bridge.drafts.size).toBe(0);
  });

  it("deletes a draft via the card's Delete button", async () => {
    const created = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "existing comment",
    });
    // The controller's in-memory mirror only grows via loadInitial()/createDraft()/saveBody(), not
    // by directly poking the bridge's map — rehydrate it the same way `root.ts` does at mount.
    await controller.loadInitial();

    const card = controller.hooks.renderCard({ comment: created, position: { lineNumber: 1, outdated: false } });
    const deleteBtn = [...card.querySelectorAll("button")].find((b) => b.textContent === "Delete")!;
    deleteBtn.click();

    await vi.waitFor(() => expect(bridge.drafts.has(created.id)).toBe(false));
  });
});

describe("CommentsController — send one and send batch", () => {
  let bridge: ReturnType<typeof makeBridge>;
  let controller: CommentsController;
  let diffViewFake: ReturnType<typeof makeFakeDiffView>;

  beforeEach(async () => {
    bridge = makeBridge();
    controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
  });

  it("send-one persists the live textarea value first (creating the still-provisional draft), then sends and removes it", async () => {
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const provisionalDraft = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[])[0]!.comment;
    expect(bridge.drafts.size).toBe(0); // still provisional: nothing round-tripped yet

    const card = controller.hooks.renderCard({ comment: provisionalDraft, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "Why is this recomputed on every call?"; // no blur yet
    const sendBtn = [...card.querySelectorAll("button")].find((b) => b.textContent === `Send to ${AGENT.label}`)!;
    sendBtn.click();

    await vi.waitFor(() => expect(bridge.sendCalls).toHaveLength(1));
    expect(bridge.sendCalls[0]!.comments).toHaveLength(1);
    expect(bridge.sendCalls[0]!.comments[0]!.id).not.toBe(provisionalDraft.id); // sent under the server-assigned id
    expect(bridge.sendCalls[0]!.comments[0]!.revision).toEqual(expect.any(Number));
    expect(bridge.sendCalls[0]!.text).toContain("Why is this recomputed on every call?");
    expect(bridge.sendCalls[0]!.text).toContain("src/foo.ts:1");
    expect(bridge.drafts.size).toBe(0); // the send call also archived the draft it just created
  });

  it("send-batch sends every current draft in one call, formatted together", async () => {
    await bridge.reviewCommentUpsert({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();", body: "first" });
    await bridge.reviewCommentUpsert({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();", body: "second" });
    await controller.loadInitial();

    await controller.sendBatch();

    expect(bridge.sendCalls).toHaveLength(1);
    expect(bridge.sendCalls[0]!.comments).toHaveLength(2);
    expect(bridge.sendCalls[0]!.text).toContain("first");
    expect(bridge.sendCalls[0]!.text).toContain("second");
    expect(bridge.drafts.size).toBe(0);
  });

  it("a send-batch failure leaves every draft unchanged and surfaces an error", async () => {
    await bridge.reviewCommentUpsert({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();", body: "first" });
    await controller.loadInitial();

    bridge.failNextSend = new SpacesBridgeError("internalError", "daemon unreachable");
    await controller.sendBatch();

    expect(bridge.sendCalls).toHaveLength(0);
    expect(bridge.drafts.size).toBe(1); // nothing removed on rejection
  });

  it("a conflict rejection re-fetches drafts from the bridge instead of trusting the stale local mirror", async () => {
    const created = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "first",
    });
    await controller.loadInitial();

    // Simulate another surface editing the draft after this controller last read it: the bridge's
    // own map now holds a body this controller's `this.drafts` mirror doesn't know about, at a
    // bumped `revision`.
    bridge.drafts.set(created.id, { ...created, body: "edited elsewhere", revision: created.revision + 1 });
    bridge.failNextSend = new SpacesBridgeError("conflict", "Comment changed since it was last read.");

    await controller.sendBatch();

    expect(bridge.sendCalls).toHaveLength(0); // the rejected send never landed
    // The re-fetch pulled the newer body into the controller's mirror, proving `handleSendFailure`
    // re-read from the bridge rather than trusting the pre-send local copy.
    const rendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[])[0]!.comment;
    expect(rendered.body).toBe("edited elsewhere");
  });
});

describe("CommentsController — Fix 1 (P2): text typed into a card while its send is in flight survives as a new provisional draft", () => {
  function setup() {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    return { bridge, controller, diffViewFake };
  }

  it("sendOne: text typed after the click, while the send is held open, survives as a new provisional card at the same anchor", async () => {
    const { bridge, controller, diffViewFake } = setup();
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const provisionalDraft = firstAnchoredComment(diffViewFake);

    // Persist the draft first (unheld) so `sendOne` below takes its `draft.body === body` fast path
    // — no upsert in flight, isolating this test to the send itself being held.
    const card = controller.hooks.renderCard({ comment: provisionalDraft, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "first text";
    textarea.dispatchEvent(new Event("input"));
    textarea.dispatchEvent(new Event("blur"));
    await vi.waitFor(() => expect(bridge.drafts.size).toBe(1));
    const persisted = [...bridge.drafts.values()][0]!;

    const persistedCard = controller.hooks.renderCard({ comment: persisted, position: { lineNumber: 1, outdated: false } });
    const persistedTextarea = persistedCard.querySelector("textarea")!;
    expect(persistedTextarea.value).toBe("first text");

    bridge.holdNextSend = true;
    const sendBtn = [...persistedCard.querySelectorAll("button")].find((b) => b.textContent === `Send to ${AGENT.label}`)!;
    sendBtn.click(); // sendOne reads "first text" live at click time, then issues the (held) send

    await vi.waitFor(() => expect(bridge.releaseHeldSend).toBeDefined());

    // Simulate refocusing the card and typing more while the send is still in flight.
    persistedTextarea.value = "first text plus more";
    persistedTextarea.dispatchEvent(new Event("input"));

    bridge.releaseHeldSend?.();
    await vi.waitFor(() => expect(bridge.sendCalls).toHaveLength(1));

    expect(bridge.drafts.size).toBe(0); // the sent row is archived server-side

    const anchoredAfter = diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[];
    expect(anchoredAfter).toHaveLength(1); // the sent card is gone AND a new provisional card exists
    const newDraft = anchoredAfter[0]!.comment;
    expect(newDraft.id).not.toBe(persisted.id);
    expect(newDraft.filePath).toBe(persisted.filePath);
    expect(newDraft.lineNumber).toBe(persisted.lineNumber);
    expect(newDraft.body).toBe(""); // provisional shape: body empty, live text seeded into liveBodies

    const newCard = controller.hooks.renderCard({ comment: newDraft, position: { lineNumber: 1, outdated: false } });
    const newTextarea = newCard.querySelector("textarea")!;
    expect(newTextarea.value).toBe("first text plus more"); // renders via `liveBodies`, same as a restored draft

    // Blurring it persists through the normal upsert path.
    newTextarea.dispatchEvent(new Event("blur"));
    await vi.waitFor(() => expect(bridge.drafts.size).toBe(1));
    expect([...bridge.drafts.values()][0]!.body).toBe("first text plus more");
  });

  it("sendOne no-op: nothing typed during the flight leaves no new card, matching the existing removal behavior", async () => {
    const { bridge, controller, diffViewFake } = setup();
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const provisionalDraft = firstAnchoredComment(diffViewFake);

    const card = controller.hooks.renderCard({ comment: provisionalDraft, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "first text";
    textarea.dispatchEvent(new Event("input"));
    textarea.dispatchEvent(new Event("blur"));
    await vi.waitFor(() => expect(bridge.drafts.size).toBe(1));
    const persisted = [...bridge.drafts.values()][0]!;

    const persistedCard = controller.hooks.renderCard({ comment: persisted, position: { lineNumber: 1, outdated: false } });
    bridge.holdNextSend = true;
    const sendBtn = [...persistedCard.querySelectorAll("button")].find((b) => b.textContent === `Send to ${AGENT.label}`)!;
    sendBtn.click();

    await vi.waitFor(() => expect(bridge.releaseHeldSend).toBeDefined());
    bridge.releaseHeldSend?.();
    await vi.waitFor(() => expect(bridge.sendCalls).toHaveLength(1));

    expect(bridge.drafts.size).toBe(0);
    const anchoredAfter = diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[];
    expect(anchoredAfter).toHaveLength(0); // no leftover live text — no new card appears
  });

  // round-19 Fix 1 (P1): this test used to assert the OLD pre-commit-loop behavior — a still-focused
  // card's un-blurred live text was excluded from the batch payload and survived send as a new
  // provisional card. docs/spec.md:156 makes a send itself a commit point ("A draft's text is
  // durable as of its last commit point (its card losing focus, or a send)"), and `doSendBatch`'s
  // drain loop now commits any live-divergent draft via `persistBody` before building the batch
  // payload — see its doc comment's Fix 1 (P1) paragraph. This scenario (an `input` event with no
  // `blur`, then a direct `sendBatch()` call) is exactly what that commit loop is meant to catch: from
  // the controller's point of view it is indistinguishable from a hibernation-restored draft that will
  // never blur (the code has no DOM-focus awareness), so the fix necessarily also covers a genuinely
  // still-focused card in this harness. Updated to assert the new, correct behavior: B's live edit is
  // committed (an upsert fires) before the send, its full text is delivered, and no leftover
  // provisional card is created since nothing was left uncommitted.
  it("sendBatch: commits a still-focused card's live-divergent text before building the payload, then delivers it", async () => {
    const { bridge, controller, diffViewFake } = setup();
    const a = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "persisted A",
    });
    const b = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "persisted B",
    });
    await controller.loadInitial();

    // Card B is mid-edit: live text is ahead of its persisted body, and no blur has fired to save it.
    const cardB = controller.hooks.renderCard({ comment: b, position: { lineNumber: 1, outdated: false } });
    const textareaB = cardB.querySelector("textarea")!;
    textareaB.value = "persisted B plus more";
    textareaB.dispatchEvent(new Event("input"));

    bridge.holdNextSend = true;
    const sendPromise = controller.sendBatch();
    // The commit loop persists B's live text and the held send is issued with it BEFORE this resolves
    // — releaseHeldSend only appears once reviewCommentsSend has actually been called.
    await vi.waitFor(() => expect(bridge.releaseHeldSend).toBeDefined());
    expect(bridge.upsertCallCount).toBe(3); // A's initial create, B's initial create, B's commit
    expect(bridge.drafts.get(b.id)?.body).toBe("persisted B plus more"); // committed before the send

    bridge.releaseHeldSend?.();
    await sendPromise;

    expect(bridge.sendCalls).toHaveLength(1);
    expect(bridge.sendCalls[0]!.text).toContain("persisted A");
    expect(bridge.sendCalls[0]!.text).toContain("persisted B plus more");
    expect(bridge.sendCalls[0]!.comments.map((c) => c.id).sort()).toEqual([a.id, b.id].sort());

    expect(bridge.drafts.size).toBe(0); // both server rows archived

    const anchoredAfter = diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[];
    expect(anchoredAfter).toHaveLength(0); // nothing left uncommitted — no leftover provisional card
  });
});

describe("CommentsController — agent availability disables sending, with a reason", () => {
  it("no running agent: the toolbar state reports no selection and the card's Send button is disabled with a reason", () => {
    const bridge = makeBridge();
    const onToolbarStateChange = vi.fn();
    const controller = new CommentsController(bridge, [], { onToolbarStateChange });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const draft = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[])[0]!.comment;

    expect(lastToolbarState(onToolbarStateChange).selectedAgentId).toBeUndefined();

    const card = controller.hooks.renderCard({ comment: draft, position: { lineNumber: 1, outdated: false } });
    const sendBtn = [...card.querySelectorAll("button")].find((b) => b.textContent === "Send")!;
    expect(sendBtn.disabled).toBe(true);
    expect(sendBtn.title).toBe("No agent is running in this workspace.");
  });

  it("sendBatch is a no-op when no agent is selected", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [], { onToolbarStateChange: vi.fn() });
    controller.setFiles([FILE]);
    await bridge.reviewCommentUpsert({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();", body: "hi" });
    await controller.loadInitial();

    await controller.sendBatch();

    expect(bridge.sendCalls).toHaveLength(0);
    expect(bridge.drafts.size).toBe(1);
  });
});

describe("CommentsController — spaces:agents re-selection", () => {
  it("re-runs the auto-default rule and keeps a still-present manual pick", async () => {
    const AGENT_2: CodePaneAgentSummary = { id: "a2", label: "codex · fix", sessionId: "s2" };
    const onToolbarStateChange = vi.fn();
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT, AGENT_2], { onToolbarStateChange });

    controller.onAgentSelected(AGENT_2.id);
    expect(lastToolbarState(onToolbarStateChange).selectedAgentId).toBe(AGENT_2.id);

    // AGENT_2 disappears: falls back to the sole remaining agent.
    controller.onAgentsChanged([AGENT]);
    expect(lastToolbarState(onToolbarStateChange).selectedAgentId).toBe(AGENT.id);
  });
});

describe("CommentsController — Fix 1: card actions serialize against a blur's in-flight persist", () => {
  function setup() {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    return { bridge, controller, diffViewFake };
  }

  it("blur-then-Send on a provisional card: only the blur's upsert goes out, and the send uses its server id", async () => {
    const { bridge, controller, diffViewFake } = setup();
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const provisionalDraft = firstAnchoredComment(diffViewFake);

    const card = controller.hooks.renderCard({ comment: provisionalDraft, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "Needs a null check";
    textarea.dispatchEvent(new Event("input"));

    bridge.holdNextUpsert = true;
    textarea.dispatchEvent(new Event("blur")); // fires persistBody, held open mid-flight

    const sendBtn = [...card.querySelectorAll("button")].find((b) => b.textContent === `Send to ${AGENT.label}`)!;
    sendBtn.click(); // sendOne races the still-unresolved blur persist

    await vi.waitFor(() => expect(bridge.releaseHeldUpsert).toBeDefined());
    expect(bridge.upsertCallCount).toBe(1); // sendOne is awaiting the blur's call, not issuing its own

    bridge.releaseHeldUpsert?.();
    await vi.waitFor(() => expect(bridge.sendCalls).toHaveLength(1));

    expect(bridge.upsertCallCount).toBe(1); // sendOne never issued a second upsert once it resolved
    expect(bridge.sendCalls[0]!.comments).toHaveLength(1);
    expect(bridge.sendCalls[0]!.comments[0]!.id).not.toBe(provisionalDraft.id); // sent under the server id
    expect(bridge.sendCalls[0]!.text).toContain("Needs a null check");
    expect(bridge.drafts.size).toBe(0); // archived by the send, no leftover row
  });

  it("blur-then-Delete on a provisional card: deletes the server row the blur created, leaving no orphan", async () => {
    const { bridge, controller, diffViewFake } = setup();
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const provisionalDraft = firstAnchoredComment(diffViewFake);

    const card = controller.hooks.renderCard({ comment: provisionalDraft, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "Leftover from debugging";
    textarea.dispatchEvent(new Event("input"));

    bridge.holdNextUpsert = true;
    textarea.dispatchEvent(new Event("blur")); // fires persistBody, held open mid-flight

    const deleteBtn = [...card.querySelectorAll("button")].find((b) => b.textContent === "Delete")!;
    deleteBtn.click(); // deleteDraft races the still-unresolved blur persist

    await vi.waitFor(() => expect(bridge.releaseHeldUpsert).toBeDefined());
    bridge.releaseHeldUpsert?.();

    // The blur's persist lands, creating a server row; deleteDraft — having awaited that persist —
    // must then delete that same (server-assigned) row rather than treating it as already gone.
    await vi.waitFor(() => expect(bridge.drafts.size).toBe(0));
    expect(bridge.drafts.has(provisionalDraft.id)).toBe(false);
  });

  it("resolves a stale provisional id to its current server id after an earlier persist already re-keyed it", async () => {
    const { bridge, controller, diffViewFake } = setup();
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const provisionalDraft = firstAnchoredComment(diffViewFake);

    const card = controller.hooks.renderCard({ comment: provisionalDraft, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "Please add a test";
    textarea.dispatchEvent(new Event("input"));
    textarea.dispatchEvent(new Event("blur"));
    await vi.waitFor(() => expect(bridge.drafts.size).toBe(1)); // fully persisted & re-keyed by now

    // The button's click handler still closes over the original (now-stale) provisional id, since
    // this card was only ever rendered once.
    const sendBtn = [...card.querySelectorAll("button")].find((b) => b.textContent === `Send to ${AGENT.label}`)!;
    sendBtn.click();

    await vi.waitFor(() => expect(bridge.sendCalls).toHaveLength(1));
    expect(bridge.sendCalls[0]!.text).toContain("Please add a test"); // went through, not a silent no-op
  });
});

describe("CommentsController — Fix 1 (round-2): persistBody re-resolves a stale id after a prior persist already re-keyed it", () => {
  function setup() {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    return { bridge, controller, diffViewFake };
  }

  it("a second blur on the same still-open card re-resolves through the alias the first blur's persist just created, sending the newer body as an update instead of silently no-opping", async () => {
    const { bridge, controller, diffViewFake } = setup();
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const provisionalDraft = firstAnchoredComment(diffViewFake);

    const card = controller.hooks.renderCard({ comment: provisionalDraft, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "first body";
    textarea.dispatchEvent(new Event("input"));

    bridge.holdNextUpsert = true;
    textarea.dispatchEvent(new Event("blur")); // fires persistBody(provisionalDraft.id, "first body"), held mid-flight
    await vi.waitFor(() => expect(bridge.releaseHeldUpsert).toBeDefined());
    expect(bridge.upsertCallCount).toBe(1);

    // A second blur for the same id in quick succession — persistBody's own doc-comment example —
    // queues behind the still-unresolved first persist rather than issuing its own upsert yet.
    textarea.value = "second body";
    textarea.dispatchEvent(new Event("input"));
    textarea.dispatchEvent(new Event("blur"));
    await new Promise((resolve) => setTimeout(resolve, 0)); // let the second call reach its own await
    expect(bridge.upsertCallCount).toBe(1); // still just the held create — the second call is queued, not yet run

    bridge.releaseHeldUpsert?.();
    await vi.waitFor(() => expect(bridge.upsertCallCount).toBe(2)); // the second call's own update lands

    expect(bridge.drafts.size).toBe(1); // no orphaned duplicate row
    const [persisted] = [...bridge.drafts.values()];
    expect(persisted!.id).not.toBe(provisionalDraft.id); // re-keyed to the server id, as usual
    // Before this fix, doPersistBody looked up the STALE provisional id (never re-resolved after the
    // await), found nothing, and returned `true` without persisting — silently dropping this edit.
    expect(persisted!.body).toBe("second body");
  });

  it("sendBatch carries the newer body once the re-resolved second persist has landed", async () => {
    const { bridge, controller, diffViewFake } = setup();
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const provisionalDraft = firstAnchoredComment(diffViewFake);

    const card = controller.hooks.renderCard({ comment: provisionalDraft, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "first body";
    textarea.dispatchEvent(new Event("input"));

    bridge.holdNextUpsert = true;
    textarea.dispatchEvent(new Event("blur"));
    await vi.waitFor(() => expect(bridge.releaseHeldUpsert).toBeDefined());

    textarea.value = "second body";
    textarea.dispatchEvent(new Event("input"));
    textarea.dispatchEvent(new Event("blur"));
    await new Promise((resolve) => setTimeout(resolve, 0));

    bridge.releaseHeldUpsert?.();
    await vi.waitFor(() => expect(bridge.upsertCallCount).toBe(2));
    await vi.waitFor(() => expect(bridge.drafts.size).toBe(1));

    await controller.sendBatch();
    expect(bridge.sendCalls).toHaveLength(1);
    expect(bridge.sendCalls[0]!.text).toContain("second body");
    expect(bridge.sendCalls[0]!.text).not.toContain("first body");
  });

  it("a persist that arrives after its draft was deleted while queued behind the draft's own create resolves true, with no update RPC and no banner", async () => {
    const { bridge, controller, diffViewFake } = setup();
    const container = document.createElement("div");
    controller.mount(container);
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const provisionalDraft = firstAnchoredComment(diffViewFake);

    const card = controller.hooks.renderCard({ comment: provisionalDraft, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "first body";
    textarea.dispatchEvent(new Event("input"));

    bridge.holdNextUpsert = true;
    textarea.dispatchEvent(new Event("blur")); // fires persistBody, held mid-flight (the draft's own create)

    const deleteBtn = [...card.querySelectorAll("button")].find((b) => b.textContent === "Delete")!;
    deleteBtn.click(); // deleteDraft queues behind the still-unresolved create

    await vi.waitFor(() => expect(bridge.releaseHeldUpsert).toBeDefined());
    bridge.releaseHeldUpsert?.();
    // Waits on the controller's own re-render rather than `bridge.drafts.size` — the mock's bridge-
    // level map is cleared synchronously inside `reviewCommentDelete`, one microtask *before*
    // `doDeleteDraft` resumes from its own await and updates the controller's local `this.drafts`, so
    // polling the bridge map alone can observe "deleted" before the controller's own mirror is caught
    // up, letting the stale blur below race a delete still in its last leg.
    await vi.waitFor(() => {
      const rendered = diffViewFake.setComments.mock.calls.at(-1)![0] as unknown[];
      expect(rendered.length).toBe(0);
    });

    const rendersBeforeStaleBlur = diffViewFake.setComments.mock.calls.length;
    const upsertCallsBeforeStaleBlur = bridge.upsertCallCount;

    // A straggler edit lands on the same (never-rebuilt, now-orphaned) card after the delete has
    // already fully resolved — mirrors a stray keystroke, or a slow DOM teardown, racing a card
    // another surface just deleted. This card's `lastSavedBody` closure is still "first body" (it
    // was never re-rendered), so this reads as a genuine edit and fires persistBody again.
    textarea.value = "second body";
    textarea.dispatchEvent(new Event("input"));
    textarea.dispatchEvent(new Event("blur"));
    await new Promise((resolve) => setTimeout(resolve, 0)); // flush persistBody's synchronous fast path

    expect(bridge.upsertCallCount).toBe(upsertCallsBeforeStaleBlur); // no update RPC was issued
    expect(bridge.drafts.size).toBe(0); // still nothing server-side
    expect(diffViewFake.setComments.mock.calls.length).toBe(rendersBeforeStaleBlur); // no re-render
    expect((container.querySelector(".banner") as HTMLElement).style.display).toBe("none"); // no banner
  });
});

describe("CommentsController — Fix 2: live text and focus survive a wholesale annotation rebuild", () => {
  function setup() {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    return { bridge, controller, diffViewFake };
  }

  it("a rebuilt card starts from unpersisted live text, not the last-persisted body", () => {
    const { controller, diffViewFake } = setup();
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const draft = firstAnchoredComment(diffViewFake);

    const card = controller.hooks.renderCard({ comment: draft, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "Typed but not blurred yet";
    textarea.dispatchEvent(new Event("input")); // no blur — nothing persisted

    // Simulate a live diff refresh: `@pierre/diffs` wholesale-rebuilds every annotation's card.
    controller.setFiles([FILE]);
    const rebuiltCard = controller.hooks.renderCard({ comment: draft, position: { lineNumber: 1, outdated: false } });
    const rebuiltTextarea = rebuiltCard.querySelector("textarea")!;

    expect(rebuiltTextarea.value).toBe("Typed but not blurred yet");
  });

  it("restores focus and caret position on the rebuilt card when the original was focused", async () => {
    const { controller, diffViewFake } = setup();
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const draft = firstAnchoredComment(diffViewFake);

    const card = controller.hooks.renderCard({ comment: draft, position: { lineNumber: 1, outdated: false } });
    document.body.appendChild(card); // jsdom only tracks `document.activeElement` for a connected node
    const textarea = card.querySelector("textarea")!;
    textarea.value = "some text to place a caret in";
    textarea.dispatchEvent(new Event("input"));
    textarea.focus();
    textarea.setSelectionRange(4, 8);
    expect(document.activeElement).toBe(textarea);

    controller.setFiles([FILE]); // refresh() -> captureFocusedCard() runs before the (mocked) rebuild
    card.remove(); // the library would have torn this down as part of the wholesale rebuild
    const rebuiltCard = controller.hooks.renderCard({ comment: draft, position: { lineNumber: 1, outdated: false } });
    document.body.appendChild(rebuiltCard);
    const rebuiltTextarea = rebuiltCard.querySelector("textarea")!;

    await vi.waitFor(() => expect(document.activeElement).toBe(rebuiltTextarea));
    expect(rebuiltTextarea.selectionStart).toBe(4);
    expect(rebuiltTextarea.selectionEnd).toBe(8);

    document.body.removeChild(rebuiltCard);
  });

  it("blurring the rebuilt card persists exactly once, with the text typed before the rebuild", async () => {
    const { bridge, controller, diffViewFake } = setup();
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const draft = firstAnchoredComment(diffViewFake);

    const card = controller.hooks.renderCard({ comment: draft, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "Saved only after the rebuild";
    textarea.dispatchEvent(new Event("input"));

    controller.setFiles([FILE]);
    const rebuiltCard = controller.hooks.renderCard({ comment: draft, position: { lineNumber: 1, outdated: false } });
    const rebuiltTextarea = rebuiltCard.querySelector("textarea")!;
    expect(rebuiltTextarea.value).toBe("Saved only after the rebuild"); // carried across the rebuild

    rebuiltTextarea.dispatchEvent(new Event("blur"));
    await vi.waitFor(() => expect(bridge.drafts.size).toBe(1));
    expect(bridge.upsertCallCount).toBe(1); // exactly one persist, not one per render
    expect([...bridge.drafts.values()][0]!.body).toBe("Saved only after the rebuild");
  });

  it("drops a sent draft's live-body entry so it cannot leak into a later render under the same id", async () => {
    const { bridge, controller, diffViewFake } = setup();
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const draft = firstAnchoredComment(diffViewFake);

    const card = controller.hooks.renderCard({ comment: draft, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "Ready to send";
    textarea.dispatchEvent(new Event("input"));
    const sendBtn = [...card.querySelectorAll("button")].find((b) => b.textContent === `Send to ${AGENT.label}`)!;
    sendBtn.click();
    await vi.waitFor(() => expect(bridge.sendCalls).toHaveLength(1));

    // Ids are never reused in practice, so this re-renders the exact (now nonexistent) sent id
    // directly to prove `liveBodies` was actually cleared rather than left dangling: a card for
    // that id must fall back to `comment.body`, not resurrect the pre-send typed text.
    const staleCard = controller.hooks.renderCard({
      comment: { ...draft, body: "server body" },
      position: { lineNumber: 1, outdated: false },
    });
    expect(staleCard.querySelector("textarea")!.value).toBe("server body");
  });
});

describe("CommentsController — round-17 Fix 2: keyboard activation of a card action button survives a persist-driven rebuild", () => {
  // Uses an already-persisted draft (created via `reviewCommentUpsert` + `loadInitial`, like the
  // round-11 blocks below) rather than a still-provisional one: a provisional draft's *first*
  // persist re-keys its id (`doPersistBody`'s `idAliases` swap), and `captureFocusedCard` reads the
  // focused button's `dataset.commentId` straight off the DOM — which still names the OLD id at
  // capture time, since the rebuild that would carry the new id hasn't happened yet. That ordering
  // question is orthogonal to this fix (button-focus restore itself) and is exercised by the
  // existing provisional-to-server id-swap coverage elsewhere in this file; keeping the id stable
  // here isolates the mechanism this test is actually proving.
  it("Tab-to-Send then a blur-triggered persist's rebuild still lands keyboard focus on the new, connected Send button, and it is clickable", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    const created = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "original",
    });
    await controller.loadInitial();

    const card = controller.hooks.renderCard({ comment: created, position: { lineNumber: 1, outdated: false } });
    document.body.appendChild(card); // jsdom only tracks `document.activeElement` for a connected node
    const textarea = card.querySelector("textarea")!;
    const sendBtn = [...card.querySelectorAll("button")].find((b) => b.dataset.cardAction === "send")!;

    textarea.value = "edited via keyboard";
    textarea.dispatchEvent(new Event("input"));
    sendBtn.focus(); // Tab moved focus off the textarea onto the card's Send button
    expect(document.activeElement).toBe(sendBtn);

    bridge.holdNextUpsert = true;
    textarea.dispatchEvent(new Event("blur")); // fires persistBody, held mid-flight — captureFocusedCard runs after this resolves
    await vi.waitFor(() => expect(bridge.releaseHeldUpsert).toBeDefined());

    bridge.releaseHeldUpsert?.();
    await vi.waitFor(() => expect(bridge.drafts.get(created.id)?.body).toBe("edited via keyboard"));

    // Simulate the wholesale rebuild the persist's `refresh()` call triggers in the real library.
    const persisted = firstAnchoredComment(diffViewFake);
    card.remove();
    const rebuiltCard = controller.hooks.renderCard({ comment: persisted, position: { lineNumber: 1, outdated: false } });
    document.body.appendChild(rebuiltCard);
    const rebuiltSendBtn = [...rebuiltCard.querySelectorAll("button")].find((b) => b.dataset.cardAction === "send")!;

    await vi.waitFor(() => expect(document.activeElement).toBe(rebuiltSendBtn));
    expect((document.activeElement as HTMLElement).isConnected).toBe(true);
    expect((document.activeElement as HTMLButtonElement).dataset.cardAction).toBe("send");
    expect((document.activeElement as HTMLButtonElement).dataset.commentId).toBe(created.id);
    expect(sendBtn.isConnected).toBe(false); // the old, detached button a naive focus-restore would have missed

    rebuiltSendBtn.click(); // the Enter/Space activation the race would otherwise have lost
    await vi.waitFor(() => expect(bridge.sendCalls).toHaveLength(1));
    expect(bridge.sendCalls[0]!.text).toContain("edited via keyboard");
  });

  // The textarea caret-restore control case (focus stays in the textarea across a rebuild, not on a
  // button) is already covered by "restores focus and caret position on the rebuilt card when the
  // original was focused" in the describe block above — not duplicated here.
});

describe("CommentsController — round-11 Fix 2: sendBatch awaits a pending persist before reading bodies/revisions", () => {
  it("sends the just-edited body (and bumped revision), not the stale pre-edit one, when a blur's persist is still in flight", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    const created = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "original",
    });
    await controller.loadInitial();

    const card = controller.hooks.renderCard({ comment: created, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "edited body";
    textarea.dispatchEvent(new Event("input"));

    bridge.holdNextUpsert = true;
    textarea.dispatchEvent(new Event("blur")); // fires persistBody, held open mid-flight

    const sendBatchPromise = controller.sendBatch(); // races the still-unresolved blur persist

    await vi.waitFor(() => expect(bridge.releaseHeldUpsert).toBeDefined());
    expect(bridge.sendCalls).toHaveLength(0); // sendBatch is blocked awaiting the in-flight persist

    bridge.releaseHeldUpsert?.();
    await sendBatchPromise;

    expect(bridge.upsertCallCount).toBe(2); // the fixture's initial create, plus the blur's edit — sendBatch issued none of its own
    expect(bridge.sendCalls).toHaveLength(1);
    expect(bridge.sendCalls[0]!.text).toContain("edited body");
    expect(bridge.sendCalls[0]!.text).not.toContain("original");
    expect(bridge.sendCalls[0]!.comments).toHaveLength(1);
    expect(bridge.sendCalls[0]!.comments[0]!.revision).toBe(created.revision + 1); // the persist's own bump
    expect(bridge.drafts.has(created.id)).toBe(false); // archived exactly once, no dangling row
  });
});

describe("CommentsController — round-11 Fix 3: 'Add to batch' coordinates against a card's own in-flight persist", () => {
  function setup() {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    return { bridge, controller, diffViewFake };
  }

  it("blur-then-Add-to-batch on a provisional card: stays inline under the server id once the held create-persist resolves, showing a disabled Batched button, and the tray lists it", async () => {
    const { bridge, controller, diffViewFake } = setup();
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const provisionalDraft = firstAnchoredComment(diffViewFake);

    const card = controller.hooks.renderCard({ comment: provisionalDraft, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "Batch this one";
    textarea.dispatchEvent(new Event("input"));

    bridge.holdNextUpsert = true;
    textarea.dispatchEvent(new Event("blur")); // fires persistBody, held open mid-flight

    const batchBtn = [...card.querySelectorAll("button")].find((b) => b.textContent === "Add to batch")!;
    batchBtn.click(); // addToBatch races the still-unresolved blur persist

    await vi.waitFor(() => expect(bridge.releaseHeldUpsert).toBeDefined());
    expect(bridge.upsertCallCount).toBe(1); // addToBatch is awaiting the blur's call, not issuing its own

    bridge.releaseHeldUpsert?.();
    await vi.waitFor(() => expect(bridge.drafts.size).toBe(1));
    const [persisted] = [...bridge.drafts.values()];
    const serverId = persisted!.id;
    expect(serverId).not.toBe(provisionalDraft.id); // re-keyed by the persist, as usual

    // addToBatch's own continuation (resolve id → mark batched) runs after the persist above, so
    // wait for its effect: the batched id stays in the inline list `refreshCardsOnly()` passes to
    // `DiffView.setComments` — a batched comment is never hidden, see `batchedIds`'s doc comment.
    await vi.waitFor(() => {
      const calls = diffViewFake.setComments.mock.calls;
      const visible = calls.at(-1)![0] as { comment: SpacesReviewComment }[];
      expect(visible.find((ac) => ac.comment.id === serverId)).toBeDefined();
    });

    // Batched under the SERVER id, not the stale provisional one — nothing in the bridge or the
    // controller's local mirror still refers to `provisionalDraft.id` at all.
    expect(bridge.drafts.has(provisionalDraft.id)).toBe(false);

    // The card's own "Add to batch" button reflects the batched state: rebuilt as a disabled
    // "Batched" button (renderCard is invoked directly here to inspect the same DOM the controller
    // would have produced for this comment/id).
    const rebuiltCard = controller.hooks.renderCard({ comment: { ...provisionalDraft, id: serverId, body: "Batch this one" }, position: { lineNumber: 1, outdated: false } });
    const rebuiltBatchBtn = [...rebuiltCard.querySelectorAll("button")].find((b) => b.textContent === "Batched")!;
    expect(rebuiltBatchBtn).toBeDefined();
    expect(rebuiltBatchBtn.disabled).toBe(true);

    // The tray lists every sendable draft regardless of batched state (see `renderTray` /
    // `docs/spec.md`'s "Add to batch" correction) — confirm it renders this one.
    const container = document.createElement("div");
    controller.mount(container);
    const rows = container.querySelectorAll(".comment-tray-row");
    expect(rows).toHaveLength(1);
    expect(container.querySelector(".comment-tray-excerpt")!.textContent).toBe("Batch this one");
    expect(container.querySelector(".comment-tray-loc")!.textContent).toBe("src/foo.ts:1");
  });

  it("a create-persist that fails leaves the card un-batched, so its error banner stays visible", async () => {
    const { bridge, controller, diffViewFake } = setup();
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const provisionalDraft = firstAnchoredComment(diffViewFake);
    const rendersBeforeFailure = diffViewFake.setComments.mock.calls.length;

    const card = controller.hooks.renderCard({ comment: provisionalDraft, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "Batch this too";
    textarea.dispatchEvent(new Event("input"));

    bridge.failNextUpsert = new SpacesBridgeError("internalError", "daemon unreachable");
    textarea.dispatchEvent(new Event("blur")); // fires persistBody, which will reject internally

    const batchBtn = [...card.querySelectorAll("button")].find((b) => b.textContent === "Add to batch")!;
    batchBtn.click(); // addToBatch awaits the very same failing persist

    await vi.waitFor(() => expect(bridge.upsertCallCount).toBe(1));
    await new Promise((resolve) => setTimeout(resolve, 0)); // flush the catch → addToBatch's no-op chain

    expect(bridge.drafts.size).toBe(0); // the persist never actually landed server-side
    // round-18 Fix 2: `doPersistBody`'s catch now always calls `refresh()` after
    // `reconcileMirrorAfterRejection` — the same unconditional shape `handleSendFailure` already
    // uses for a send failure — regardless of whether the rejection was a typed one the reconcile
    // actually acts on (this `internalError` isn't, so the mirror itself is untouched; only the
    // render count changes). So exactly one more render happens here versus the old surfaceError-only
    // catch, even though the card is still keyed by the same (never re-keyed) provisional id.
    expect(diffViewFake.setComments.mock.calls.length).toBe(rendersBeforeFailure + 1);
  });
});

describe("CommentsController — 'Add to batch' keeps the card inline (batching is presentation-only)", () => {
  function setup() {
    const bridge = makeBridge();
    const onToolbarStateChange = vi.fn<(state: CommentsToolbarState) => void>();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    const container = document.createElement("div");
    controller.mount(container);
    return { bridge, controller, diffViewFake, container, onToolbarStateChange };
  }

  it("a batched comment stays in the annotations passed to DiffView.setComments, its card shows a disabled Batched button, and the tray still lists it", async () => {
    const { bridge, controller, diffViewFake, container } = setup();
    const persisted = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "please fix this",
    });
    await controller.loadInitial();

    const card = controller.hooks.renderCard({ comment: persisted, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = persisted.body;
    const batchBtn = [...card.querySelectorAll("button")].find((b) => b.textContent === "Add to batch")!;
    batchBtn.click();
    await vi.waitFor(() => expect(bridge.upsertCallCount).toBeGreaterThanOrEqual(0)); // let the click's microtasks settle

    // Still inline: the id is present in the latest annotations passed to setComments, not filtered
    // out — a batched comment is never hidden, see `batchedIds`'s doc comment on the controller.
    const calls = diffViewFake.setComments.mock.calls;
    const visible = calls.at(-1)![0] as { comment: SpacesReviewComment }[];
    expect(visible.find((ac) => ac.comment.id === persisted.id)).toBeDefined();

    // The card's own button reflects the batched state once rebuilt.
    const rebuiltCard = controller.hooks.renderCard({ comment: persisted, position: { lineNumber: 1, outdated: false } });
    const rebuiltBatchBtn = [...rebuiltCard.querySelectorAll("button")].find(
      (b) => b.textContent === "Batched" || b.textContent === "Add to batch",
    )!;
    expect(rebuiltBatchBtn.textContent).toBe("Batched");
    expect(rebuiltBatchBtn.disabled).toBe(true);

    // The tray still lists it, unaffected by batching.
    const rows = container.querySelectorAll(".comment-tray-row");
    expect(rows).toHaveLength(1);
    expect(container.querySelector(".comment-tray-loc")!.textContent).toBe("src/foo.ts:1");
  });

  it("clicking the tray row for a batched comment scrolls to it without un-batching it or hiding the card", async () => {
    const { bridge, controller, diffViewFake, container } = setup();
    const persisted = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "please fix this",
    });
    await controller.loadInitial();

    const card = controller.hooks.renderCard({ comment: persisted, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = persisted.body;
    const batchBtn = [...card.querySelectorAll("button")].find((b) => b.textContent === "Add to batch")!;
    batchBtn.click();

    const setCommentsCallsBeforeTrayClick = diffViewFake.setComments.mock.calls.length;
    const row = container.querySelector(".comment-tray-row") as HTMLElement;
    row.click();

    expect(diffViewFake.scrollToLine).toHaveBeenCalledWith("src/foo.ts", "new", 1);
    // The tray click is scroll-only: it must not trigger another render pass (no un-batch mutation
    // to react to) and the row must still be there afterward.
    expect(diffViewFake.setComments.mock.calls.length).toBe(setCommentsCallsBeforeTrayClick);
    expect(container.querySelectorAll(".comment-tray-row")).toHaveLength(1);

    const rebuiltCard = controller.hooks.renderCard({ comment: persisted, position: { lineNumber: 1, outdated: false } });
    const rebuiltBatchBtn = [...rebuiltCard.querySelectorAll("button")].find(
      (b) => b.textContent === "Batched" || b.textContent === "Add to batch",
    )!;
    expect(rebuiltBatchBtn.textContent).toBe("Batched"); // still batched, not reverted by the click
  });
});

describe("CommentsController — Fix 3: sendOne/sendBatch use the re-anchored line number", () => {
  it("sendOne sends the re-anchored line number when the diff has shifted since the comment was created", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const provisionalDraft = firstAnchoredComment(diffViewFake);
    const card = controller.hooks.renderCard({ comment: provisionalDraft, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "Please guard against null here";
    textarea.dispatchEvent(new Event("input"));
    textarea.dispatchEvent(new Event("blur"));
    await vi.waitFor(() => expect(bridge.drafts.size).toBe(1));

    // The diff shifts: the commented-on line now sits one line further down.
    controller.setFiles([SHIFTED_FILE]);

    const sendBtn = [...card.querySelectorAll("button")].find((b) => b.textContent === `Send to ${AGENT.label}`)!;
    sendBtn.click();

    await vi.waitFor(() => expect(bridge.sendCalls).toHaveLength(1));
    expect(bridge.sendCalls[0]!.text).toContain("src/foo.ts:2\n");
    expect(bridge.sendCalls[0]!.text).not.toContain("src/foo.ts:1\n");
  });

  it("sendBatch sends the re-anchored line number for a shifted draft", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    controller.setFiles([FILE]);
    await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "batched note",
    });
    await controller.loadInitial();

    controller.setFiles([SHIFTED_FILE]);
    await controller.sendBatch();

    expect(bridge.sendCalls).toHaveLength(1);
    expect(bridge.sendCalls[0]!.text).toContain("src/foo.ts:2\n");
  });
});

describe("CommentsController — Fix 4: loadInitial merges instead of clobbering concurrent local drafts", () => {
  it("keeps a provisional draft created while reviewCommentList is still in flight", async () => {
    const bridge = makeBridge();
    const onToolbarStateChange = vi.fn();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "server-side comment",
    });

    bridge.holdNextList = true;
    const loadPromise = controller.loadInitial(); // parks on reviewCommentList
    await vi.waitFor(() => expect(bridge.releaseHeldList).toBeDefined());

    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" }); // provisional, local-only

    bridge.releaseHeldList?.();
    await loadPromise;

    const rendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
    expect(rendered.some((c) => c.body === "server-side comment")).toBe(true); // the listed row
    expect(rendered.some((c) => c.id.startsWith("provisional-"))).toBe(true); // the still-open provisional card
    expect(lastToolbarState(onToolbarStateChange).draftCount).toBe(1); // provisional has no body yet, not counted
  });

  it("does not duplicate a draft whose persist lands (and gets re-keyed) while reviewCommentList is still in flight", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const provisionalDraft = firstAnchoredComment(diffViewFake);

    bridge.holdNextList = true;
    const loadPromise = controller.loadInitial();
    await vi.waitFor(() => expect(bridge.releaseHeldList).toBeDefined());

    // The provisional draft's persist lands (and this.drafts is re-keyed to the server id) while
    // the list RPC above is still parked — the eventual list response, built from `drafts.values()`
    // only once released below, ends up reflecting this same row under the same server id.
    const card = controller.hooks.renderCard({ comment: provisionalDraft, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "Landed mid-flight";
    textarea.dispatchEvent(new Event("input"));
    textarea.dispatchEvent(new Event("blur"));
    await vi.waitFor(() => expect(bridge.drafts.size).toBe(1));

    bridge.releaseHeldList?.();
    await loadPromise;

    const rendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
    expect(rendered.filter((c) => c.body === "Landed mid-flight")).toHaveLength(1); // not double-listed
  });
});

describe("CommentsController — Fix 4 (round-2): loadInitial drops a response row a concurrent send/delete already removed", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  // `makeBridge`'s `reviewCommentList` snapshots `drafts.values()` at *release* time, not at the
  // moment the call was dispatched (see its doc comment) — so a delete/send that fully lands before
  // release already leaves the row out on its own, which would make these tests pass whether or not
  // the fix exists. Each test below restores the row into `bridge.drafts` right before releasing (or
  // before letting a retry attempt call through), standing in for a response the daemon had already
  // serialized *before* the removal committed — the actual race `removedWhileListInFlight` guards
  // against, and the only case in which this bug can manifest.

  it("drops a response row a delete already removed locally while reviewCommentList was in flight", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "server-side comment",
    });
    await controller.loadInitial(); // ordinary rehydration: seeds this.drafts with the persisted row

    const draft = firstAnchoredComment(diffViewFake);
    const card = controller.hooks.renderCard({ comment: draft, position: { lineNumber: 1, outdated: false } });

    bridge.holdNextList = true;
    const loadPromise = controller.loadInitial(); // a second call in flight (e.g. a retry), response pending
    await vi.waitFor(() => expect(bridge.releaseHeldList).toBeDefined());

    const deleteBtn = [...card.querySelectorAll("button")].find((b) => b.textContent === "Delete")!;
    deleteBtn.click();
    await vi.waitFor(() => expect(bridge.drafts.size).toBe(0)); // the delete lands for real, server-side

    bridge.drafts.set(draft.id, draft); // stand in for the daemon's already-serialized stale response
    bridge.releaseHeldList?.();
    await loadPromise;

    const rendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
    expect(rendered.some((c) => c.id === draft.id)).toBe(false); // no ghost card
  });

  it("drops a response row a sendBatch already sent locally while reviewCommentList was in flight", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "server-side comment",
    });
    await controller.loadInitial();
    const draft = firstAnchoredComment(diffViewFake);

    bridge.holdNextList = true;
    const loadPromise = controller.loadInitial();
    await vi.waitFor(() => expect(bridge.releaseHeldList).toBeDefined());

    await controller.sendBatch();
    expect(bridge.sendCalls).toHaveLength(1);
    expect(bridge.drafts.size).toBe(0); // sendBatch's own bridge call removes it synchronously on success

    bridge.drafts.set(draft.id, draft); // stand in for the daemon's already-serialized stale response
    bridge.releaseHeldList?.();
    await loadPromise;

    const rendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
    expect(rendered.some((c) => c.id === draft.id)).toBe(false); // sent comment doesn't reappear
  });

  it("a plain load with no concurrent removal is unaffected", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "plain comment",
    });
    await controller.loadInitial();

    const rendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
    expect(rendered.some((c) => c.body === "plain comment")).toBe(true);
  });

  it("a removal during a failed list attempt still drops the row on the successful retry, and the tombstone doesn't leak into a later, unrelated call", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "server-side comment",
    });
    await controller.loadInitial(); // ordinary rehydration, seeds this.drafts
    const draft = firstAnchoredComment(diffViewFake);
    const card = controller.hooks.renderCard({ comment: draft, position: { lineNumber: 1, outdated: false } });

    vi.useFakeTimers();
    const listSpy = vi.spyOn(bridge, "reviewCommentList");

    // The built-in `holdNextList`/`failNextList` flags can't express "pause, then reject" together —
    // a manual deferred promise stands in for a transient failure that lands after a local removal
    // already raced it, matching `loadInitialRetryFailures`'s retry mechanism this exercises.
    let rejectFirst!: (err: unknown) => void;
    listSpy.mockImplementationOnce(() => new Promise((_resolve, reject) => (rejectFirst = reject)));
    const loadPromise1 = controller.loadInitial(); // parks on the manual promise; listCallsInFlight is 1
    await vi.waitFor(() => expect(rejectFirst).toBeDefined());

    const deleteBtn = [...card.querySelectorAll("button")].find((b) => b.textContent === "Delete")!;
    deleteBtn.click();
    await vi.waitFor(() => expect(bridge.drafts.size).toBe(0)); // the delete lands for real

    rejectFirst(new SpacesBridgeError("unavailable", "device offline"));
    await loadPromise1; // catches, schedules a retry — the tombstone recorded above is NOT cleared here
    expect(listSpy).toHaveBeenCalledTimes(1);

    // Stand in for the daemon's already-serialized stale response, same as the earlier tests — this
    // retry attempt is the one that must apply (then clear) the tombstone recorded during the failure.
    bridge.drafts.set(draft.id, draft);
    await vi.advanceTimersByTimeAsync(1000); // retry #1 fires at the backoff floor and succeeds
    expect(listSpy).toHaveBeenCalledTimes(2);

    const rendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
    expect(rendered.some((c) => c.id === draft.id)).toBe(false); // still no ghost card on the retry

    // The tombstone must not leak past the attempt that consumed it: a later, unrelated load with the
    // row legitimately present must show it normally.
    bridge.drafts.set(draft.id, draft);
    await controller.loadInitial();
    const rendered2 = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
    expect(rendered2.some((c) => c.id === draft.id)).toBe(true);
  });
});

describe("CommentsController — round-2b: reconcileMirrorAfterRejection's own relist shares the Fix 4 tombstone with loadInitial", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it("does not resurrect an unrelated draft whose delete completed while the rejection relist was in flight", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    const a = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "comment A",
    });
    const b = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "comment B",
    });
    await controller.loadInitial();

    // A's delete is rejected with a typed error, triggering reconcileMirrorAfterRejection's own
    // relist — held open via the same `holdNextList`/`releaseHeldList` machinery the Fix 4 tests use
    // for `loadInitial`, since both methods call the same `reviewCommentList` RPC.
    bridge.failNextDelete = new SpacesBridgeError("notFound", "already sent");
    bridge.holdNextList = true;
    const cardA = controller.hooks.renderCard({ comment: a, position: { lineNumber: 1, outdated: false } });
    const deleteBtnA = [...cardA.querySelectorAll("button")].find((btn) => btn.textContent === "Delete")!;
    deleteBtnA.click();
    await vi.waitFor(() => expect(bridge.releaseHeldList).toBeDefined()); // reconcile's own relist is parked

    // While that relist is in flight, an UNRELATED draft (B) is deleted successfully.
    const cardB = controller.hooks.renderCard({ comment: b, position: { lineNumber: 1, outdated: false } });
    const deleteBtnB = [...cardB.querySelectorAll("button")].find((btn) => btn.textContent === "Delete")!;
    deleteBtnB.click();
    await vi.waitFor(() => expect(bridge.drafts.has(b.id)).toBe(false)); // B's delete lands for real, server-side

    const rendersBeforeRelease = diffViewFake.setComments.mock.calls.length;

    // Stand in for the daemon's already-serialized stale response to reconcile's relist, still
    // carrying B — same technique the Fix 4 (round-2) tests above use for `loadInitial`'s response.
    bridge.drafts.set(b.id, b);
    bridge.releaseHeldList?.();

    await vi.waitFor(() => expect(diffViewFake.setComments.mock.calls.length).toBeGreaterThan(rendersBeforeRelease));
    const rendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
    expect(rendered.some((c) => c.id === b.id)).toBe(false); // no ghost card for the unrelated removal
  });

  it("a loadInitial retry and a rejection relist overlapping: the first to resolve does not clear the tombstone the second still needs", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    const a = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "comment A",
    });
    const b = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "comment B",
    });
    await controller.loadInitial(); // ordinary rehydration, seeds this.drafts with both rows

    const cardA = controller.hooks.renderCard({ comment: a, position: { lineNumber: 1, outdated: false } });
    const cardB = controller.hooks.renderCard({ comment: b, position: { lineNumber: 1, outdated: false } });

    // Park a SECOND `loadInitial` call (e.g. a retry) on a manually-controlled promise — the same
    // technique the round-3 codex Fix 3 tests above use — since the built-in `holdNextList` flag is
    // one-shot and reconcile's own relist below needs that mechanism for itself.
    const listSpy = vi.spyOn(bridge, "reviewCommentList");
    let resolveLoadList!: (response: SpacesReviewComment[]) => void;
    listSpy.mockImplementationOnce(() => new Promise((resolve) => (resolveLoadList = resolve)));
    const loadPromise = controller.loadInitial();

    // A's delete is rejected, firing reconcileMirrorAfterRejection's own relist — held via the
    // built-in mechanism now that the mock-once above has been consumed by loadInitial's call.
    bridge.failNextDelete = new SpacesBridgeError("notFound", "already sent");
    bridge.holdNextList = true;
    const deleteBtnA = [...cardA.querySelectorAll("button")].find((btn) => btn.textContent === "Delete")!;
    deleteBtnA.click();
    await vi.waitFor(() => expect(bridge.releaseHeldList).toBeDefined()); // both list calls are now in flight

    // While BOTH are in flight, an UNRELATED draft (B) is deleted successfully.
    const deleteBtnB = [...cardB.querySelectorAll("button")].find((btn) => btn.textContent === "Delete")!;
    deleteBtnB.click();
    await vi.waitFor(() => expect(bridge.drafts.has(b.id)).toBe(false));

    // Stand in for the daemon's already-serialized stale response B rides back in on, for BOTH
    // pending calls.
    bridge.drafts.set(b.id, b);

    // Resolve loadInitial's own call FIRST, while reconcile's relist is still parked — its own
    // decrement must not bring the shared counter to zero yet (reconcile's own call is still
    // outstanding), so it must not clear the tombstone reconcile's relist still needs.
    resolveLoadList([...bridge.drafts.values()]);
    await loadPromise;

    let rendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
    expect(rendered.some((c) => c.id === b.id)).toBe(false); // loadInitial's own response didn't resurrect B

    // Now release reconcile's relist — its response is the same stale snapshot, still carrying B.
    // If the tombstone had been cleared early by loadInitial's completion above, this would
    // resurrect B as a ghost card.
    const rendersBeforeRelease = diffViewFake.setComments.mock.calls.length;
    bridge.releaseHeldList?.();
    await vi.waitFor(() => expect(diffViewFake.setComments.mock.calls.length).toBeGreaterThan(rendersBeforeRelease));

    rendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
    expect(rendered.some((c) => c.id === b.id)).toBe(false); // still no ghost card from the second, overlapping response
  });
});

describe("CommentsController — Fix 3 (P2): list-response merges keep the locally newer row by revision", () => {
  it("loadInitial: a stale relist response landing after a newer local upsert does not revert the row, and a subsequent no-op blur doesn't resend the old body", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    const original = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "old body",
    });
    await controller.loadInitial(); // seeds this.drafts at revision 0

    // A second reviewCommentList call (e.g. an overlapping retry) is dispatched and parked.
    bridge.holdNextList = true;
    const relistPromise = controller.loadInitial();
    await vi.waitFor(() => expect(bridge.releaseHeldList).toBeDefined());

    // While that list call is still in flight, a blur-driven upsert completes for the SAME row,
    // acknowledged by the daemon at revision 1 with a new body — and the persist's drop-if-equal rule
    // clears liveBodies for this id (see doPersistBody), so nothing else masks a reversion.
    const card = controller.hooks.renderCard({ comment: original, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea") as HTMLTextAreaElement;
    textarea.value = "new body";
    textarea.dispatchEvent(new Event("input"));
    textarea.dispatchEvent(new Event("blur"));
    await vi.waitFor(() => expect(bridge.drafts.get(original.id)?.revision).toBe(1));
    const newlyPersisted = bridge.drafts.get(original.id)!;
    expect(newlyPersisted.body).toBe("new body");

    // Stand in for the daemon's already-serialized stale response the held list call carries — same
    // technique the Fix 4 (round-2) tests above use, here to make the release-time snapshot reflect
    // the OLD revision/body instead of the just-persisted one.
    bridge.drafts.set(original.id, original);
    bridge.releaseHeldList?.();
    await relistPromise;
    bridge.drafts.set(original.id, newlyPersisted); // restore true server state for hygiene

    // The stale response must not have reverted the local row: it still shows the new body at the new
    // revision, not the old one the stale relist carried.
    const comment = firstAnchoredComment(diffViewFake);
    expect(comment.body).toBe("new body");
    expect(comment.revision).toBe(1);

    // A subsequent blur on a freshly rendered card (no further typing) must not resend the old body:
    // renderCard's blur handler no-ops once the textarea's value matches the render's own
    // `comment.body` (now "new body", not the reverted "old body"), so no upsert call is issued at all.
    const upsertCallCountBefore = bridge.upsertCallCount;
    const rerenderedCard = controller.hooks.renderCard({ comment, position: { lineNumber: 1, outdated: false } });
    rerenderedCard.querySelector("textarea")!.dispatchEvent(new Event("blur"));
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(bridge.upsertCallCount).toBe(upsertCallCountBefore);
  });

  it("loadInitial: a response row at a revision equal to or newer than local wins (existing behavior preserved)", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    const created = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "v0",
    });
    await controller.loadInitial(); // seeds this.drafts at revision 0

    // A daemon-acknowledged update this controller's mirror never locally applied (e.g. a plain relist
    // picking up a change made through another surface) bumps the row to revision 1 with a new body,
    // entirely through the fake bridge's own store — this controller's local revision stays at 0.
    await bridge.reviewCommentUpsert({
      id: created.id,
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "v1 from elsewhere",
    });

    await controller.loadInitial(); // response revision (1) >= local revision (0) → response wins

    const comment = firstAnchoredComment(diffViewFake);
    expect(comment.body).toBe("v1 from elsewhere");
    expect(comment.revision).toBe(1);
  });

  it("reconcileMirrorAfterRejection: a stale relist response after a rejected mutation does not revert an unrelated row's newer local upsert", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    const a = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "comment A",
    });
    const b = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "comment B",
    });
    await controller.loadInitial();

    // A's delete is rejected with a conflict, triggering reconcileMirrorAfterRejection's own relist —
    // held open the same way the round-2b tests above hold it.
    bridge.failNextDelete = new SpacesBridgeError("conflict", "stale revision");
    bridge.holdNextList = true;
    const cardA = controller.hooks.renderCard({ comment: a, position: { lineNumber: 1, outdated: false } });
    const deleteBtnA = [...cardA.querySelectorAll("button")].find((btn) => btn.textContent === "Delete")!;
    deleteBtnA.click();
    await vi.waitFor(() => expect(bridge.releaseHeldList).toBeDefined()); // reconcile's own relist is parked

    // While that relist is in flight, an UNRELATED draft (B) gets a newer, daemon-acknowledged body via
    // a blur-driven upsert.
    const cardB = controller.hooks.renderCard({ comment: b, position: { lineNumber: 1, outdated: false } });
    const textareaB = cardB.querySelector("textarea") as HTMLTextAreaElement;
    textareaB.value = "comment B, updated";
    textareaB.dispatchEvent(new Event("input"));
    textareaB.dispatchEvent(new Event("blur"));
    await vi.waitFor(() => expect(bridge.drafts.get(b.id)?.revision).toBe(1));
    const newlyPersistedB = bridge.drafts.get(b.id)!;

    // Stand in for the daemon's already-serialized stale response the held relist carries, still at
    // B's OLD revision/body.
    bridge.drafts.set(b.id, b);
    const rendersBeforeRelease = diffViewFake.setComments.mock.calls.length;
    bridge.releaseHeldList?.();
    await vi.waitFor(() => expect(diffViewFake.setComments.mock.calls.length).toBeGreaterThan(rendersBeforeRelease));
    bridge.drafts.set(b.id, newlyPersistedB); // restore true server state for hygiene

    const rendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
    const survivingB = rendered.find((c) => c.id === b.id);
    expect(survivingB?.body).toBe("comment B, updated"); // the locally newer row survives the stale relist
    expect(survivingB?.revision).toBe(1);
  });
});

describe("CommentsController — round-16 Fix 1: comment drafts survive web-view teardown", () => {
  it("restorePendingState recreates a provisional entry as a fresh draft with its live body, and the next blur persists it normally", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    controller.restorePendingState([
      {
        id: "provisional-7", // the pre-teardown id — must not survive into the rehydrated mirror
        provisional: true,
        filePath: "src/foo.ts",
        side: "new",
        lineNumber: 1,
        lineText: "const x = compute();",
        body: "typed before teardown",
      },
    ]);

    const comment = firstAnchoredComment(diffViewFake);
    expect(comment.id).not.toBe("provisional-7"); // recreated under a fresh id minted this session
    expect(comment.body).toBe(""); // the stored draft is still empty — the text lives in liveBodies until persisted

    const card = controller.hooks.renderCard({ comment, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea") as HTMLTextAreaElement;
    expect(textarea.value).toBe("typed before teardown"); // liveBodies seeds the rendered textarea

    textarea.dispatchEvent(new Event("blur")); // unchanged value, but differs from the empty stored body
    await vi.waitFor(() => expect(bridge.drafts.size).toBe(1));
    const persisted = [...bridge.drafts.values()][0]!;
    expect(persisted.body).toBe("typed before teardown");
  });

  it("restorePendingState seeds a persisted entry's live body ahead of loadInitial, so the card shows the in-progress text instead of the last-listed body", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    const persisted = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "last saved",
    });

    controller.restorePendingState([
      {
        id: persisted.id,
        provisional: false,
        filePath: "src/foo.ts",
        side: "new",
        lineNumber: 1,
        lineText: "const x = compute();",
        body: "typed since last save",
      },
    ]);
    await controller.loadInitial(); // merges the listed row in under its real id — restorePendingState never recreates it

    const comment = firstAnchoredComment(diffViewFake);
    expect(comment.body).toBe("last saved"); // the mirror's stored body is still the listed value
    const card = controller.hooks.renderCard({ comment, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea") as HTMLTextAreaElement;
    expect(textarea.value).toBe("typed since last save"); // liveBodies wins over the listed body

    textarea.dispatchEvent(new Event("blur")); // differs from comment.body ("last saved") → persists
    await vi.waitFor(() => expect(bridge.drafts.get(persisted.id)?.body).toBe("typed since last save"));
  });

  it("collectStateForFlush includes only a still-typed provisional draft and a persisted draft with unsaved edits, returning null once nothing qualifies", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    expect(controller.collectStateForFlush()).toBeNull(); // nothing pending yet

    controller.hooks.onRequestNewComment({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
    });
    expect(controller.collectStateForFlush()).toBeNull(); // an empty provisional card has nothing to lose

    const persisted = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "saved",
    });
    await controller.loadInitial();
    expect(controller.collectStateForFlush()).toBeNull(); // a clean persisted draft has nothing to lose either

    const rendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
    const provisionalComment = rendered.find((c) => c.id.startsWith("provisional-"))!;
    const persistedComment = rendered.find((c) => c.id === persisted.id)!;

    const provisionalTextarea = controller.hooks
      .renderCard({ comment: provisionalComment, position: { lineNumber: 1, outdated: false } })
      .querySelector("textarea") as HTMLTextAreaElement;
    provisionalTextarea.value = "typed into provisional";
    provisionalTextarea.dispatchEvent(new Event("input"));

    const persistedTextarea = controller.hooks
      .renderCard({ comment: persistedComment, position: { lineNumber: 1, outdated: false } })
      .querySelector("textarea") as HTMLTextAreaElement;
    persistedTextarea.value = "typed since last save";
    persistedTextarea.dispatchEvent(new Event("input"));

    const flushed = controller.collectStateForFlush();
    expect(flushed).not.toBeNull();
    const entries = JSON.parse(flushed!) as PendingReviewCommentEntry[];
    expect(entries).toHaveLength(2);
    expect(entries.find((e) => e.provisional)?.body).toBe("typed into provisional");
    expect(entries.find((e) => !e.provisional)?.body).toBe("typed since last save");
  });
});

describe("CommentsController — round-11 Fix: a repeat teardown inside the restore→list-merge window still recovers a persisted draft's text", () => {
  it("collectStateForFlush recovers a restored persisted entry's text before loadInitial has resolved, then hands off to the normal path once it has (without double-emitting)", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    const persisted = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "last saved",
    });

    controller.restorePendingState([
      {
        id: persisted.id, // a real-looking, already-persisted id
        provisional: false,
        filePath: "src/foo.ts",
        side: "new",
        lineNumber: 1,
        lineText: "const x = compute();",
        body: "typed since last save", // the live, unsaved text — no draft object exists for this id yet
      },
    ]);

    // Hold reviewCommentList open so loadInitial() has not merged the real draft object into
    // this.drafts yet — this is exactly the restore→list-merge window the fix bridges.
    bridge.holdNextList = true;
    const loadPromise = controller.loadInitial();

    const flushedDuringWindow = controller.collectStateForFlush();
    expect(flushedDuringWindow).not.toBeNull();
    const entriesDuringWindow = JSON.parse(flushedDuringWindow!) as PendingReviewCommentEntry[];
    expect(entriesDuringWindow).toHaveLength(1);
    expect(entriesDuringWindow[0]).toMatchObject({
      id: persisted.id,
      provisional: false,
      body: "typed since last save",
    });

    // Let loadInitial() resolve, merging the real row (still body "last saved") into this.drafts.
    bridge.releaseHeldList!();
    await loadPromise;

    // The normal path (the main loop over this.drafts) now covers this id on its own, since its
    // live text ("typed since last save") still differs from the persisted body ("last saved").
    const flushedAfter = controller.collectStateForFlush();
    expect(flushedAfter).not.toBeNull();
    const entriesAfter = JSON.parse(flushedAfter!) as PendingReviewCommentEntry[];
    expect(entriesAfter).toHaveLength(1); // not 2 — the held copy was retired, not also emitted
    expect(entriesAfter[0]).toMatchObject({ id: persisted.id, body: "typed since last save" });
  });

  it("collectStateForFlush still recovers a restored persisted entry, as a fresh provisional draft, once loadInitial resolves without that id in the response (it was deleted or sent while this pane was torn down) — Fix 1 (P2)", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    controller.restorePendingState([
      {
        id: "c-gone", // never created in bridge.drafts, so reviewCommentList's response omits it
        provisional: false,
        filePath: "src/foo.ts",
        side: "new",
        lineNumber: 1,
        lineText: "const x = compute();",
        body: "typed since last save",
      },
    ]);

    expect(controller.collectStateForFlush()).not.toBeNull(); // held, ahead of loadInitial resolving

    await controller.loadInitial(); // response is empty — "c-gone" was deleted/sent while torn down

    // The old id is gone, but the typed text was never part of that completed send, so it is not
    // lost: loadInitial's leftover-restoredPendingById conversion (Fix 1, P2) recreates it as a fresh
    // provisional draft at the same anchor — collectStateForFlush recovers it under a new id, not null.
    const flushedAfter = controller.collectStateForFlush();
    expect(flushedAfter).not.toBeNull();
    const entriesAfter = JSON.parse(flushedAfter!) as PendingReviewCommentEntry[];
    expect(entriesAfter).toHaveLength(1);
    expect(entriesAfter[0]!.id).not.toBe("c-gone");
    expect(entriesAfter[0]!.id.startsWith("provisional-")).toBe(true);
    expect(entriesAfter[0]).toMatchObject({ provisional: true, body: "typed since last save" });
  });
});

describe("CommentsController — round-19 Fix 1 (P1): sendBatch commits live-divergent draft text before building the batch payload", () => {
  it("commits a restored provisional draft's live text before sending, instead of sending a client-local id the daemon rejects the whole batch for", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    // Simulates a hibernation-restored provisional card: recreated locally with an empty stored body
    // and its typed text seeded only into liveBodies — no blur has ever fired for it this session, so
    // (pre-fix) doSendBatch's drain never touches it and the send payload would carry "provisional-N".
    controller.restorePendingState([
      {
        id: "provisional-9", // the pre-teardown id — irrelevant here, restorePendingState mints a fresh one
        provisional: true,
        filePath: "src/foo.ts",
        side: "new",
        lineNumber: 1,
        lineText: "const x = compute();",
        body: "restored text",
      },
    ]);

    await controller.sendBatch();

    // The commit loop persisted the restored text (creating a real server row) before the send ran.
    expect(bridge.upsertCallCount).toBe(1);
    expect(bridge.sendCalls).toHaveLength(1);
    const sentIds = bridge.sendCalls[0]!.comments.map((c) => c.id);
    expect(sentIds).toHaveLength(1);
    expect(sentIds[0]).not.toMatch(/^provisional-/); // a real server id, not the client-local placeholder
    expect(bridge.sendCalls[0]!.text).toContain("restored text");

    expect(bridge.drafts.size).toBe(0); // the committed-then-sent row is archived server-side
  });

  it("commits a restored persisted draft's newer live text before sending, instead of silently delivering the stale listed body", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    const persisted = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "old",
    });

    // Same restore shape as the round-16 Fix 1 test above: restorePendingState seeds liveBodies ahead
    // of loadInitial's merge, which lands the listed (stale) body into this.drafts.
    controller.restorePendingState([
      {
        id: persisted.id,
        provisional: false,
        filePath: "src/foo.ts",
        side: "new",
        lineNumber: 1,
        lineText: "const x = compute();",
        body: "new",
      },
    ]);
    await controller.loadInitial();

    await controller.sendBatch();

    // The commit loop upserted "new" (bumping the revision) before the send read anything.
    expect(bridge.upsertCallCount).toBe(2); // the initial create, then the restore commit
    expect(bridge.sendCalls).toHaveLength(1);
    expect(bridge.sendCalls[0]!.text).toContain("new");
    expect(bridge.sendCalls[0]!.text).not.toContain("old");
    const sentComment = bridge.sendCalls[0]!.comments.find((c) => c.id === persisted.id)!;
    expect(sentComment.revision).toBe(1); // bumped by the commit, not the stale listed revision (0)
  });

  it("a failed commit-persist during the drain aborts the batch, surfacing the error and leaving the draft's live text retryable", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    const persisted = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "old",
    });

    controller.restorePendingState([
      {
        id: persisted.id,
        provisional: false,
        filePath: "src/foo.ts",
        side: "new",
        lineNumber: 1,
        lineText: "const x = compute();",
        body: "new",
      },
    ]);
    await controller.loadInitial();

    bridge.failNextUpsert = new SpacesBridgeError("internalError", "daemon unreachable");
    await controller.sendBatch();

    expect(bridge.sendCalls).toHaveLength(0); // aborted before anything was sent
    expect(bridge.drafts.get(persisted.id)?.body).toBe("old"); // the server-side row was never touched

    // The draft's live text survives untouched (doPersistBody's catch never mutates liveBodies), so
    // it renders and is retryable on the next blur.
    const comment = firstAnchoredComment(diffViewFake);
    expect(comment.body).toBe("old"); // this.drafts still holds the pre-commit body
    const card = controller.hooks.renderCard({ comment, position: { lineNumber: 1, outdated: false } });
    expect(card.querySelector("textarea")!.value).toBe("new");
  });
});

describe("CommentsController — Fix 1 (P2 hibernation): loadInitial converts a leftover restoredPendingById entry into a fresh provisional draft", () => {
  it("recovers text typed during a send that archived the row before the next loadInitial resolved", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    const persisted = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "saved body",
    });
    await controller.loadInitial();

    const comment = firstAnchoredComment(diffViewFake);
    const card = controller.hooks.renderCard({ comment, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea") as HTMLTextAreaElement;
    textarea.value = "typed but never blurred before teardown";
    textarea.dispatchEvent(new Event("input"));

    const flushed = controller.collectStateForFlush();
    expect(flushed).not.toBeNull();
    const entries = JSON.parse(flushed!) as PendingReviewCommentEntry[];
    expect(entries).toHaveLength(1);
    expect(entries[0]).toMatchObject({
      id: persisted.id,
      provisional: false,
      body: "typed but never blurred before teardown",
    });

    // A fresh controller/bridge stands in for the next page load. The send that archived this row
    // happened entirely server-side — this fresh bridge starts with an empty draft store, so
    // reviewCommentList's response for the fresh controller simply omits the id, matching "the row is
    // gone" with no held-response machinery needed.
    const freshBridge = makeBridge();
    const freshController = new CommentsController(freshBridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const freshDiffViewFake = makeFakeDiffView();
    freshController.attachDiffView(freshDiffViewFake.fake);
    freshController.setFiles([FILE]);

    freshController.restorePendingState(entries);
    await freshController.loadInitial(); // response is empty — the row was sent/archived server-side

    const rendered = (freshDiffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map(
      (ac) => ac.comment,
    );
    expect(rendered).toHaveLength(1);
    const recreated = rendered[0]!;
    expect(recreated.id.startsWith("provisional-")).toBe(true); // fresh provisional id, not the old real one
    expect(recreated.filePath).toBe(persisted.filePath);
    expect(recreated.side).toBe(persisted.side);
    expect(recreated.lineNumber).toBe(persisted.lineNumber);
    expect(recreated.lineText).toBe(persisted.lineText);
    expect(recreated.body).toBe(""); // provisional shape: live text lives in liveBodies until persisted

    const recreatedCard = freshController.hooks.renderCard({ comment: recreated, position: { lineNumber: 1, outdated: false } });
    const recreatedTextarea = recreatedCard.querySelector("textarea") as HTMLTextAreaElement;
    expect(recreatedTextarea.value).toBe("typed but never blurred before teardown"); // renders via liveBodies

    // Blurring it persists through the normal upsert path, under the entry's own anchor.
    const upsertCalls: ReviewCommentUpsertInput[] = [];
    const originalUpsert = freshBridge.reviewCommentUpsert;
    freshBridge.reviewCommentUpsert = (input) => {
      upsertCalls.push(input);
      return originalUpsert(input);
    };
    recreatedTextarea.dispatchEvent(new Event("blur"));
    await vi.waitFor(() => expect(upsertCalls).toHaveLength(1));
    expect(upsertCalls[0]).toMatchObject({
      filePath: persisted.filePath,
      side: persisted.side,
      lineNumber: persisted.lineNumber,
      lineText: persisted.lineText,
      body: "typed but never blurred before teardown",
    });
  });

  it("does not recreate a provisional draft when the held entry's id is still present in the response", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    const persisted = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "last saved",
    });

    controller.restorePendingState([
      {
        id: persisted.id,
        provisional: false,
        filePath: "src/foo.ts",
        side: "new",
        lineNumber: 1,
        lineText: "const x = compute();",
        body: "typed since last save",
      },
    ]);

    await controller.loadInitial(); // response includes persisted.id — covered by the ordinary merge

    const rendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
    expect(rendered).toHaveLength(1); // no extra provisional card
    expect(rendered[0]!.id).toBe(persisted.id);

    const card = controller.hooks.renderCard({ comment: rendered[0]!, position: { lineNumber: 1, outdated: false } });
    expect(card.querySelector("textarea")!.value).toBe("typed since last save"); // liveBodies overlay still applies
  });

  it("drops a whitespace-only held entry without recreating a draft, when its id is absent from the response", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    controller.restorePendingState([
      {
        id: "c-gone", // never created in bridge.drafts, so reviewCommentList's response omits it
        provisional: false,
        filePath: "src/foo.ts",
        side: "new",
        lineNumber: 1,
        lineText: "const x = compute();",
        body: "   ", // whitespace-only: nothing worth preserving
      },
    ]);

    await controller.loadInitial(); // response is empty

    const anchoredAfter = diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[];
    expect(anchoredAfter).toHaveLength(0); // no provisional draft minted

    // The conversion loop deletes liveBodies's entry for the old id unconditionally, before checking
    // whether the text is worth preserving (see loadInitial's implementation) — so nothing is left
    // behind under "c-gone" for collectStateForFlush's main loop to ever stumble on, even though
    // "c-gone" no longer names any draft in this.drafts.
    expect(controller.collectStateForFlush()).toBeNull();
  });
});

describe("CommentsController — round-16 Fix 2: a typed rejection reconciles the local mirror", () => {
  it("sendOne rejected with a typed error re-fetches the mirror, dropping a row the daemon already archived out from under this client", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    const a = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "comment A",
    });
    const b = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "comment B",
    });
    await controller.loadInitial();

    bridge.drafts.delete(a.id); // simulates another surface having already sent it since the last list

    bridge.failNextSend = new SpacesBridgeError("conflict", "stale revision");
    const card = controller.hooks.renderCard({ comment: b, position: { lineNumber: 1, outdated: false } });
    const sendBtn = [...card.querySelectorAll("button")].find((btn) => btn.textContent?.startsWith("Send"))!;
    sendBtn.click();

    await vi.waitFor(() => {
      const rendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
      expect(rendered.some((c) => c.id === a.id)).toBe(false); // the archived row is gone from the relisted mirror
    });
    const rendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
    expect(rendered.some((c) => c.id === b.id)).toBe(true); // b's own send failed but it stays a draft, per the RPC's contract
  });

  it("deleteDraft rejected with a typed error reconciles the mirror the same way", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    const a = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "comment A",
    });
    const b = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "comment B",
    });
    await controller.loadInitial();

    bridge.drafts.delete(a.id); // simulates another surface having already sent it since the last list

    bridge.failNextDelete = new SpacesBridgeError("notFound", "already sent");
    const card = controller.hooks.renderCard({ comment: b, position: { lineNumber: 1, outdated: false } });
    const deleteBtn = [...card.querySelectorAll("button")].find((btn) => btn.textContent === "Delete")!;
    deleteBtn.click();

    await vi.waitFor(() => {
      const rendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
      expect(rendered.some((c) => c.id === a.id)).toBe(false); // the archived row is gone from the relisted mirror
    });
    const rendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
    expect(rendered.some((c) => c.id === b.id)).toBe(true); // b's own delete failed but it stays a draft
  });

  it("a transport-shaped rejection (not a SpacesBridgeError) leaves the mirror untouched, with no relist", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    const container = document.createElement("div");
    controller.mount(container);

    const a = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "comment A",
    });
    await controller.loadInitial();

    const listSpy = vi.spyOn(bridge, "reviewCommentList");
    // A network-hiccup-shaped failure, not a `SpacesBridgeError` — see `reconcileMirrorAfterRejection`'s
    // doc comment for why this must not trigger a re-fetch.
    bridge.reviewCommentsSend = () => Promise.reject(new Error("network hiccup"));

    const card = controller.hooks.renderCard({ comment: a, position: { lineNumber: 1, outdated: false } });
    const sendBtn = [...card.querySelectorAll("button")].find((btn) => btn.textContent?.startsWith("Send"))!;
    sendBtn.click();

    await vi.waitFor(() => {
      const banner = container.querySelector(".banner") as HTMLElement;
      expect(banner.style.display).toBe("flex");
    });
    expect(listSpy).not.toHaveBeenCalled();
    const rendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
    expect(rendered.some((c) => c.id === a.id)).toBe(true); // untouched — no relist happened
  });

  it("an internalError rejection (a daemon hiccup) leaves the mirror untouched, with no relist", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    const container = document.createElement("div");
    controller.mount(container);

    const a = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "comment A",
    });
    await controller.loadInitial();

    const listSpy = vi.spyOn(bridge, "reviewCommentList");
    // A daemon-side hiccup, not proof the mirror is stale — see `reconcileMirrorAfterRejection`'s
    // doc comment for why this must not trigger a re-fetch.
    bridge.failNextSend = new SpacesBridgeError("internalError", "daemon unreachable");
    const card = controller.hooks.renderCard({ comment: a, position: { lineNumber: 1, outdated: false } });
    const sendBtn = [...card.querySelectorAll("button")].find((btn) => btn.textContent?.startsWith("Send"))!;
    sendBtn.click();

    await vi.waitFor(() => {
      const banner = container.querySelector(".banner") as HTMLElement;
      expect(banner.style.display).toBe("flex");
    });
    expect(listSpy).not.toHaveBeenCalled();
    const rendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
    expect(rendered.some((c) => c.id === a.id)).toBe(true); // untouched — no relist happened
  });

  it("an unavailable rejection (agent unreachable / mid-reconnect) leaves the mirror untouched, with no relist", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    const container = document.createElement("div");
    controller.mount(container);

    const a = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "comment A",
    });
    await controller.loadInitial();

    const listSpy = vi.spyOn(bridge, "reviewCommentList");
    // The agent/client is unreachable or mid-reconnect, not proof the mirror is stale — see
    // `reconcileMirrorAfterRejection`'s doc comment for why this must not trigger a re-fetch.
    bridge.failNextSend = new SpacesBridgeError("unavailable", "agent not reachable");
    const card = controller.hooks.renderCard({ comment: a, position: { lineNumber: 1, outdated: false } });
    const sendBtn = [...card.querySelectorAll("button")].find((btn) => btn.textContent?.startsWith("Send"))!;
    sendBtn.click();

    await vi.waitFor(() => {
      const banner = container.querySelector(".banner") as HTMLElement;
      expect(banner.style.display).toBe("flex");
    });
    expect(listSpy).not.toHaveBeenCalled();
    const rendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
    expect(rendered.some((c) => c.id === a.id)).toBe(true); // untouched — no relist happened
  });
});

describe("CommentsController — round-16 Fix 3: a blur auto-discard and a click Delete for the same row coalesce", () => {
  function setup() {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    const container = document.createElement("div");
    controller.mount(container);
    return { bridge, controller, diffViewFake, container };
  }

  it("a blur-triggered auto-discard held in flight is coalesced with a click-triggered delete for the same row, firing only one reviewCommentDelete RPC", async () => {
    const { bridge, controller, container } = setup();
    const created = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "existing comment",
    });
    await controller.loadInitial();

    const deleteSpy = vi.spyOn(bridge, "reviewCommentDelete");
    const card = controller.hooks.renderCard({ comment: created, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    const deleteBtn = [...card.querySelectorAll("button")].find((b) => b.textContent === "Delete")!;

    textarea.value = "";
    textarea.dispatchEvent(new Event("input"));
    bridge.holdNextDelete = true;
    textarea.dispatchEvent(new Event("blur")); // fires deleteDraft(id, true), held open mid-flight
    await vi.waitFor(() => expect(bridge.releaseHeldDelete).toBeDefined());

    deleteBtn.click(); // fires deleteDraft(id, false) for the same row — must coalesce, not issue a second RPC

    bridge.releaseHeldDelete?.();
    await vi.waitFor(() => expect(bridge.drafts.has(created.id)).toBe(false));

    expect(deleteSpy).toHaveBeenCalledTimes(1); // exactly one reviewCommentDelete RPC fired
    const banner = container.querySelector(".banner") as HTMLElement;
    expect(banner.style.display).not.toBe("flex"); // the coalesced (silent) run's outcome produced no spurious banner
  });

  it("sequential deletes for two different cards each fire their own RPC — coalescing keys on the same id only", async () => {
    const { bridge, controller } = setup();
    const a = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "comment A",
    });
    const b = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "comment B",
    });
    await controller.loadInitial();

    const deleteSpy = vi.spyOn(bridge, "reviewCommentDelete");

    const cardA = controller.hooks.renderCard({ comment: a, position: { lineNumber: 1, outdated: false } });
    const deleteBtnA = [...cardA.querySelectorAll("button")].find((btn) => btn.textContent === "Delete")!;
    deleteBtnA.click();
    await vi.waitFor(() => expect(bridge.drafts.has(a.id)).toBe(false));

    const cardB = controller.hooks.renderCard({ comment: b, position: { lineNumber: 1, outdated: false } });
    const deleteBtnB = [...cardB.querySelectorAll("button")].find((btn) => btn.textContent === "Delete")!;
    deleteBtnB.click();
    await vi.waitFor(() => expect(bridge.drafts.has(b.id)).toBe(false));

    expect(deleteSpy).toHaveBeenCalledTimes(2); // each row's delete is independent — no cross-row coalescing
  });
});

describe("CommentsController — round-17 Fix 3: a delete registered under a provisional id follows a persist's re-key to the server id", () => {
  function setup() {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    const container = document.createElement("div");
    controller.mount(container);
    return { bridge, controller, diffViewFake, container };
  }

  it("a delete registered while the draft is still provisional coalesces with a second delete for the re-keyed server id, firing only one reviewCommentDelete RPC", async () => {
    const { bridge, controller, diffViewFake, container } = setup();
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const draft = firstAnchoredComment(diffViewFake);
    const provisionalId = draft.id;

    const card = controller.hooks.renderCard({ comment: draft, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "needs review";
    textarea.dispatchEvent(new Event("input"));

    const deleteSpy = vi.spyOn(bridge, "reviewCommentDelete");
    bridge.holdNextUpsert = true;
    textarea.dispatchEvent(new Event("blur")); // fires persistBody(provisionalId, "needs review"), held mid-flight
    await vi.waitFor(() => expect(bridge.releaseHeldUpsert).toBeDefined());

    const deleteBtn = [...card.querySelectorAll("button")].find((b) => b.textContent === "Delete")!;
    bridge.holdNextDelete = true;
    deleteBtn.click(); // run 1: deleteDraft(provisionalId, false) — parks awaiting the held persist, then its own held delete RPC

    bridge.releaseHeldUpsert?.(); // the persist lands: re-keys idAliases and transfers pendingDeleteById to the server id
    await vi.waitFor(() => expect(bridge.releaseHeldDelete).toBeDefined()); // run 1 resumed and is now parked on its own RPC

    const persisted = firstAnchoredComment(diffViewFake);
    expect(persisted.id).not.toBe(provisionalId); // the server-assigned id the persist adopted

    // Simulate the wholesale rebuild the id swap triggers, then click Delete again using the server
    // id — this must coalesce onto run 1, not start a second RPC.
    const rebuiltCard = controller.hooks.renderCard({ comment: persisted, position: { lineNumber: 1, outdated: false } });
    const rebuiltDeleteBtn = [...rebuiltCard.querySelectorAll("button")].find((b) => b.textContent === "Delete")!;
    rebuiltDeleteBtn.click();

    expect(deleteSpy).toHaveBeenCalledTimes(1); // still just run 1's RPC — no second call issued

    bridge.releaseHeldDelete?.();
    await vi.waitFor(() => expect(bridge.drafts.has(persisted.id)).toBe(false));

    expect(deleteSpy).toHaveBeenCalledTimes(1); // exactly one reviewCommentDelete RPC fired, even after both settle
    const banner = container.querySelector(".banner") as HTMLElement;
    expect(banner.style.display).not.toBe("flex"); // no spurious error banner from the coalesced second click

    const rendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
    expect(rendered.some((c) => c.id === persisted.id)).toBe(false); // row is gone from the rendered output
  });

  it("cleans up the transferred pendingDelete entry in finally even when the coalesced run's RPC rejects, so a later delete for the same row starts a fresh RPC instead of reusing the dead run", async () => {
    const { bridge, controller, diffViewFake, container } = setup();
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const draft = firstAnchoredComment(diffViewFake);

    const card = controller.hooks.renderCard({ comment: draft, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "needs review";
    textarea.dispatchEvent(new Event("input"));

    const deleteSpy = vi.spyOn(bridge, "reviewCommentDelete");
    bridge.holdNextUpsert = true;
    textarea.dispatchEvent(new Event("blur"));
    await vi.waitFor(() => expect(bridge.releaseHeldUpsert).toBeDefined());

    const deleteBtn = [...card.querySelectorAll("button")].find((b) => b.textContent === "Delete")!;
    bridge.holdNextDelete = true;
    deleteBtn.click(); // run 1: parks awaiting the held persist, then its own held delete RPC

    bridge.releaseHeldUpsert?.();
    await vi.waitFor(() => expect(bridge.releaseHeldDelete).toBeDefined());

    const persisted = firstAnchoredComment(diffViewFake);
    const rebuiltCard = controller.hooks.renderCard({ comment: persisted, position: { lineNumber: 1, outdated: false } });
    const rebuiltDeleteBtn = [...rebuiltCard.querySelectorAll("button")].find((b) => b.textContent === "Delete")!;
    rebuiltDeleteBtn.click(); // coalesces onto run 1 — no second RPC yet
    expect(deleteSpy).toHaveBeenCalledTimes(1);

    // Force run 1's held RPC to reject with a typed `notFound` when it resumes, rather than
    // resolving, to prove the `finally` cleanup fires on the failure path too.
    bridge.drafts.delete(persisted.id);
    bridge.releaseHeldDelete?.();

    await vi.waitFor(() => {
      const banner = container.querySelector(".banner") as HTMLElement;
      expect(banner.style.display).toBe("flex"); // run 1's own (non-silent) catch surfaced the failure
    });
    expect(deleteSpy).toHaveBeenCalledTimes(1); // both coalesced calls still share the one failed RPC

    // A third, independent delete for the same row must not reuse run 1's dead, already-settled entry.
    const thirdCard = controller.hooks.renderCard({ comment: persisted, position: { lineNumber: 1, outdated: false } });
    const thirdDeleteBtn = [...thirdCard.querySelectorAll("button")].find((b) => b.textContent === "Delete")!;
    thirdDeleteBtn.click();

    await vi.waitFor(() => expect(deleteSpy).toHaveBeenCalledTimes(2)); // a fresh RPC was issued, not coalesced onto the dead run
  });
});

describe("CommentsController — Fix 1 (round-13): a failed persist aborts sendBatch", () => {
  function setup() {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    const container = document.createElement("div");
    controller.mount(container);
    return { bridge, controller, diffViewFake, container };
  }

  it("a blur-time persist that fails aborts sendBatch, leaving the draft and its typed text intact", async () => {
    const { bridge, controller, diffViewFake, container } = setup();
    const created = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "original",
    });
    await controller.loadInitial();

    const card = controller.hooks.renderCard({ comment: created, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "edited but will fail to save";
    textarea.dispatchEvent(new Event("input"));

    bridge.failNextUpsert = new SpacesBridgeError("internalError", "daemon unreachable");
    textarea.dispatchEvent(new Event("blur")); // fires persistBody, which will reject internally

    await controller.sendBatch(); // races the still-in-flight failing persist; must await it, then abort

    expect(bridge.sendCalls).toHaveLength(0); // never sent
    const banner = container.querySelector(".banner") as HTMLElement;
    expect(banner.style.display).toBe("flex"); // a banner is shown
    expect(bridge.drafts.get(created.id)?.body).toBe("original"); // the daemon's copy is untouched

    // The rendered mirror still holds the pre-edit body too (doPersistBody's catch never updates it)...
    const rendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[])[0]!.comment;
    expect(rendered.body).toBe("original");
    // ...but the newly typed text is still recoverable, not lost.
    const flushed = controller.collectStateForFlush();
    expect(flushed).not.toBeNull();
    const entries = JSON.parse(flushed!) as PendingReviewCommentEntry[];
    expect(entries).toHaveLength(1);
    expect(entries[0]!.body).toBe("edited but will fail to save");
  });

  it("after a failed persist, a subsequent successful blur lets sendBatch proceed with the new body", async () => {
    const { bridge, controller } = setup();
    const created = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "original",
    });
    await controller.loadInitial();

    const card = controller.hooks.renderCard({ comment: created, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "first attempt, will fail";
    textarea.dispatchEvent(new Event("input"));
    bridge.failNextUpsert = new SpacesBridgeError("internalError", "daemon unreachable");
    textarea.dispatchEvent(new Event("blur"));

    await controller.sendBatch(); // aborts: the failed persist never touched this.drafts
    expect(bridge.sendCalls).toHaveLength(0);

    // Blur again with different text — this persist succeeds.
    textarea.value = "second attempt, will succeed";
    textarea.dispatchEvent(new Event("input"));
    textarea.dispatchEvent(new Event("blur"));
    await vi.waitFor(() => expect(bridge.drafts.get(created.id)?.body).toBe("second attempt, will succeed"));

    await controller.sendBatch();
    expect(bridge.sendCalls).toHaveLength(1); // now DOES send
    expect(bridge.sendCalls[0]!.text).toContain("second attempt, will succeed");
  });
});

describe("CommentsController — Fix 2 (round-13): sendBatch serializes with in-flight deletes and filters on live text", () => {
  function setup() {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    return { bridge, controller, diffViewFake };
  }

  it("sendBatch waits for an in-flight blur-triggered delete before sending, excluding the cleared card", async () => {
    const { bridge, controller } = setup();
    const a = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "keep me",
    });
    const b = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "clear me",
    });
    await controller.loadInitial();

    const cardB = controller.hooks.renderCard({ comment: b, position: { lineNumber: 1, outdated: false } });
    const textareaB = cardB.querySelector("textarea")!;
    textareaB.value = "";
    textareaB.dispatchEvent(new Event("input"));

    bridge.holdNextDelete = true;
    textareaB.dispatchEvent(new Event("blur")); // fires deleteDraft(b.id, true), held open mid-flight
    await vi.waitFor(() => expect(bridge.releaseHeldDelete).toBeDefined());

    const sendBatchPromise = controller.sendBatch(); // must serialize with the still-open delete
    await new Promise((resolve) => setTimeout(resolve, 0)); // flush pending microtasks
    expect(bridge.sendCalls).toHaveLength(0); // still blocked

    bridge.releaseHeldDelete?.();
    await sendBatchPromise;

    expect(bridge.sendCalls).toHaveLength(1);
    const sentIds = bridge.sendCalls[0]!.comments.map((c) => c.id);
    expect(sentIds).not.toContain(b.id); // the cleared card is excluded
    expect(sentIds).toContain(a.id); // the other draft still sends
  });

  it("sendBatch proceeds and excludes the cleared card even when its held delete rejects with a transport-shaped error", async () => {
    const { bridge, controller } = setup();
    const a = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "keep me",
    });
    const b = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "clear me",
    });
    await controller.loadInitial();

    let rejectDelete: ((err: unknown) => void) | undefined;
    bridge.reviewCommentDelete = () =>
      new Promise<void>((_resolve, reject) => {
        rejectDelete = reject;
      });

    const cardB = controller.hooks.renderCard({ comment: b, position: { lineNumber: 1, outdated: false } });
    const textareaB = cardB.querySelector("textarea")!;
    textareaB.value = "";
    textareaB.dispatchEvent(new Event("input"));
    textareaB.dispatchEvent(new Event("blur")); // fires deleteDraft(b.id, true), held on the rejecting promise
    await vi.waitFor(() => expect(rejectDelete).toBeDefined());

    const sendBatchPromise = controller.sendBatch();
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(bridge.sendCalls).toHaveLength(0); // still blocked on the pending (about-to-fail) delete

    rejectDelete!(new Error("network hiccup")); // transport-shaped rejection, not a SpacesBridgeError
    await sendBatchPromise; // must not hang or throw

    expect(bridge.sendCalls).toHaveLength(1);
    const sentIds = bridge.sendCalls[0]!.comments.map((c) => c.id);
    expect(sentIds).not.toContain(b.id); // excluded via the live-text filter, even though the delete failed
    expect(sentIds).toContain(a.id);
    expect(bridge.drafts.has(b.id)).toBe(true); // the failed delete never actually removed the server row
  });

  it("does not disturb a single-card batch or an all-empty batch (existing no-op cases stay unaffected)", async () => {
    const { bridge, controller } = setup();
    await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "solo comment",
    });
    await controller.loadInitial();

    await controller.sendBatch();
    expect(bridge.sendCalls).toHaveLength(1);
    expect(bridge.sendCalls[0]!.comments).toHaveLength(1);
  });
});

describe("CommentsController — Fix 3 (round-13): rejection relist merges, keeping only provisional/in-flight rows", () => {
  function setup() {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    return { bridge, controller, diffViewFake };
  }

  it("keeps an open provisional card across a rejection relist, with its typed text intact", async () => {
    const { bridge, controller, diffViewFake } = setup();
    const a = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "comment A",
    });
    const b = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "comment B",
    });
    await controller.loadInitial();

    bridge.drafts.delete(a.id); // simulates another surface having already sent it since the last list

    // A separate provisional card, open and typed into, but never persisted.
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const afterOpen = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
    const provisionalDraft = afterOpen.find((c) => c.id.startsWith("provisional-"))!;
    const provisionalCard = controller.hooks.renderCard({ comment: provisionalDraft, position: { lineNumber: 1, outdated: false } });
    const provisionalTextarea = provisionalCard.querySelector("textarea")!;
    provisionalTextarea.value = "still drafting this one";
    provisionalTextarea.dispatchEvent(new Event("input"));

    bridge.failNextSend = new SpacesBridgeError("conflict", "stale revision");
    const cardB = controller.hooks.renderCard({ comment: b, position: { lineNumber: 1, outdated: false } });
    const sendBtn = [...cardB.querySelectorAll("button")].find((btn) => btn.textContent?.startsWith("Send"))!;
    sendBtn.click();

    await vi.waitFor(() => {
      const rendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
      expect(rendered.some((c) => c.id === a.id)).toBe(false); // the archived row is gone from the relisted mirror
    });

    const finalRendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
    const stillProvisional = finalRendered.find((c) => c.id === provisionalDraft.id);
    expect(stillProvisional).toBeDefined(); // the open provisional card survived the relist merge
    const rebuilt = controller.hooks.renderCard({ comment: stillProvisional!, position: { lineNumber: 1, outdated: false } });
    expect(rebuilt.querySelector("textarea")!.value).toBe("still drafting this one"); // and its typed text is intact
  });

  it("keeps a provisional card whose create-persist is still in flight across a rejection relist, and its server row eventually appears", async () => {
    const { bridge, controller, diffViewFake } = setup();
    const a = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "comment A",
    });
    const b = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "comment B",
    });
    await controller.loadInitial();

    bridge.drafts.delete(a.id); // simulates another surface having already sent it since the last list

    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const afterOpen = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
    const provisionalDraft = afterOpen.find((c) => c.id.startsWith("provisional-"))!;
    const provisionalCard = controller.hooks.renderCard({ comment: provisionalDraft, position: { lineNumber: 1, outdated: false } });
    const provisionalTextarea = provisionalCard.querySelector("textarea")!;
    provisionalTextarea.value = "creating this one now";
    provisionalTextarea.dispatchEvent(new Event("input"));

    bridge.holdNextUpsert = true;
    provisionalTextarea.dispatchEvent(new Event("blur")); // fires persistBody, held open mid-flight
    await vi.waitFor(() => expect(bridge.releaseHeldUpsert).toBeDefined());

    bridge.failNextSend = new SpacesBridgeError("conflict", "stale revision");
    const cardB = controller.hooks.renderCard({ comment: b, position: { lineNumber: 1, outdated: false } });
    const sendBtn = [...cardB.querySelectorAll("button")].find((btn) => btn.textContent?.startsWith("Send"))!;
    sendBtn.click();

    await vi.waitFor(() => {
      const rendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
      expect(rendered.some((c) => c.id === a.id)).toBe(false); // the archived row is gone from the relisted mirror
    });
    const relistedRendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
    // The in-flight create survived the relist merge, still under its provisional id — not stuck invisible.
    expect(relistedRendered.some((c) => c.id === provisionalDraft.id)).toBe(true);

    bridge.releaseHeldUpsert?.();
    await vi.waitFor(() => {
      const rendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
      expect(rendered.some((c) => c.body === "creating this one now" && c.id !== provisionalDraft.id)).toBe(true);
    });
  });

  it("round-16 Fix 2's regression guard still passes unmodified: sendOne rejected with a typed error drops an already-archived row", async () => {
    // This is a duplicate-in-spirit smoke check, not a replacement for the original test above
    // (describe block "CommentsController — round-16 Fix 2") — that exact test is left untouched
    // and re-run as part of the full suite; this confirms the same scenario under Fix 3's new merge
    // logic once more, colocated with the other Fix 3 tests for readability.
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    const a = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "comment A",
    });
    const b = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "comment B",
    });
    await controller.loadInitial();

    bridge.drafts.delete(a.id);

    bridge.failNextSend = new SpacesBridgeError("conflict", "stale revision");
    const card = controller.hooks.renderCard({ comment: b, position: { lineNumber: 1, outdated: false } });
    const sendBtn = [...card.querySelectorAll("button")].find((btn) => btn.textContent?.startsWith("Send"))!;
    sendBtn.click();

    await vi.waitFor(() => {
      const rendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
      expect(rendered.some((c) => c.id === a.id)).toBe(false);
    });
    const rendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
    expect(rendered.some((c) => c.id === b.id)).toBe(true);
  });
});

// Round-3 codex Fix 3: `loadInitial`'s third requirement — "a provisional draft created before the
// retry lands survives the merge" — is already covered by the "Fix 4" describe block above, not
// re-tested here. A retry re-invokes the exact same `loadInitial` body, including the
// `stillLocalOnly` merge below the RPC call, as the very first attempt; it adds no merge logic of
// its own. Fix 4's "keeps a provisional draft created while reviewCommentList is still in flight"
// test already proves a provisional draft survives a `reviewCommentList` call resolving after it
// was created, which is the same code path a retry's eventual successful call exercises.
describe("CommentsController — Fix 3 (round-3 codex): loadInitial retries a transient reviewCommentList failure", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it("retries with backoff after repeated transient failures, surfaces the banner exactly once, and lists the drafts once it succeeds", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    const container = document.createElement("div");
    controller.mount(container);

    await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "server-side comment",
    });

    const listSpy = vi.spyOn(bridge, "reviewCommentList");
    const banner = container.querySelector(".banner") as HTMLElement;

    // Fake timers are switched on before the first failing call so the retry timer it schedules is
    // one `vi.advanceTimersByTimeAsync` can control end to end — switching on partway through (after
    // a real `setTimeout` is already pending) would leave that first retry running on the real clock.
    vi.useFakeTimers();

    bridge.failNextList = new SpacesBridgeError("unavailable", "device offline");
    await controller.loadInitial(); // first attempt: rejects, banner shown, retry #1 scheduled at the 1000ms floor
    expect(listSpy).toHaveBeenCalledTimes(1);
    expect(banner.style.display).toBe("flex");
    // `surfaceError` prefers a `SpacesBridgeError`'s own message over the fallback string (see
    // `surfaceError`), so the banner shows the injected error's message here.
    expect(banner.textContent).toBe("device offline");

    // A second consecutive failure: the counter keeps backing off, and — the point of this test —
    // the banner must NOT be re-shown for it (only the first failure in a retry run does).
    bridge.failNextList = new SpacesBridgeError("unavailable", "device offline");
    banner.textContent = "sentinel"; // would be overwritten by a second surfaceError call
    await vi.advanceTimersByTimeAsync(1000); // retry #1 fires and fails, retry #2 scheduled at 2000ms (doubled)
    expect(listSpy).toHaveBeenCalledTimes(2);
    expect(banner.textContent).toBe("sentinel"); // untouched by the second failure

    // `failNextList` is left unset now, so retry #2 succeeds.
    await vi.advanceTimersByTimeAsync(2000);
    expect(listSpy).toHaveBeenCalledTimes(3);

    const rendered = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[]).map((ac) => ac.comment);
    expect(rendered.some((c) => c.body === "server-side comment")).toBe(true);
  });

  it("a teardown (collectStateForFlush) while a retry is pending stops it from ever calling the bridge again", async () => {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);

    const listSpy = vi.spyOn(bridge, "reviewCommentList");
    vi.useFakeTimers();

    bridge.failNextList = new SpacesBridgeError("unavailable", "device offline");
    await controller.loadInitial(); // fails, retry scheduled
    expect(listSpy).toHaveBeenCalledTimes(1);

    controller.collectStateForFlush(); // teardown seam: must clear the pending retry timer

    // Well past the retry floor (and the 30s cap) — the timer must never fire again post-teardown.
    await vi.advanceTimersByTimeAsync(35000);
    expect(listSpy).toHaveBeenCalledTimes(1);
  });
});

describe("CommentsController — Fix 2 (round-2 P1): sendBatch drains persists registered during its own await", () => {
  function setup() {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    return { bridge, controller, diffViewFake };
  }

  it("includes a card's NEW body/revision when its persist registers (and resolves) during the drain, not just the persist in flight at click time", async () => {
    const { bridge, controller } = setup();
    const x = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "x original",
    });
    const y = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "y original",
    });
    await controller.loadInitial();

    // Card X: an edit+blur whose persist is held open — this is the persist in flight the instant
    // "Send batch" is clicked.
    const cardX = controller.hooks.renderCard({ comment: x, position: { lineNumber: 1, outdated: false } });
    const textareaX = cardX.querySelector("textarea")!;
    textareaX.value = "x edited";
    textareaX.dispatchEvent(new Event("input"));
    bridge.holdNextUpsert = true;
    textareaX.dispatchEvent(new Event("blur")); // fires persistBody(x), held open mid-flight

    const sendBatchPromise = controller.sendBatch(); // races X's still-unresolved persist
    await vi.waitFor(() => expect(bridge.releaseHeldUpsert).toBeDefined());
    expect(bridge.sendCalls).toHaveLength(0); // still draining X

    // While sendBatch is still awaiting X (the one-shot `holdNextUpsert` was already spent on X, so
    // this persist is NOT held), card Y is edited and blurred — its persist REGISTERS during
    // sendBatch's await, which the old one-shot snapshot would have missed entirely.
    const cardY = controller.hooks.renderCard({ comment: y, position: { lineNumber: 1, outdated: false } });
    const textareaY = cardY.querySelector("textarea")!;
    textareaY.value = "y edited";
    textareaY.dispatchEvent(new Event("input"));
    textareaY.dispatchEvent(new Event("blur")); // fires persistBody(y), resolves on its own

    // Let Y's persist land (and update this.drafts) before X is released, proving the drain loop —
    // not the original one-shot snapshot — is what picks it up.
    await vi.waitFor(() => expect(bridge.drafts.get(y.id)?.body).toBe("y edited"));
    const yNewRevision = bridge.drafts.get(y.id)!.revision;
    expect(yNewRevision).toBe(y.revision + 1);

    bridge.releaseHeldUpsert?.(); // let X's persist land too
    await sendBatchPromise;

    expect(bridge.sendCalls).toHaveLength(1);
    const sent = bridge.sendCalls[0]!;
    const yEntry = sent.comments.find((c) => c.id === y.id)!;
    expect(yEntry.revision).toBe(yNewRevision); // Y's NEW revision, not its stale pre-edit one
    expect(sent.text).toContain("y edited");
    expect(sent.text).not.toContain("y original");
    expect(sent.text).toContain("x edited"); // X's own edit went through too
    expect(bridge.drafts.size).toBe(0);
  });

  it("a persist that registers mid-drain and fails aborts the batch, sending nothing", async () => {
    const { bridge, controller } = setup();
    const x = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "x original",
    });
    const y = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "y original",
    });
    await controller.loadInitial();
    const container = document.createElement("div");
    document.body.appendChild(container);
    controller.mount(container);

    const cardX = controller.hooks.renderCard({ comment: x, position: { lineNumber: 1, outdated: false } });
    const textareaX = cardX.querySelector("textarea")!;
    textareaX.value = "x edited";
    textareaX.dispatchEvent(new Event("input"));
    bridge.holdNextUpsert = true;
    textareaX.dispatchEvent(new Event("blur")); // fires persistBody(x), held open mid-flight

    const sendBatchPromise = controller.sendBatch(); // drain-loop iteration 1 awaits X alone
    await vi.waitFor(() => expect(bridge.releaseHeldUpsert).toBeDefined());

    // Card Y's persist is parked on a manually-controlled promise (rather than the one-shot
    // `holdNextUpsert`, already spent on X) so it can be released deterministically AFTER X's
    // iteration has resolved and the drain loop has re-snapshotted the maps — proving iteration 2,
    // not just iteration 1's original snapshot, is what catches this failure.
    let rejectY: ((err: unknown) => void) | undefined;
    const originalUpsert = bridge.reviewCommentUpsert;
    bridge.reviewCommentUpsert = (input) => {
      if (input.id === y.id) {
        return new Promise<SpacesReviewComment>((_resolve, reject) => {
          rejectY = reject;
        });
      }
      return originalUpsert(input);
    };

    const cardY = controller.hooks.renderCard({ comment: y, position: { lineNumber: 1, outdated: false } });
    const textareaY = cardY.querySelector("textarea")!;
    textareaY.value = "y edited but will fail";
    textareaY.dispatchEvent(new Event("input"));
    textareaY.dispatchEvent(new Event("blur")); // fires persistBody(y), registers mid-drain, parked on rejectY

    // Release X: iteration 1 resolves (X succeeded), the loop re-snapshots and finds Y still
    // pending, so it starts iteration 2 awaiting Y.
    //
    // `rejectY` is already defined at this point (it was captured synchronously back when Y's blur
    // fired, above) — waiting on it here would resolve on the very first check and prove nothing.
    // What actually needs waiting for is the drain loop reaching iteration 2 and parking on Y: X's
    // release only *starts* a chain of several microtask ticks (the held upsert's own promise
    // resolving, `doPersistBody(x)` resuming and returning, `persistBody(x)`'s `finally` running,
    // the loop's `Promise.all`s settling) before `sendBatch` re-snapshots `pendingPersistById` and
    // captures Y's still-pending promise into its next `Promise.all`. A `setTimeout` macrotask
    // boundary only runs after every microtask already queued has drained, so it is what actually
    // guarantees that chain has finished — and the loop is durably awaiting Y — before Y is
    // rejected below. Rejecting any earlier (e.g. right after a same-tick `vi.waitFor` check that
    // was already satisfied) races the loop's own re-snapshot: Y can be rejected and removed from
    // `pendingPersistById` by its own `finally` block before the loop ever re-reads the map, which
    // makes iteration 2 see an empty map and exit the loop as if nothing were left to drain —
    // exactly the bug this test exists to catch, so the synchronization here has to be airtight.
    bridge.releaseHeldUpsert?.();
    await new Promise((resolve) => setTimeout(resolve, 0));

    rejectY!(new Error("save failed")); // Y's persist fails, caught by doPersistBody, resolves to false
    await sendBatchPromise;

    expect(bridge.sendCalls).toHaveLength(0); // aborted — nothing sent
    const banner = container.querySelector(".banner") as HTMLElement;
    expect(banner.style.display).toBe("flex");
    expect(bridge.drafts.get(y.id)?.body).toBe("y original"); // the failed persist never touched the server copy
  });
});

describe("CommentsController — Fix 3 (round-2 P1): captures the target agent when the action starts", () => {
  const AGENT_2: CodePaneAgentSummary = { id: "a2", label: "codex · fix", sessionId: "s2" };

  function setup(agents: readonly CodePaneAgentSummary[]) {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, agents, { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    return { bridge, controller, diffViewFake };
  }

  it("sendOne sends to the agent shown at click time, not a dropdown pick made during the pending-persist await", async () => {
    const { bridge, controller, diffViewFake } = setup([AGENT, AGENT_2]);
    controller.onAgentSelected(AGENT.id);

    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const provisionalDraft = firstAnchoredComment(diffViewFake);
    const card = controller.hooks.renderCard({ comment: provisionalDraft, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "Please add a null check";
    textarea.dispatchEvent(new Event("input"));

    bridge.holdNextUpsert = true;
    textarea.dispatchEvent(new Event("blur")); // fires persistBody, held open mid-flight

    const sendBtn = [...card.querySelectorAll("button")].find((b) => b.textContent === `Send to ${AGENT.label}`)!;
    sendBtn.click(); // sendOne captures AGENT before awaiting the still-pending blur persist

    await vi.waitFor(() => expect(bridge.releaseHeldUpsert).toBeDefined());

    // A dropdown pick changes the selection while sendOne is still awaiting the pending persist.
    controller.onAgentSelected(AGENT_2.id);

    bridge.releaseHeldUpsert?.();
    await vi.waitFor(() => expect(bridge.sendCalls).toHaveLength(1));

    expect(bridge.sendCalls[0]!.sessionId).toBe(AGENT.sessionId); // captured at click time, not AGENT_2
  });

  it("sendOne sends to the agent shown at click time even when an agents-update auto-selects a different one during the await", async () => {
    const { bridge, controller, diffViewFake } = setup([AGENT]); // sole agent: auto-selected
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const provisionalDraft = firstAnchoredComment(diffViewFake);
    const card = controller.hooks.renderCard({ comment: provisionalDraft, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "Please add a null check";
    textarea.dispatchEvent(new Event("input"));

    bridge.holdNextUpsert = true;
    textarea.dispatchEvent(new Event("blur"));

    const sendBtn = [...card.querySelectorAll("button")].find((b) => b.textContent === `Send to ${AGENT.label}`)!;
    sendBtn.click();

    await vi.waitFor(() => expect(bridge.releaseHeldUpsert).toBeDefined());

    // AGENT's session ends; AGENT_2 is the sole remaining agent, so `onAgentsChanged`'s auto-default
    // rule (see `selectDefaultAgentId`) re-selects it while sendOne is still awaiting.
    controller.onAgentsChanged([AGENT_2]);

    bridge.releaseHeldUpsert?.();
    await vi.waitFor(() => expect(bridge.sendCalls).toHaveLength(1));

    expect(bridge.sendCalls[0]!.sessionId).toBe(AGENT.sessionId); // captured at click time, not AGENT_2
  });

  it("sendBatch sends to the agent captured at click time, through the Fix-2 drain loop, not a selection change made during it", async () => {
    const { bridge, controller } = setup([AGENT, AGENT_2]);
    controller.onAgentSelected(AGENT.id);

    const x = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "x original",
    });
    await controller.loadInitial();

    const card = controller.hooks.renderCard({ comment: x, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "x edited";
    textarea.dispatchEvent(new Event("input"));

    bridge.holdNextUpsert = true;
    textarea.dispatchEvent(new Event("blur")); // fires persistBody(x), held open mid-flight

    const sendBatchPromise = controller.sendBatch(); // captures AGENT before draining X's pending persist
    await vi.waitFor(() => expect(bridge.releaseHeldUpsert).toBeDefined());

    controller.onAgentSelected(AGENT_2.id); // selection changes mid-drain

    bridge.releaseHeldUpsert?.();
    await sendBatchPromise;

    expect(bridge.sendCalls).toHaveLength(1);
    expect(bridge.sendCalls[0]!.sessionId).toBe(AGENT.sessionId); // captured at click time, not AGENT_2
  });
});

describe("CommentsController — Fix (P2): overlapping sends serialize instead of racing to a false failure", () => {
  function setup() {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    return { bridge, controller, diffViewFake };
  }

  it("double-click Send: exactly one reviewCommentsSend call reaches the bridge, no error banner, and the card is gone", async () => {
    const { bridge, controller, diffViewFake } = setup();
    const persisted = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "please fix this",
    });
    await controller.loadInitial();

    const container = document.createElement("div");
    controller.mount(container);

    const card = controller.hooks.renderCard({ comment: persisted, position: { lineNumber: 1, outdated: false } });
    const sendBtn = [...card.querySelectorAll("button")].find((b) => b.textContent === `Send to ${AGENT.label}`)!;

    bridge.holdNextSend = true;
    sendBtn.click(); // first sendOne: reaches the (held) send RPC and publishes itself into `sendInFlight`
    await vi.waitFor(() => expect(bridge.releaseHeldSend).toBeDefined());

    // Second click lands while the first send is still in flight — without the fix this races the
    // daemon's single-writer queue and comes back a false "not a draft" failure once the first send
    // wins. With the fix it queues behind `sendInFlight` instead.
    sendBtn.click();

    bridge.releaseHeldSend?.(); // one-shot hold: only the first send was ever parked open
    await vi.waitFor(() => expect(bridge.sendCalls).toHaveLength(1));
    // Let the queued second sendOne resume, re-validate against post-send state (the draft is already
    // gone from `this.drafts`), and no-op.
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(bridge.sendCalls).toHaveLength(1); // the second click never issued a second RPC
    const banner = container.querySelector(".banner") as HTMLElement;
    expect(banner.style.display).not.toBe("flex"); // no false "not a draft" failure surfaced
    const anchoredAfter = diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[];
    expect(anchoredAfter).toHaveLength(0); // the card is gone
  });

  it("Send batch queued behind a pending single send: the single send delivers A, then the batch delivers exactly B", async () => {
    const { bridge, controller, diffViewFake } = setup();
    const a = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "comment A",
    });
    const b = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "comment B",
    });
    await controller.loadInitial();

    const container = document.createElement("div");
    controller.mount(container);

    const cardA = controller.hooks.renderCard({ comment: a, position: { lineNumber: 1, outdated: false } });
    const sendBtnA = [...cardA.querySelectorAll("button")].find((btn) => btn.textContent === `Send to ${AGENT.label}`)!;

    bridge.holdNextSend = true; // one-shot: holds only A's send, not B's later one
    sendBtnA.click();
    await vi.waitFor(() => expect(bridge.releaseHeldSend).toBeDefined());

    // "Send batch" fires while A's single send is still pending — it must queue behind A rather than
    // racing it (which would either false-fail A once it lands, or leave B unsent).
    const batchPromise = controller.sendBatch();

    bridge.releaseHeldSend?.(); // release A's held send; the queued batch then runs and sends B
    await batchPromise;

    expect(bridge.sendCalls).toHaveLength(2);
    expect(bridge.sendCalls[0]!.comments.map((c) => c.id)).toEqual([a.id]);
    expect(bridge.sendCalls[1]!.comments.map((c) => c.id)).toEqual([b.id]); // batch recomputed its sendable set post-A

    const banner = container.querySelector(".banner") as HTMLElement;
    expect(banner.style.display).not.toBe("flex");
    const anchoredAfter = diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[];
    expect(anchoredAfter).toHaveLength(0); // both cards gone
  });
});

describe("CommentsController — Fix 1 (round-9 P1): captures the send-target agent before the sendInFlight queued wait", () => {
  const AGENT_2: CodePaneAgentSummary = { id: "a2", label: "codex · fix", sessionId: "s2" };

  function setup() {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT, AGENT_2], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    return { bridge, controller, diffViewFake };
  }

  it("sendOne queued behind another held sendOne still targets the agent selected when it was clicked, not a switch made while queued behind sendInFlight", async () => {
    const { bridge, controller } = setup();
    controller.onAgentSelected(AGENT.id);

    const a = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "comment A",
    });
    const b = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "comment B",
    });
    await controller.loadInitial();

    const cardA = controller.hooks.renderCard({ comment: a, position: { lineNumber: 1, outdated: false } });
    const sendBtnA = [...cardA.querySelectorAll("button")].find((btn) => btn.textContent === `Send to ${AGENT.label}`)!;
    const cardB = controller.hooks.renderCard({ comment: b, position: { lineNumber: 1, outdated: false } });
    const sendBtnB = [...cardB.querySelectorAll("button")].find((btn) => btn.textContent === `Send to ${AGENT.label}`)!;

    bridge.holdNextSend = true; // one-shot: holds only A's send RPC
    sendBtnA.click(); // A's sendOne captures AGENT, reaches the (held) send RPC, publishes into sendInFlight
    await vi.waitFor(() => expect(bridge.releaseHeldSend).toBeDefined());

    // B's sendOne captures AGENT synchronously too (before B's own `while (sendInFlight)` wait even
    // starts), then queues behind A via `sendInFlight` — B's send RPC has not been reached yet.
    sendBtnB.click();

    // Switch the selection while B is queued behind A. Without the fix (capturing after the
    // `sendInFlight` wait), B would resolve `agent` from `selectedAgentId` only once it resumes,
    // targeting AGENT_2 instead of the agent shown when B was actually clicked.
    controller.onAgentSelected(AGENT_2.id);

    bridge.releaseHeldSend?.(); // release A's held send; B then runs (its own send call is not held)
    await vi.waitFor(() => expect(bridge.sendCalls).toHaveLength(2));

    expect(bridge.sendCalls[0]!.sessionId).toBe(AGENT.sessionId);
    expect(bridge.sendCalls[1]!.sessionId).toBe(AGENT.sessionId); // captured at B's click time, not AGENT_2
  });

  it("sendBatch queued behind a held sendOne still targets the agent selected when it was called, not a switch made while queued behind sendInFlight", async () => {
    const { bridge, controller } = setup();
    controller.onAgentSelected(AGENT.id);

    const a = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "comment A",
    });
    const b = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "comment B",
    });
    await controller.loadInitial();

    const cardA = controller.hooks.renderCard({ comment: a, position: { lineNumber: 1, outdated: false } });
    const sendBtnA = [...cardA.querySelectorAll("button")].find((btn) => btn.textContent === `Send to ${AGENT.label}`)!;

    bridge.holdNextSend = true; // one-shot: holds only A's send RPC
    sendBtnA.click();
    await vi.waitFor(() => expect(bridge.releaseHeldSend).toBeDefined());

    // sendBatch captures AGENT synchronously (before its own `sendInFlight` wait even starts), then
    // queues behind A's still-held send.
    const batchPromise = controller.sendBatch();

    // Selection changes while the batch is queued — without the fix, the batch would target AGENT_2
    // once it resumes and re-reads `selectedAgentId`.
    controller.onAgentSelected(AGENT_2.id);

    bridge.releaseHeldSend?.(); // release A's held send; the queued batch then runs and sends B
    await batchPromise;

    expect(bridge.sendCalls).toHaveLength(2);
    expect(bridge.sendCalls[0]!.sessionId).toBe(AGENT.sessionId);
    expect(bridge.sendCalls[1]!.comments.map((c) => c.id)).toEqual([b.id]);
    expect(bridge.sendCalls[1]!.sessionId).toBe(AGENT.sessionId); // captured at call time, not AGENT_2
  });
});

describe("CommentsController — Fix 2 (P2): doSendOne's provisional-to-server id swap migrates liveBodies/pendingFocus and refreshes before the send await", () => {
  function setup() {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    return { bridge, controller, diffViewFake };
  }

  it("a rejected send preserves text typed after the provisional-to-server swap, and persists it under the server id on blur", async () => {
    const { bridge, controller, diffViewFake } = setup();

    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const provisionalDraft = firstAnchoredComment(diffViewFake);
    const card = controller.hooks.renderCard({ comment: provisionalDraft, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "first draft";
    textarea.dispatchEvent(new Event("input"));

    // Records every upsert call's input from here on — used below to prove the blur-time persist
    // targets the server-assigned id, not the stale provisional one.
    const upsertCalls: ReviewCommentUpsertInput[] = [];
    const originalUpsert = bridge.reviewCommentUpsert;
    bridge.reviewCommentUpsert = (input) => {
      upsertCalls.push(input);
      return originalUpsert(input);
    };

    // The upsert (the swap) resolves normally; the subsequent send is parked on a manually-controlled
    // promise so it can be rejected deterministically once the swap's state is inspected — mirrors the
    // Y-reject pattern in the round-11 Fix 2 drain-loop test above.
    let rejectSend: ((err: unknown) => void) | undefined;
    bridge.reviewCommentsSend = () =>
      new Promise<void>((_resolve, reject) => {
        rejectSend = reject;
      });

    const sendBtn = [...card.querySelectorAll("button")].find((b) => b.textContent === `Send to ${AGENT.label}`)!;
    sendBtn.click(); // doSendOne: upsert creates the server row, swaps the id, refreshes, then parks on the send

    await vi.waitFor(() => expect(rejectSend).toBeDefined());

    // The swap's refresh (before the send await) rebuilt the card under the server-assigned id — this
    // is what the fix adds: without it, the latest render would still show the stale provisional id.
    const persisted = firstAnchoredComment(diffViewFake);
    expect(persisted.id).not.toBe(provisionalDraft.id);
    const rebuiltCard = controller.hooks.renderCard({ comment: persisted, position: { lineNumber: 1, outdated: false } });
    const rebuiltTextarea = rebuiltCard.querySelector("textarea")!;

    // Additional typing during the held send lands in `liveBodies` under the server id (the rebuilt
    // card's `dataset.commentId`) — this is the window Fix 2 protects.
    rebuiltTextarea.value = "first draft, plus more typed while the send is in flight";
    rebuiltTextarea.dispatchEvent(new Event("input"));

    rejectSend!(new Error("send failed"));
    await new Promise((resolve) => setTimeout(resolve, 0)); // let handleSendFailure's catch settle

    // Re-render once more to check what actually ends up on screen after the failure.
    const afterFailureComment = firstAnchoredComment(diffViewFake);
    expect(afterFailureComment.id).toBe(persisted.id); // the rejected send never removed/re-keyed the draft
    const afterFailureCard = controller.hooks.renderCard({ comment: afterFailureComment, position: { lineNumber: 1, outdated: false } });
    const afterFailureTextarea = afterFailureCard.querySelector("textarea")!;
    expect(afterFailureTextarea.value).toBe("first draft, plus more typed while the send is in flight");

    afterFailureTextarea.dispatchEvent(new Event("blur"));
    await vi.waitFor(() => expect(upsertCalls.length).toBeGreaterThan(1));

    expect(upsertCalls.at(-1)!.id).toBe(persisted.id); // persisted under the SERVER id, not the stale provisional one
    expect(upsertCalls.at(-1)!.body).toBe("first draft, plus more typed while the send is in flight");
  });

  it("shows the live typed text, not a reverted persisted body, immediately after a held send is issued (post-swap refresh)", async () => {
    const { bridge, controller, diffViewFake } = setup();

    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const provisionalDraft = firstAnchoredComment(diffViewFake);
    const card = controller.hooks.renderCard({ comment: provisionalDraft, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "typed before send";
    textarea.dispatchEvent(new Event("input"));

    bridge.holdNextSend = true; // holds reviewCommentsSend open — the upsert (the swap) has already resolved by then
    const sendBtn = [...card.querySelectorAll("button")].find((b) => b.textContent === `Send to ${AGENT.label}`)!;
    sendBtn.click();

    await vi.waitFor(() => expect(bridge.releaseHeldSend).toBeDefined());

    // The swap's refresh must have run BEFORE this point (it runs before the `reviewCommentsSend`
    // await, not after) — so the latest render already reflects the server-assigned id and the live
    // text, not a reverted body.
    const persisted = firstAnchoredComment(diffViewFake);
    expect(persisted.id).not.toBe(provisionalDraft.id);
    const rebuiltCard = controller.hooks.renderCard({ comment: persisted, position: { lineNumber: 1, outdated: false } });
    const rebuiltTextarea = rebuiltCard.querySelector("textarea")!;
    expect(rebuiltTextarea.value).toBe("typed before send"); // not reverted, not blank

    bridge.releaseHeldSend?.();
    await vi.waitFor(() => expect(bridge.sendCalls).toHaveLength(1));
  });
});

// This file never tears a `CommentsController` instance down (no `dispose`/`removeEventListener`
// exists on the class), so every controller created above also has live `mousedown`/`mouseup`/
// `blur` capture listeners on `window` that fire when the tests below dispatch those events. That's
// safe: every assertion below reads only its own `bridge`/`controller`/`diffViewFake` locals, so a
// stale prior controller reacting to a dispatched event only touches its own now-irrelevant fake.
describe("CommentsController — round-15: press-scoped rebuild gate", () => {
  function setup() {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    return { bridge, controller, diffViewFake };
  }

  /** Types a body into a freshly-opened draft's card, connects the card to `document` (existing
   *  round-2 Fix 2 tests do the same — jsdom only tracks `document.activeElement`/live nodes for a
   *  connected element), and returns the card, its textarea, and its Send button. */
  function openDraftWithText(controller: CommentsController, diffViewFake: ReturnType<typeof makeFakeDiffView>, body: string) {
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const draft = firstAnchoredComment(diffViewFake);
    const card = controller.hooks.renderCard({ comment: draft, position: { lineNumber: 1, outdated: false } });
    document.body.appendChild(card);
    const textarea = card.querySelector("textarea")!;
    textarea.value = body;
    textarea.dispatchEvent(new Event("input"));
    const sendBtn = [...card.querySelectorAll("button")].find((b) => b.textContent === `Send to ${AGENT.label}`)!;
    return { card, textarea, sendBtn };
  }

  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("a blur-triggered persist that resolves mid-press does not rebuild until mouseup, and the pressed Send button still fires", async () => {
    const { bridge, controller, diffViewFake } = setup();
    const { card, textarea, sendBtn } = openDraftWithText(controller, diffViewFake, "Needs a null check");
    const callsBeforeGesture = diffViewFake.setComments.mock.calls.length;

    bridge.holdNextUpsert = true;
    window.dispatchEvent(new Event("mousedown")); // press starts: the rebuild gate opens
    textarea.dispatchEvent(new Event("blur")); // blur-before-click: starts the held persist mid-press

    await vi.waitFor(() => expect(bridge.releaseHeldUpsert).toBeDefined());
    bridge.releaseHeldUpsert?.(); // the persist resolves WHILE the press is still open
    await vi.waitFor(() => expect(bridge.drafts.size).toBe(1)); // persist has landed server-side
    // Let `doPersistBody`'s own continuation (which calls `refresh()`) actually run. This is pure
    // microtask work and is unaffected by fake timers (those only fake macrotasks like `setTimeout`).
    await Promise.resolve();
    await Promise.resolve();

    // The rebuild was gated: no additional `setComments` call happened even though the persist
    // that would normally trigger one already landed. (A `document.contains(sendBtn)` check would
    // add no signal here: this harness's `diffViewFake.setComments` is a plain `vi.fn()` mock, not a
    // real `@pierre/diffs` that actually tears down and replaces DOM nodes, so the card is never
    // actually detached in this test regardless of gating — the call-count gate above is what
    // exercises the actual mechanism under test.)
    expect(diffViewFake.setComments.mock.calls.length).toBe(callsBeforeGesture);

    window.dispatchEvent(new Event("mouseup")); // press ends: schedules the deferred flush's setTimeout(0)
    sendBtn.click(); // click fires on the SAME node the user pressed, proving nothing detached it

    await vi.waitFor(() => expect(bridge.sendCalls).toHaveLength(1));
    expect(bridge.sendCalls[0]!.text).toContain("Needs a null check");

    // The rebuild is no longer stuck: by now — via `sendOne`'s own unrelated, ungated refresh (see
    // the class doc comment) and/or the deferred flush `mouseup` scheduled — the diff view has been
    // rebuilt again, so the UI is not left permanently stale behind the gate. `vi.waitFor` advances
    // fake timers as needed while polling, so this also exercises the deferred flush's own
    // `setTimeout(0)` if `sendOne`'s refresh alone hasn't already satisfied it.
    await vi.waitFor(() => expect(diffViewFake.setComments.mock.calls.length).toBeGreaterThan(callsBeforeGesture));

    card.remove();
  });

  it("with no mouse press in progress, a blur's persist rebuilds immediately, needing no mouseup", async () => {
    const { bridge, controller, diffViewFake } = setup();
    const { card, textarea } = openDraftWithText(controller, diffViewFake, "Keyboard focus-away, no mouse press");
    const callsBeforeBlur = diffViewFake.setComments.mock.calls.length;

    bridge.holdNextUpsert = true;
    textarea.dispatchEvent(new Event("blur")); // no mousedown preceded this — nothing gates the rebuild
    await vi.waitFor(() => expect(bridge.releaseHeldUpsert).toBeDefined());
    bridge.releaseHeldUpsert?.();

    await vi.waitFor(() => expect(diffViewFake.setComments.mock.calls.length).toBeGreaterThan(callsBeforeBlur));

    card.remove();
  });

  it("a press abandoned without a visible mouseup (e.g. an app switch) still flushes, via window blur", async () => {
    const { bridge, controller, diffViewFake } = setup();
    const { card, textarea } = openDraftWithText(controller, diffViewFake, "Abandoned press");
    const callsBeforeGesture = diffViewFake.setComments.mock.calls.length;

    bridge.holdNextUpsert = true;
    window.dispatchEvent(new Event("mousedown"));
    textarea.dispatchEvent(new Event("blur")); // starts the held persist mid-press

    await vi.waitFor(() => expect(bridge.releaseHeldUpsert).toBeDefined());
    bridge.releaseHeldUpsert?.();
    await vi.waitFor(() => expect(bridge.drafts.size).toBe(1));
    await Promise.resolve();
    await Promise.resolve();

    // Still gated: no visible `mouseup` has happened yet.
    expect(diffViewFake.setComments.mock.calls.length).toBe(callsBeforeGesture);

    window.dispatchEvent(new Event("blur")); // e.g. an app switch mid-press — no `mouseup` ever fires
    await vi.advanceTimersByTimeAsync(0); // flush the deferred setTimeout(0)

    expect(diffViewFake.setComments.mock.calls.length).toBeGreaterThan(callsBeforeGesture);

    card.remove();
  });

  it("keeps a pressed tray remove button alive while a completed patch re-anchors its comment", async () => {
    const { bridge, controller, diffViewFake } = setup();
    const persisted = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "Remove this review note",
    });
    await controller.loadInitial();
    const container = document.createElement("div");
    document.body.appendChild(container);
    controller.mount(container);
    const row = container.querySelector<HTMLElement>(".comment-tray-row")!;
    const removeButton = row.querySelector<HTMLButtonElement>(".comment-tray-remove")!;

    // The user has pressed the row's remove button. A completed patch arriving during this
    // gesture must retain the pressed DOM node until the click is delivered.
    removeButton.dispatchEvent(new MouseEvent("mousedown", { bubbles: true }));
    controller.updateFile(SHIFTED_FILE);
    expect(container.querySelector(".comment-tray-row")).toBe(row);

    window.dispatchEvent(new MouseEvent("mouseup", { bubbles: true }));
    removeButton.click();
    await vi.waitFor(() => expect(bridge.drafts.has(persisted.id)).toBe(false));
    expect(diffViewFake.setComments.mock.calls.length).toBeGreaterThan(2);
  });
});

describe("CommentsController — round-18 Fix 1 (P2): a failed blur persist stays eligible for retry", () => {
  function setup() {
    const bridge = makeBridge();
    const onToolbarStateChange = vi.fn<(state: CommentsToolbarState) => void>();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    const container = document.createElement("div");
    controller.mount(container);
    return { bridge, controller, diffViewFake, container, onToolbarStateChange };
  }

  it("refocusing and re-blurring the SAME text after a failed persist retries it, instead of silently no-op'ing", async () => {
    const { bridge, controller, diffViewFake, container } = setup();
    const created = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "original",
    });
    await controller.loadInitial();

    const card = controller.hooks.renderCard({ comment: created, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "edited text";
    textarea.dispatchEvent(new Event("input"));

    // A transport-shaped rejection (not a typed `SpacesBridgeError`) — isolates this test to Fix 1's
    // rollback mechanism, keeping it clear of Fix 2's reconcile (which must NOT fire here — see the
    // control test below).
    const upsertSpy = vi.spyOn(bridge, "reviewCommentUpsert").mockImplementationOnce(() => Promise.reject(new Error("network hiccup")));

    textarea.dispatchEvent(new Event("blur"));

    await vi.waitFor(() => {
      const banner = container.querySelector(".banner") as HTMLElement;
      expect(banner.style.display).toBe("flex");
    });
    expect(upsertSpy).toHaveBeenCalledTimes(1);
    // The row survives — an untyped rejection must not trigger Fix 2's reconcile/removal.
    const renderedAfterFailure = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[])[0]!.comment;
    expect(renderedAfterFailure.body).toBe("original");

    // Refocus + re-blur with the SAME (still-unsaved) text. jsdom doesn't require a literal focus
    // cycle to prove the retry — dispatching `blur` again is enough, matching this file's other
    // blur-driven tests. Without Fix 1, `lastSavedBody` would have already been eagerly advanced to
    // "edited text" by the first (failed) blur, so this second blur's `body === lastSavedBody` check
    // would silently no-op — no second RPC, forever.
    textarea.dispatchEvent(new Event("blur"));

    await vi.waitFor(() => expect(upsertSpy).toHaveBeenCalledTimes(2));
    await vi.waitFor(() => expect(bridge.drafts.get(created.id)?.body).toBe("edited text"));
    const renderedAfterRetry = (diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[])[0]!.comment;
    expect(renderedAfterRetry.body).toBe("edited text");
  });

  it("re-blurring the SAME text while the first persist is still in flight does not register a second upsert", async () => {
    const { bridge, controller } = setup();
    const created = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "original",
    });
    await controller.loadInitial();

    const card = controller.hooks.renderCard({ comment: created, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "edited text";
    textarea.dispatchEvent(new Event("input"));

    // `created` above already issued one upsert call of its own — count from here.
    const upsertCallsBeforeBlur = bridge.upsertCallCount;
    bridge.holdNextUpsert = true;
    textarea.dispatchEvent(new Event("blur"));
    await vi.waitFor(() => expect(bridge.releaseHeldUpsert).toBeDefined());
    expect(bridge.upsertCallCount).toBe(upsertCallsBeforeBlur + 1);

    // Re-blur the SAME text while the first persist is still parked — the eager-advance in Fix 1's
    // rollback logic must still suppress this as a duplicate in-flight persist.
    textarea.dispatchEvent(new Event("blur"));
    expect(bridge.upsertCallCount).toBe(upsertCallsBeforeBlur + 1);

    bridge.releaseHeldUpsert?.();
    await vi.waitFor(() => expect(bridge.drafts.get(created.id)?.body).toBe("edited text"));
    expect(bridge.upsertCallCount).toBe(upsertCallsBeforeBlur + 1);
  });
});

describe("CommentsController — round-18 Fix 2 (P2): a typed upsert rejection reconciles the mirror", () => {
  function setup() {
    const bridge = makeBridge();
    const onToolbarStateChange = vi.fn<(state: CommentsToolbarState) => void>();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    const container = document.createElement("div");
    controller.mount(container);
    return { bridge, controller, diffViewFake, container, onToolbarStateChange };
  }

  it("a typed (notFound) upsert rejection removes the stale row from the rendered mirror and the toolbar count", async () => {
    const { bridge, controller, diffViewFake, container, onToolbarStateChange } = setup();
    const created = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "original",
    });
    await controller.loadInitial();

    const card = controller.hooks.renderCard({ comment: created, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "edited text";
    textarea.dispatchEvent(new Event("input"));

    // Simulates another surface having already sent/deleted this draft server-side since the last
    // list — the same setup round-16 Fix 2's tests use. `reviewCommentList` (used by the reconcile's
    // relist) now returns `[]`.
    bridge.drafts.delete(created.id);
    bridge.failNextUpsert = new SpacesBridgeError("notFound", "already sent");
    textarea.dispatchEvent(new Event("blur"));

    await vi.waitFor(() => {
      const banner = container.querySelector(".banner") as HTMLElement;
      expect(banner.style.display).toBe("flex");
    });

    await vi.waitFor(() => {
      const rendered = diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[];
      expect(rendered.some((ac) => ac.comment.id === created.id)).toBe(false);
    });
    // `refresh()` (called from the catch) pushes toolbar state as part of its pipeline.
    expect(lastToolbarState(onToolbarStateChange).draftCount).toBe(0);
  });

  it("a transport-shaped (untyped) upsert rejection does not relist, and the row survives", async () => {
    const { bridge, controller, diffViewFake } = setup();
    const created = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "original",
    });
    await controller.loadInitial();

    const card = controller.hooks.renderCard({ comment: created, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "edited text";
    textarea.dispatchEvent(new Event("input"));

    const listSpy = vi.spyOn(bridge, "reviewCommentList");
    vi.spyOn(bridge, "reviewCommentUpsert").mockImplementationOnce(() => Promise.reject(new Error("network hiccup")));
    textarea.dispatchEvent(new Event("blur"));

    await vi.waitFor(() => {
      const rendered = diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[];
      expect(rendered.some((ac) => ac.comment.id === created.id)).toBe(true);
    });
    expect(listSpy).not.toHaveBeenCalled();
  });
});

describe("CommentsController — round-18 Fix 3 (P2): toolbar batch count reflects live text", () => {
  function setup() {
    const bridge = makeBridge();
    const onToolbarStateChange = vi.fn<(state: CommentsToolbarState) => void>();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    return { bridge, controller, diffViewFake, onToolbarStateChange };
  }

  it("typing into a sole provisional draft's card counts it before any blur, and emptying it drops the count back to 0", async () => {
    const { controller, diffViewFake, onToolbarStateChange } = setup();
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const draft = firstAnchoredComment(diffViewFake);
    const card = controller.hooks.renderCard({ comment: draft, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;

    textarea.value = "a comment, not yet blurred";
    textarea.dispatchEvent(new Event("input"));
    expect(lastToolbarState(onToolbarStateChange).draftCount).toBe(1);

    textarea.value = "";
    textarea.dispatchEvent(new Event("input"));
    expect(lastToolbarState(onToolbarStateChange).draftCount).toBe(0);
  });
});

describe("CommentsController — round-19 Fix 2 (P2): batch tray membership and excerpts track live text", () => {
  function setup() {
    const bridge = makeBridge();
    const onToolbarStateChange = vi.fn<(state: CommentsToolbarState) => void>();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    const container = document.createElement("div");
    controller.mount(container); // mounts the (persistent) tray element the tests query below
    return { bridge, controller, diffViewFake, container, onToolbarStateChange };
  }

  it("a live-only provisional (typed, never blurred) appears in the open tray, agreeing with the toolbar's live draftCount", () => {
    const { controller, diffViewFake, container, onToolbarStateChange } = setup();
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const draft = firstAnchoredComment(diffViewFake);
    const card = controller.hooks.renderCard({ comment: draft, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;

    // Before typing, an empty provisional draft has no sendable body — the tray is empty, matching
    // the toolbar's own count.
    expect(container.querySelectorAll(".comment-tray-row")).toHaveLength(0);
    expect(lastToolbarState(onToolbarStateChange).draftCount).toBe(0);

    textarea.value = "restored text";
    textarea.dispatchEvent(new Event("input")); // no blur — this draft has never round-tripped

    expect(lastToolbarState(onToolbarStateChange).draftCount).toBe(1);
    const rows = container.querySelectorAll(".comment-tray-row");
    expect(rows).toHaveLength(1); // agrees with the toolbar count above
    expect(container.querySelector(".comment-tray-excerpt")!.textContent).toBe("restored text");
  });

  it("excerpt tracks live edits: a persisted draft's tray excerpt reflects unsaved typing, not the stale saved body", async () => {
    const { bridge, controller, container } = setup();
    const persisted = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "old",
    });
    await controller.loadInitial();

    expect(container.querySelector(".comment-tray-excerpt")!.textContent).toBe("old"); // the listed body, pre-edit

    const card = controller.hooks.renderCard({ comment: persisted, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    textarea.value = "new";
    textarea.dispatchEvent(new Event("input")); // no blur — the excerpt must not wait for a commit

    expect(container.querySelector(".comment-tray-excerpt")!.textContent).toBe("new");
  });

  it("the open tray re-renders on every keystroke, with no blur dispatched at any point", () => {
    const { controller, diffViewFake, container } = setup();
    controller.hooks.onRequestNewComment({ filePath: "src/foo.ts", side: "new", lineNumber: 1, lineText: "const x = compute();" });
    const draft = firstAnchoredComment(diffViewFake);
    const card = controller.hooks.renderCard({ comment: draft, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;

    expect(container.querySelectorAll(".comment-tray-row")).toHaveLength(0);

    textarea.value = "f";
    textarea.dispatchEvent(new Event("input"));
    expect(container.querySelectorAll(".comment-tray-row")).toHaveLength(1);
    expect(container.querySelector(".comment-tray-excerpt")!.textContent).toBe("f");

    textarea.value = "fi";
    textarea.dispatchEvent(new Event("input"));
    expect(container.querySelector(".comment-tray-excerpt")!.textContent).toBe("fi");

    textarea.value = "";
    textarea.dispatchEvent(new Event("input"));
    expect(container.querySelectorAll(".comment-tray-row")).toHaveLength(0); // emptied back out, still no blur
  });
});

describe("CommentsController — round-23 Fix: divergent-commit loop revalidates each entry per iteration", () => {
  // The plain "stays divergent the whole time, gets committed then sent" path is already pinned by
  // the round-19 Fix 1 (P1) tests above and by Fix 1 (P2)'s "sendBatch: commits a still-focused
  // card's live-divergent text..." test — no separate control test is added here. In both tests
  // below, draft A stays divergent across the whole held window and is still committed and sent,
  // which re-proves that path is unchanged by this fix's added per-entry revalidation.
  function setup() {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    return { bridge, controller, diffViewFake };
  }

  it("a delete still in flight for a LATER divergent entry when the loop reaches it is skipped, not re-upserted — the earlier entry still sends", async () => {
    const { bridge, controller } = setup();
    const a = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "persisted A",
    });
    const b = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "persisted B",
    });
    await controller.loadInitial();

    // Both cards mid-edit: live text ahead of their persisted body, neither has blurred — same shape
    // the round-19 Fix 1 (P1) tests use (a still-focused/hibernation-restored card), just with two
    // cards so the commit loop has a second entry to reach mid-drain. Creation order (A before B)
    // makes A the divergent loop's first entry.
    const cardA = controller.hooks.renderCard({ comment: a, position: { lineNumber: 1, outdated: false } });
    const textareaA = cardA.querySelector("textarea")!;
    textareaA.value = "persisted A plus more";
    textareaA.dispatchEvent(new Event("input"));

    const cardB = controller.hooks.renderCard({ comment: b, position: { lineNumber: 1, outdated: false } });
    const textareaB = cardB.querySelector("textarea")!;
    textareaB.value = "persisted B plus more";
    textareaB.dispatchEvent(new Event("input"));

    bridge.holdNextUpsert = true;
    const sendPromise = controller.sendBatch();
    await vi.waitFor(() => expect(bridge.releaseHeldUpsert).toBeDefined()); // A's commit-persist is in flight

    // While A's commit is still open, delete B through the real click flow (`doDeleteDraft`'s
    // non-provisional arm) and hold ITS RPC open too, so B's delete is still in flight — not yet
    // resolved — at the moment the loop reaches B's entry.
    bridge.holdNextDelete = true;
    const deleteBtnB = [...cardB.querySelectorAll("button")].find((btn) => btn.textContent === "Delete")!;
    deleteBtnB.click();
    await vi.waitFor(() => expect(bridge.releaseHeldDelete).toBeDefined()); // B's delete RPC is in flight

    bridge.releaseHeldUpsert?.(); // A's commit resolves; the loop's next entry is B, whose delete is still pending
    await new Promise((resolve) => setTimeout(resolve, 0)); // flush pending microtasks

    // The loop skipped B (pendingDeleteById still holds it) instead of re-upserting a row the daemon
    // would reject as an unknown explicit id — no fourth upsert call, and the batch has not aborted.
    expect(bridge.upsertCallCount).toBe(3); // A's create, B's create, A's commit — never a fourth for B
    expect(bridge.sendCalls).toHaveLength(0); // not sent yet — the outer drain loop is now awaiting B's delete

    bridge.releaseHeldDelete?.();
    await sendPromise;

    expect(bridge.upsertCallCount).toBe(3); // still no upsert was ever attempted for B
    expect(bridge.sendCalls).toHaveLength(1);
    expect(bridge.sendCalls[0]!.text).toContain("persisted A plus more");
    expect(bridge.sendCalls[0]!.comments.map((c) => c.id)).toEqual([a.id]); // B excluded, not aborting the batch
    expect(bridge.drafts.has(a.id)).toBe(false); // A sent, archived server-side
    expect(bridge.drafts.has(b.id)).toBe(false); // B deleted, not resurrected
  });

  it("a live text emptied for a LATER divergent entry while an earlier entry's commit is held is skipped, not upserted with a blank body", async () => {
    const { bridge, controller } = setup();
    const a = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "persisted A",
    });
    const b = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "persisted B",
    });
    await controller.loadInitial();

    const cardA = controller.hooks.renderCard({ comment: a, position: { lineNumber: 1, outdated: false } });
    const textareaA = cardA.querySelector("textarea")!;
    textareaA.value = "persisted A plus more";
    textareaA.dispatchEvent(new Event("input"));

    const cardB = controller.hooks.renderCard({ comment: b, position: { lineNumber: 1, outdated: false } });
    const textareaB = cardB.querySelector("textarea")!;
    textareaB.value = "persisted B plus more";
    textareaB.dispatchEvent(new Event("input"));

    bridge.holdNextUpsert = true;
    const sendPromise = controller.sendBatch();
    await vi.waitFor(() => expect(bridge.releaseHeldUpsert).toBeDefined()); // A's commit-persist is in flight

    // While A's commit is still open, empty B's textarea (typing, no blur) — the same no-blur input
    // path the tray-liveness tests above use — so B is no longer divergent (blank) by the time the
    // loop reaches its entry.
    textareaB.value = "";
    textareaB.dispatchEvent(new Event("input"));

    bridge.releaseHeldUpsert?.();
    await sendPromise;

    // No upsert was ever attempted for B's now-blank body — the daemon rejects a blank upsert
    // `invalidArgument`, which would otherwise have aborted the whole batch.
    expect(bridge.upsertCallCount).toBe(3); // A's create, B's create, A's commit only
    expect(bridge.sendCalls).toHaveLength(1);
    expect(bridge.sendCalls[0]!.text).toContain("persisted A plus more");
    expect(bridge.sendCalls[0]!.comments.map((c) => c.id)).toEqual([a.id]); // B excluded, not aborting the batch
    expect(bridge.drafts.has(a.id)).toBe(false); // A sent, archived server-side
    expect(bridge.drafts.get(b.id)?.body).toBe("persisted B"); // B's server row untouched — never upserted
  });
});

describe("CommentsController — round-24 Fix 1 (P1): doSendOne recomputes the body at execution time, not the click-time snapshot", () => {
  function setup() {
    const bridge = makeBridge();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange: vi.fn() });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    return { bridge, controller, diffViewFake };
  }

  /** Seeds two already-persisted drafts at the same anchor and loads them into the controller —
   *  mirrors the two-card seeding pattern used by the sendBatch commit-loop tests above. */
  async function seedTwoCards(bridge: ReturnType<typeof makeBridge>, controller: CommentsController) {
    const a = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "persisted A",
    });
    const b = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "v1",
    });
    await controller.loadInitial();
    return { a, b };
  }

  /** Clicks A's Send button with its own send RPC held open, so A occupies `sendInFlight` for the
   *  rest of the test. Returns once `releaseHeldSend` is available. B's own Send click (queued
   *  behind A via the `sendInFlight` wait) must happen AFTER this, at each test's click-time body. */
  async function holdCardASend(bridge: ReturnType<typeof makeBridge>, cardA: HTMLElement) {
    bridge.holdNextSend = true;
    const sendBtnA = [...cardA.querySelectorAll("button")].find((b) => b.textContent === `Send to ${AGENT.label}`)!;
    sendBtnA.click(); // A's fast path (draft.body === body): no upsert, straight to the held send
    await vi.waitFor(() => expect(bridge.releaseHeldSend).toBeDefined());
  }

  it("blurred-newer: a card queued behind another card's in-flight send delivers its blur-persisted body, not the stale click-time snapshot", async () => {
    const { bridge, controller, diffViewFake } = setup();
    const { a, b } = await seedTwoCards(bridge, controller);
    const cardA = controller.hooks.renderCard({ comment: a, position: { lineNumber: 1, outdated: false } });
    const cardB = controller.hooks.renderCard({ comment: b, position: { lineNumber: 1, outdated: false } });
    const textareaB = cardB.querySelector("textarea")!;

    await holdCardASend(bridge, cardA);

    const sendBtnB = [...cardB.querySelectorAll("button")].find((btn) => btn.textContent === `Send to ${AGENT.label}`)!;
    sendBtnB.click(); // captures B's click-time body, "v1", then parks behind A's in-flight send

    // While B is queued, a newer body lands server-side via the normal blur-persist path.
    textareaB.value = "v2";
    textareaB.dispatchEvent(new Event("input"));
    textareaB.dispatchEvent(new Event("blur"));
    await vi.waitFor(() => expect(bridge.drafts.get(b.id)?.body).toBe("v2"));

    // From here on, any additional upsert would mean the fast path (draft.body === effective body)
    // was missed — the send itself must not need to re-upsert what the blur already persisted.
    const upsertSpy = vi.spyOn(bridge, "reviewCommentUpsert");
    bridge.releaseHeldSend?.(); // A's send resolves, freeing `sendInFlight`; B's queued send now runs for real
    await vi.waitFor(() => expect(bridge.sendCalls).toHaveLength(2));

    // Pre-fix, `doSendOne` sent the stale click-time `body` ("v1") verbatim, clobbering the blur's
    // newer "v2" both in the upsert re-check and in the delivered text.
    const sendForB = bridge.sendCalls.find((c) => c.comments.some((entry) => entry.id === b.id))!;
    expect(sendForB.text).toContain("v2");
    expect(sendForB.text).not.toContain("v1");
    expect(upsertSpy).not.toHaveBeenCalled();
    expect(bridge.drafts.has(b.id)).toBe(false); // archived server-side, never left stranded at "v1"
  });

  it("unblurred-newer: a card queued behind another card's in-flight send delivers its live (never-blurred) body, not the stale click-time snapshot", async () => {
    const { bridge, controller, diffViewFake } = setup();
    const { a, b } = await seedTwoCards(bridge, controller);
    const cardA = controller.hooks.renderCard({ comment: a, position: { lineNumber: 1, outdated: false } });
    const cardB = controller.hooks.renderCard({ comment: b, position: { lineNumber: 1, outdated: false } });
    const textareaB = cardB.querySelector("textarea")!;

    await holdCardASend(bridge, cardA);

    const sendBtnB = [...cardB.querySelectorAll("button")].find((btn) => btn.textContent === `Send to ${AGENT.label}`)!;
    sendBtnB.click(); // captures B's click-time body, "v1", then parks behind A's in-flight send

    // While B is queued, type a newer body but never blur it — it lives only in `liveBodies`;
    // `draft.body` stays "v1".
    textareaB.value = "v2";
    textareaB.dispatchEvent(new Event("input"));

    const upsertSpy = vi.spyOn(bridge, "reviewCommentUpsert");
    bridge.releaseHeldSend?.();
    await vi.waitFor(() => expect(bridge.sendCalls).toHaveLength(2));

    // The send itself must commit "v2" through the normal upsert branch (draft.body "v1" !==
    // effective body "v2"), then deliver that same "v2" — never the stale click-time "v1".
    expect(upsertSpy).toHaveBeenCalledTimes(1);
    expect(upsertSpy.mock.calls[0]![0]).toMatchObject({ id: b.id, body: "v2" });
    const sendForB = bridge.sendCalls.find((c) => c.comments.some((entry) => entry.id === b.id))!;
    expect(sendForB.text).toContain("v2");
    expect(sendForB.text).not.toContain("v1");
  });

  it("emptied-during-wait: a card emptied out while queued is discarded via delete, never sent, and does not disturb the in-flight card ahead of it", async () => {
    const { bridge, controller, diffViewFake } = setup();
    const { a, b } = await seedTwoCards(bridge, controller);
    const cardA = controller.hooks.renderCard({ comment: a, position: { lineNumber: 1, outdated: false } });
    const cardB = controller.hooks.renderCard({ comment: b, position: { lineNumber: 1, outdated: false } });
    const textareaB = cardB.querySelector("textarea")!;

    await holdCardASend(bridge, cardA);

    const sendBtnB = [...cardB.querySelectorAll("button")].find((btn) => btn.textContent === `Send to ${AGENT.label}`)!;
    sendBtnB.click(); // captures B's click-time body, "v1", then parks behind A's in-flight send

    // While B is queued, empty its textarea entirely (typed, never blurred).
    textareaB.value = "";
    textareaB.dispatchEvent(new Event("input"));

    bridge.releaseHeldSend?.();
    await vi.waitFor(() => expect(bridge.sendCalls).toHaveLength(1)); // A's own send only, ever

    // Pre-fix, `doSendOne` would have re-sent the stale click-time "v1" body instead of discarding
    // the now-empty card.
    await vi.waitFor(() => expect(bridge.drafts.has(b.id)).toBe(false)); // discarded via delete, not send
    expect(bridge.sendCalls.some((c) => c.comments.some((entry) => entry.id === b.id))).toBe(false);
    expect(bridge.drafts.has(a.id)).toBe(false); // A's own send completed normally, unaffected by B
  });
});

describe("CommentsController — round-24 Fix 2 (P2): doSendOne's pre-send upsert catch reconciles a typed rejection", () => {
  function setup() {
    const bridge = makeBridge();
    const onToolbarStateChange = vi.fn<(state: CommentsToolbarState) => void>();
    const controller = new CommentsController(bridge, [AGENT], { onToolbarStateChange });
    const diffViewFake = makeFakeDiffView();
    controller.attachDiffView(diffViewFake.fake);
    controller.setFiles([FILE]);
    const container = document.createElement("div");
    controller.mount(container);
    return { bridge, controller, diffViewFake, container, onToolbarStateChange };
  }

  it("a typed (notFound) rejection from the send's own re-upsert reconciles the stale row out of the rendered mirror, mirroring doDeleteDraft", async () => {
    const { bridge, controller, diffViewFake, container, onToolbarStateChange } = setup();
    const created = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 1,
      lineText: "const x = compute();",
      body: "original",
    });
    await controller.loadInitial();

    const card = controller.hooks.renderCard({ comment: created, position: { lineNumber: 1, outdated: false } });
    const textarea = card.querySelector("textarea")!;
    // Typed but never blurred: `draft.body` ("original") diverges from the effective body ("edited
    // text"), so `sendOne` must go through the upsert branch rather than the fast path.
    textarea.value = "edited text";
    textarea.dispatchEvent(new Event("input"));

    // Simulates another surface having already sent/deleted this draft server-side since the last
    // list — same setup as round-18 Fix 2's persistBody-catch test, but exercised through Send
    // instead of blur.
    bridge.drafts.delete(created.id);
    bridge.failNextUpsert = new SpacesBridgeError("notFound", "already sent");

    const sendBtn = [...card.querySelectorAll("button")].find((b) => b.textContent === `Send to ${AGENT.label}`)!;
    sendBtn.click();

    await vi.waitFor(() => {
      const banner = container.querySelector(".banner") as HTMLElement;
      expect(banner.style.display).toBe("flex");
    });

    // Pre-fix, `doSendOne`'s upsert catch only called `surfaceError` — the stale row would still be
    // in the rendered mirror and the toolbar count. Fix 2 also reconciles the mirror, exactly like
    // `doDeleteDraft`'s own catch does.
    await vi.waitFor(() => {
      const rendered = diffViewFake.setComments.mock.calls.at(-1)![0] as { comment: SpacesReviewComment }[];
      expect(rendered.some((ac) => ac.comment.id === created.id)).toBe(false);
    });
    expect(lastToolbarState(onToolbarStateChange).draftCount).toBe(0);
    expect(bridge.sendCalls).toHaveLength(0); // rejected before any reviewCommentsSend call
  });
});
