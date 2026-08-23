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
});
