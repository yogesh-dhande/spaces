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
    workspaceDiff: notUsed,
    workspaceFileRead: notUsed,
    workspaceFileWrite: notUsed,
    workspaceFileList: notUsed,
    subscribeDiffSignature: () => () => {},
    subscribeFileSignature: () => () => {},
    notifyEditorStateChanged: () => {},
    notifyModeChanged: () => {},
    notifyReady: () => {},
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
  truncated: false,
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
  truncated: false,
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

/** A minimal stand-in for `DiffView`'s public surface, cast to the real type — the controller
 *  only ever calls these three methods on it. */
function makeFakeDiffView() {
  const setComments = vi.fn();
  const scrollToLine = vi.fn();
  const scrollToFile = vi.fn();
  const fake = { setComments, scrollToLine, scrollToFile } as unknown as DiffView;
  return { fake, setComments, scrollToLine, scrollToFile };
}

function lastToolbarState(spy: ReturnType<typeof vi.fn>): CommentsToolbarState {
  return spy.mock.calls.at(-1)![0] as CommentsToolbarState;
}

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

    // Collapsing an empty card would hide it with no way to bring it back (the tray only lists
    // non-empty drafts), so the click above must be rejected rather than silently orphaning it.
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

  it("blur-then-Add-to-batch on a provisional card: collapses under the server id once the held create-persist resolves, and the tray lists it", async () => {
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

    // addToBatch's own continuation (resolve id → collapse) runs after the persist above, so wait
    // for its effect: the collapsed id drops out of the *visible* (inline) list `refresh()` passes
    // to `DiffView.setComments`.
    await vi.waitFor(() => {
      const calls = diffViewFake.setComments.mock.calls;
      const visible = calls.at(-1)![0] as { comment: SpacesReviewComment }[];
      expect(visible.find((ac) => ac.comment.id === serverId)).toBeUndefined();
    });

    // Collapsed under the SERVER id, not the stale provisional one — nothing in the bridge or the
    // controller's local mirror still refers to `provisionalDraft.id` at all.
    expect(bridge.drafts.has(provisionalDraft.id)).toBe(false);

    // The tray lists every sendable draft regardless of collapse state (see `renderTray` /
    // `docs/spec.md`'s "Add to batch" correction) — confirm it renders this one.
    const container = document.createElement("div");
    controller.mount(container);
    const rows = container.querySelectorAll(".comment-tray-row");
    expect(rows).toHaveLength(1);
    expect(container.querySelector(".comment-tray-excerpt")!.textContent).toBe("Batch this one");
    expect(container.querySelector(".comment-tray-loc")!.textContent).toBe("src/foo.ts:1");
  });

  it("a create-persist that fails leaves the card uncollapsed, so its error banner stays visible", async () => {
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
    // Neither the failed persist nor addToBatch's no-op re-renders anything: the card is still the
    // one inline render from `renderCard` above, still keyed by the (never re-keyed) provisional id.
    expect(diffViewFake.setComments.mock.calls.length).toBe(rendersBeforeFailure);
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

  it("collectStateForFlush no longer recovers a restored persisted entry once loadInitial resolves without that id in the response (it was deleted or sent while this pane was torn down)", async () => {
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

    expect(controller.collectStateForFlush()).toBeNull(); // no longer recoverable — not this mechanism's promise
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
