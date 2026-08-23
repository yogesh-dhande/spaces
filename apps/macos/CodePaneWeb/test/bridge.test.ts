import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createRealBridge } from "../src/bridge/realBridge";
import { createMockBridge } from "../src/bridge/mockBridge";
import { SpacesBridgeError } from "../src/bridge/types";

describe("RealSpacesBridge", () => {
  let postMessage: ReturnType<typeof vi.fn<(message: unknown) => void>>;

  beforeEach(() => {
    postMessage = vi.fn<(message: unknown) => void>();
    window.webkit = { messageHandlers: { spacesBridge: { postMessage } } };
  });

  afterEach(() => {
    delete window.webkit;
    delete window.__spacesBridge;
  });

  it("correlates each call's reply by id, even when replies arrive out of order", async () => {
    const bridge = createRealBridge();

    const first = bridge.workspaceFileRead("a.ts");
    const second = bridge.workspaceFileRead("b.ts");

    expect(postMessage).toHaveBeenCalledTimes(2);
    const firstId = (postMessage.mock.calls[0]![0] as { id: string }).id;
    const secondId = (postMessage.mock.calls[1]![0] as { id: string }).id;
    expect(firstId).not.toBe(secondId);

    // Resolve out of order: second call's reply arrives first.
    window.__spacesBridge!.resolve(secondId, { content: "B", sha256: "sha-b", size: 1 });
    window.__spacesBridge!.resolve(firstId, { content: "A", sha256: "sha-a", size: 1 });

    await expect(second).resolves.toEqual({ content: "B", sha256: "sha-b", size: 1 });
    await expect(first).resolves.toEqual({ content: "A", sha256: "sha-a", size: 1 });
  });

  it("rejects with a SpacesBridgeError carrying the reported code and message", async () => {
    const bridge = createRealBridge();
    const call = bridge.workspaceFileRead("missing.ts");
    const id = (postMessage.mock.calls[0]![0] as { id: string }).id;

    window.__spacesBridge!.reject(id, { code: "notFound", message: "no such file" });

    await expect(call).rejects.toBeInstanceOf(SpacesBridgeError);
    await expect(call).rejects.toMatchObject({ code: "notFound", message: "no such file" });
  });

  it("normalizes an unrecognized error code to internalError rather than passing it through", async () => {
    const bridge = createRealBridge();
    const call = bridge.workspaceFileRead("x.ts");
    const id = (postMessage.mock.calls[0]![0] as { id: string }).id;

    window.__spacesBridge!.reject(id, { code: "somethingTheHostInventedLater", message: "boom" });

    await expect(call).rejects.toMatchObject({ code: "internalError", message: "boom" });
  });

  it("drops a reply for an id it no longer tracks instead of throwing", () => {
    createRealBridge();
    expect(() => window.__spacesBridge!.resolve("never-requested", {})).not.toThrow();
  });

  it("rejects immediately with 'unavailable' when the WKWebView message handler is not installed", async () => {
    delete window.webkit;
    const bridge = createRealBridge();
    await expect(bridge.workspaceFileRead("a.ts")).rejects.toMatchObject({ code: "unavailable" });
  });

  it("sends the ready lifecycle notification with no id", () => {
    const bridge = createRealBridge();
    bridge.notifyReady();
    expect(postMessage).toHaveBeenCalledWith({ method: "ready" });
  });

  it("posts reviewCommentList with an id and no params, and resolves with the reply", async () => {
    const bridge = createRealBridge();
    const call = bridge.reviewCommentList();
    const [msg] = postMessage.mock.calls[0]! as [{ id: string; method: string; params: unknown }];
    expect(msg.method).toBe("reviewCommentList");
    expect(msg.params).toEqual({});

    const comment = {
      id: "c1",
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 3,
      lineText: "x",
      body: "y",
      createdAt: "t1",
      revision: 0,
    };
    window.__spacesBridge!.resolve(msg.id, [comment]);
    await expect(call).resolves.toEqual([comment]);
  });

  it("posts reviewCommentUpsert with the exact input as params", async () => {
    const bridge = createRealBridge();
    const input = { filePath: "src/foo.ts", side: "new" as const, lineNumber: 3, lineText: "x", body: "" };
    bridge.reviewCommentUpsert(input);
    const [msg] = postMessage.mock.calls[0]! as [{ id: string; method: string; params: unknown }];
    expect(msg.method).toBe("reviewCommentUpsert");
    expect(msg.params).toEqual(input);
  });

  it("posts reviewCommentDelete with { id }", async () => {
    const bridge = createRealBridge();
    const call = bridge.reviewCommentDelete("c1");
    const [msg] = postMessage.mock.calls[0]! as [{ id: string; method: string; params: unknown }];
    expect(msg.method).toBe("reviewCommentDelete");
    expect(msg.params).toEqual({ id: "c1" });
    window.__spacesBridge!.resolve(msg.id, { ok: true });
    await expect(call).resolves.toBeUndefined();
  });

  it("posts reviewCommentsSend with { sessionId, text, comments }", async () => {
    const bridge = createRealBridge();
    const comments = [
      { id: "c1", revision: 0 },
      { id: "c2", revision: 2 },
    ];
    const call = bridge.reviewCommentsSend("s1", "Code review comments:\n\n...", comments);
    const [msg] = postMessage.mock.calls[0]! as [{ id: string; method: string; params: unknown }];
    expect(msg.method).toBe("reviewCommentsSend");
    expect(msg.params).toEqual({ sessionId: "s1", text: "Code review comments:\n\n...", comments });
    window.__spacesBridge!.resolve(msg.id, { ok: true });
    await expect(call).resolves.toBeUndefined();
  });

  it("rejects reviewCommentsSend with the reported error, e.g. an unrunning session", async () => {
    const bridge = createRealBridge();
    const call = bridge.reviewCommentsSend("s1", "text", [{ id: "c1", revision: 0 }]);
    const [msg] = postMessage.mock.calls[0]! as [{ id: string; method: string; params: unknown }];
    window.__spacesBridge!.reject(msg.id, { code: "invalidArgument", message: "session s1 is not running" });
    await expect(call).rejects.toMatchObject({ code: "invalidArgument", message: "session s1 is not running" });
  });
});

describe("MockSpacesBridge", () => {
  it("rejects workspaceFileRead for a path outside the fixture set with a notFound SpacesBridgeError", async () => {
    const bridge = createMockBridge();
    await expect(bridge.workspaceFileRead("does/not/exist.ts")).rejects.toBeInstanceOf(SpacesBridgeError);
    await expect(bridge.workspaceFileRead("does/not/exist.ts")).rejects.toMatchObject({ code: "notFound" });
  });

  it("returns a conflict shape (not a throw) when the write's baseSHA256 is stale", async () => {
    const bridge = createMockBridge();
    const read = await bridge.workspaceFileRead("notes/TODO.md");

    const result = await bridge.workspaceFileWrite("notes/TODO.md", "# TODO\n\n- changed elsewhere\n", {
      baseSHA256: "stale-hash-not-matching-current",
    });

    expect(result).toMatchObject({ conflict: true });
    expect((result as { currentSHA256: string }).currentSHA256).toBe(read.sha256);
  });

  it("accepts a write whose baseSHA256 matches the current content, and the next read reflects it", async () => {
    const bridge = createMockBridge();
    const read = await bridge.workspaceFileRead("notes/TODO.md");

    const result = await bridge.workspaceFileWrite("notes/TODO.md", "# TODO\n\n- done\n", {
      baseSHA256: read.sha256,
    });
    // `ok: true` carries the write's own sha256 (round-4 Fix 1: adopted directly as the next CAS
    // baseline, with no re-read) rather than a bare `{ ok: true }`.
    expect(result).toEqual({ ok: true, sha256: expect.any(String) });

    const reread = await bridge.workspaceFileRead("notes/TODO.md");
    expect(reread.content).toBe("# TODO\n\n- done\n");
    expect(reread.sha256).not.toBe(read.sha256);
  });

  it("delivers a signature-change event to every subscribed listener, and stops after unsubscribe", () => {
    const bridge = createMockBridge();
    const a = vi.fn();
    const b = vi.fn();
    const unsubA = bridge.subscribeDiffSignature({ kind: "uncommitted" }, a);
    bridge.subscribeDiffSignature({ kind: "uncommitted" }, b);

    bridge.simulateSignatureChange();
    expect(a).toHaveBeenCalledTimes(1);
    expect(b).toHaveBeenCalledTimes(1);
    const firstSignature = (a.mock.calls[0]![0] as { scopeSignature: string }).scopeSignature;

    unsubA();
    bridge.simulateSignatureChange();
    expect(a).toHaveBeenCalledTimes(1); // no further calls after unsubscribe
    expect(b).toHaveBeenCalledTimes(2);
    const secondSignature = (b.mock.calls[1]![0] as { scopeSignature: string }).scopeSignature;
    expect(secondSignature).not.toBe(firstSignature); // each change carries a distinct signature
  });

  it("reviewCommentUpsert creates a draft (no id) and reviewCommentList returns it", async () => {
    const bridge = createMockBridge();
    const created = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 3,
      lineText: "const x = 1;",
      body: "",
    });
    expect(created.id).toEqual(expect.any(String));
    expect(created.body).toBe("");

    const drafts = await bridge.reviewCommentList();
    expect(drafts).toEqual([created]);
  });

  it("reviewCommentUpsert with an id updates the existing draft in place", async () => {
    const bridge = createMockBridge();
    const created = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 3,
      lineText: "const x = 1;",
      body: "",
    });
    const updated = await bridge.reviewCommentUpsert({ ...created, body: "Why?" });
    expect(updated.id).toBe(created.id);
    expect(updated.body).toBe("Why?");

    const drafts = await bridge.reviewCommentList();
    expect(drafts).toEqual([updated]);
  });

  it("reviewCommentUpsert rejects notFound for an id with no matching draft", async () => {
    const bridge = createMockBridge();
    await expect(
      bridge.reviewCommentUpsert({
        id: "does-not-exist",
        filePath: "src/foo.ts",
        side: "new",
        lineNumber: 3,
        lineText: "x",
        body: "y",
      }),
    ).rejects.toMatchObject({ code: "notFound" });
  });

  it("reviewCommentDelete removes a draft; a second delete rejects notFound", async () => {
    const bridge = createMockBridge();
    const created = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 3,
      lineText: "x",
      body: "y",
    });
    await bridge.reviewCommentDelete(created.id);
    await expect(bridge.reviewCommentList()).resolves.toEqual([]);
    await expect(bridge.reviewCommentDelete(created.id)).rejects.toMatchObject({ code: "notFound" });
  });

  it("reviewCommentsSend rejects invalidArgument for an empty comments list", async () => {
    const bridge = createMockBridge();
    await expect(bridge.reviewCommentsSend("s1", "text", [])).rejects.toMatchObject({ code: "invalidArgument" });
  });

  it("reviewCommentsSend is atomic: a rejection for one unknown id leaves every named draft untouched", async () => {
    const bridge = createMockBridge();
    const c1 = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 3,
      lineText: "x",
      body: "keep me",
    });

    await expect(
      bridge.reviewCommentsSend("s1", "text", [
        { id: c1.id, revision: c1.revision },
        { id: "unknown-id", revision: 0 },
      ]),
    ).rejects.toMatchObject({ code: "notFound" });

    // Both-or-neither: c1 must still be a draft, not silently removed by the partial attempt.
    const drafts = await bridge.reviewCommentList();
    expect(drafts).toEqual([c1]);
  });

  it("reviewCommentsSend rejects conflict for a stale revision and leaves the draft untouched", async () => {
    const bridge = createMockBridge();
    const c1 = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 3,
      lineText: "x",
      body: "keep me",
    });

    await expect(
      bridge.reviewCommentsSend("s1", "text", [{ id: c1.id, revision: c1.revision + 1 }]),
    ).rejects.toMatchObject({ code: "conflict" });

    const drafts = await bridge.reviewCommentList();
    expect(drafts).toEqual([c1]);
  });

  it("reviewCommentsSend removes every named draft on success", async () => {
    const bridge = createMockBridge();
    const c1 = await bridge.reviewCommentUpsert({
      filePath: "src/foo.ts",
      side: "new",
      lineNumber: 3,
      lineText: "x",
      body: "one",
    });
    const c2 = await bridge.reviewCommentUpsert({
      filePath: "src/bar.ts",
      side: "old",
      lineNumber: 7,
      lineText: "y",
      body: "two",
    });

    await bridge.reviewCommentsSend("s1", "Code review comments:\n\n...", [
      { id: c1.id, revision: c1.revision },
      { id: c2.id, revision: c2.revision },
    ]);

    await expect(bridge.reviewCommentList()).resolves.toEqual([]);
  });
});
