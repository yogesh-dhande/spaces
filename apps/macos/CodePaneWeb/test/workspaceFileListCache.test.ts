import { describe, expect, it, vi } from "vitest";
import { WorkspaceFileListResult } from "../src/bridge/types";
import { WorkspaceFileListCache } from "../src/app/workspaceFileListCache";

function makeResult(paths: string[], truncated = false): WorkspaceFileListResult {
  return { paths, truncated };
}

/** A manually-resolved/rejected promise, used to prove in-flight de-duplication: two `get()` calls
 *  issued before the bridge call settles must share one underlying request rather than each firing
 *  their own (a plain `mockResolvedValue` would resolve synchronously-ish and couldn't distinguish
 *  "shared" from "two calls that happened to both resolve"). */
function deferred<T>(): { promise: Promise<T>; resolve: (value: T) => void; reject: (error: unknown) => void } {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

describe("WorkspaceFileListCache", () => {
  it("dedupes concurrent get() calls before the first fetch resolves into one bridge call", async () => {
    const { promise, resolve } = deferred<WorkspaceFileListResult>();
    const bridge = { workspaceFileList: vi.fn().mockReturnValue(promise) };
    const cache = new WorkspaceFileListCache(bridge);

    const first = cache.get();
    const second = cache.get();
    expect(bridge.workspaceFileList).toHaveBeenCalledTimes(1);

    resolve(makeResult(["a.ts"]));
    await expect(first).resolves.toEqual(makeResult(["a.ts"]));
    await expect(second).resolves.toEqual(makeResult(["a.ts"]));
    expect(bridge.workspaceFileList).toHaveBeenCalledTimes(1);
  });

  it("returns the cached result without refetching after a successful resolution", async () => {
    const bridge = { workspaceFileList: vi.fn().mockResolvedValue(makeResult(["a.ts"])) };
    const cache = new WorkspaceFileListCache(bridge);

    await cache.get();
    const second = await cache.get();

    expect(second).toEqual(makeResult(["a.ts"]));
    expect(bridge.workspaceFileList).toHaveBeenCalledTimes(1);
  });

  it("does not cache a rejected fetch — the next get() call retries", async () => {
    const bridge = vi.fn();
    const cacheBridge = { workspaceFileList: bridge };
    bridge.mockRejectedValueOnce(new Error("boom"));
    bridge.mockResolvedValueOnce(makeResult(["a.ts"]));
    const cache = new WorkspaceFileListCache(cacheBridge);

    await expect(cache.get()).rejects.toThrow("boom");
    expect(bridge).toHaveBeenCalledTimes(1);

    await expect(cache.get()).resolves.toEqual(makeResult(["a.ts"]));
    expect(bridge).toHaveBeenCalledTimes(2);
  });

  it("invalidate() forces a refetch on the next get() even after a prior successful resolution", async () => {
    const bridge = vi.fn();
    const cacheBridge = { workspaceFileList: bridge };
    bridge.mockResolvedValueOnce(makeResult(["a.ts"]));
    bridge.mockResolvedValueOnce(makeResult(["b.ts"]));
    const cache = new WorkspaceFileListCache(cacheBridge);

    await expect(cache.get()).resolves.toEqual(makeResult(["a.ts"]));
    cache.invalidate();
    await expect(cache.get()).resolves.toEqual(makeResult(["b.ts"]));
    expect(bridge).toHaveBeenCalledTimes(2);
  });
});

describe("WorkspaceFileListCache — getFresh()", () => {
  it("with nothing cached yet, behaves like get() — a single fetch, no separate revalidation", async () => {
    const bridge = vi.fn().mockResolvedValue(makeResult(["a.ts"]));
    const cache = new WorkspaceFileListCache({ workspaceFileList: bridge });

    await expect(cache.getFresh()).resolves.toEqual(makeResult(["a.ts"]));
    expect(bridge).toHaveBeenCalledTimes(1);
  });

  it("with a cached value, returns a promise for a background refetch while get() keeps serving the old value", async () => {
    const bridge = vi.fn();
    bridge.mockResolvedValueOnce(makeResult(["a.ts"]));
    const { promise: freshPromise, resolve: resolveFresh } = deferred<WorkspaceFileListResult>();
    bridge.mockReturnValueOnce(freshPromise);
    const cache = new WorkspaceFileListCache({ workspaceFileList: bridge });

    await expect(cache.get()).resolves.toEqual(makeResult(["a.ts"]));

    const fresh = cache.getFresh();
    // The background refetch is in flight, but get() keeps handing back the old cached value —
    // callers that only care about "what's cached right now" aren't blocked on the revalidation.
    await expect(cache.get()).resolves.toEqual(makeResult(["a.ts"]));

    resolveFresh(makeResult(["a.ts", "b.ts"]));
    await expect(fresh).resolves.toEqual(makeResult(["a.ts", "b.ts"]));
    // The refetch's result replaces the cache: a subsequent get() sees the fresh value.
    await expect(cache.get()).resolves.toEqual(makeResult(["a.ts", "b.ts"]));
    expect(bridge).toHaveBeenCalledTimes(2);
  });

  it("dedupes concurrent getFresh() calls into one in-flight background refetch", async () => {
    const bridge = vi.fn();
    bridge.mockResolvedValueOnce(makeResult(["a.ts"]));
    const { promise: freshPromise, resolve: resolveFresh } = deferred<WorkspaceFileListResult>();
    bridge.mockReturnValueOnce(freshPromise);
    const cache = new WorkspaceFileListCache({ workspaceFileList: bridge });
    await cache.get();

    const first = cache.getFresh();
    const second = cache.getFresh();
    expect(bridge).toHaveBeenCalledTimes(2); // 1 for get(), 1 for the shared revalidation

    resolveFresh(makeResult(["a.ts", "b.ts"]));
    await expect(first).resolves.toEqual(makeResult(["a.ts", "b.ts"]));
    await expect(second).resolves.toEqual(makeResult(["a.ts", "b.ts"]));
    expect(bridge).toHaveBeenCalledTimes(2);
  });

  it("a failed background revalidation rejects getFresh()'s promise but keeps the previous cached value", async () => {
    const bridge = vi.fn();
    bridge.mockResolvedValueOnce(makeResult(["a.ts"]));
    bridge.mockRejectedValueOnce(new Error("boom"));
    const cache = new WorkspaceFileListCache({ workspaceFileList: bridge });
    await cache.get();

    await expect(cache.getFresh()).rejects.toThrow("boom");
    // The prior good value is still served — a transient revalidation failure doesn't clobber it.
    await expect(cache.get()).resolves.toEqual(makeResult(["a.ts"]));

    // A later getFresh() call retries rather than latching the failure (mirrors get()'s own
    // not-caching-a-failed-fetch contract).
    bridge.mockResolvedValueOnce(makeResult(["a.ts", "b.ts"]));
    await expect(cache.getFresh()).resolves.toEqual(makeResult(["a.ts", "b.ts"]));
  });
});

describe("WorkspaceFileListCache — invalidate() during an in-flight fetch or revalidation", () => {
  it("getFresh() revalidation in flight, then invalidate(): the old revalidation's resolution does not stop the trailing refetch it schedules from serving fresh data", async () => {
    const bridge = vi.fn();
    bridge.mockResolvedValueOnce(makeResult(["a.ts"]));
    const { promise: staleFresh, resolve: resolveStaleFresh } = deferred<WorkspaceFileListResult>();
    bridge.mockReturnValueOnce(staleFresh);
    bridge.mockResolvedValueOnce(makeResult(["c.ts"]));
    const cache = new WorkspaceFileListCache({ workspaceFileList: bridge });

    await cache.get(); // bridge call 1: a.ts
    const stale = cache.getFresh(); // bridge call 2: revalidation, in flight

    cache.invalidate();
    // invalidate() only records that a trailing refetch is owed — it does not itself add a bridge
    // call while the revalidation above is still in flight.
    expect(bridge).toHaveBeenCalledTimes(2);

    resolveStaleFresh(makeResult(["a.ts"]));
    // The caller still awaiting the stale revalidation gets its own result — only the cache's
    // stored state is obsolete, not the promise callers already hold.
    await expect(stale).resolves.toEqual(makeResult(["a.ts"]));

    // Settling the stale revalidation is what starts the one trailing refetch invalidate()
    // scheduled; get() sees it (already resolved, or still in flight — either way it joins rather
    // than starting a fourth call) instead of the pre-invalidation listing.
    await expect(cache.get()).resolves.toEqual(makeResult(["c.ts"]));
    expect(bridge).toHaveBeenCalledTimes(3);
  });

  it("getFresh() revalidation in flight, invalidate(), then a get() during the same flight: both join the single trailing refetch rather than starting an independent fetch B", async () => {
    const bridge = vi.fn();
    bridge.mockResolvedValueOnce(makeResult(["a.ts"]));
    const { promise: staleFresh, resolve: resolveStaleFresh } = deferred<WorkspaceFileListResult>();
    bridge.mockReturnValueOnce(staleFresh);
    bridge.mockResolvedValueOnce(makeResult(["b.ts"]));
    const cache = new WorkspaceFileListCache({ workspaceFileList: bridge });

    await cache.get(); // bridge call 1: a.ts
    const stale = cache.getFresh(); // bridge call 2: revalidation, in flight

    cache.invalidate();
    const bRequest = cache.get(); // joins the trailing refetch invalidate() already scheduled — no new call
    expect(bridge).toHaveBeenCalledTimes(2);

    resolveStaleFresh(makeResult(["a.ts"]));
    // The caller still awaiting the stale revalidation gets its own result.
    await expect(stale).resolves.toEqual(makeResult(["a.ts"]));
    // Settling the stale revalidation is what starts the one trailing refetch both invalidate()
    // and the get() above coalesced into; bRequest resolves to its result once it lands.
    await expect(bRequest).resolves.toEqual(makeResult(["b.ts"]));
    expect(bridge).toHaveBeenCalledTimes(3);

    await expect(cache.get()).resolves.toEqual(makeResult(["b.ts"]));
    expect(bridge).toHaveBeenCalledTimes(3);
  });

  it("get() in flight, then invalidate(): the old fetch's resolution does not latch its result, and the trailing refetch invalidate() schedules is what serves fresh data", async () => {
    const bridge = vi.fn();
    const { promise: oldFetch, resolve: resolveOld } = deferred<WorkspaceFileListResult>();
    bridge.mockReturnValueOnce(oldFetch);
    bridge.mockResolvedValueOnce(makeResult(["c.ts"]));
    const cache = new WorkspaceFileListCache({ workspaceFileList: bridge });

    const first = cache.get(); // bridge call 1, in flight
    cache.invalidate();

    resolveOld(makeResult(["a.ts"]));
    await expect(first).resolves.toEqual(makeResult(["a.ts"])); // the original caller still gets its own result

    // Settling the old fetch is what starts the one trailing refetch invalidate() scheduled — by
    // the time get() runs it has already been started (and may already have settled), so get()
    // joins it rather than starting a third call.
    await expect(cache.get()).resolves.toEqual(makeResult(["c.ts"]));
    expect(bridge).toHaveBeenCalledTimes(2);
  });

  it("getFresh() called again after invalidate() killed an in-flight revalidation returns the trailing refetch, not the doomed promise, even when that revalidation fails", async () => {
    const bridge = vi.fn();
    bridge.mockResolvedValueOnce(makeResult(["a.ts"]));
    const { promise: staleFresh, reject: rejectStaleFresh } = deferred<WorkspaceFileListResult>();
    bridge.mockReturnValueOnce(staleFresh);
    bridge.mockResolvedValueOnce(makeResult(["c.ts"]));
    const cache = new WorkspaceFileListCache({ workspaceFileList: bridge });

    await cache.get(); // bridge call 1
    const doomed = cache.getFresh(); // bridge call 2, in flight

    cache.invalidate();
    const revived = cache.getFresh(); // must not be the promise stuck waiting on the doomed revalidation
    expect(revived).not.toBe(doomed);

    // The doomed revalidation fails; that failure is still what unblocks the trailing refetch
    // invalidate() scheduled — a fetch failure is not treated any differently from a success for
    // the purpose of firing the one trailing request that is owed.
    rejectStaleFresh(new Error("boom"));
    await expect(doomed).rejects.toThrow("boom");
    await expect(revived).resolves.toEqual(makeResult(["c.ts"]));
    expect(bridge).toHaveBeenCalledTimes(3);
  });
});

describe("WorkspaceFileListCache — coalescing invalidations into a single trailing refetch", () => {
  it("three invalidate() calls plus a get() and a getFresh() made during one in-flight fetch collapse into exactly one trailing bridge call", async () => {
    const bridge = vi.fn();
    const { promise: originalFetch, resolve: resolveOriginal } = deferred<WorkspaceFileListResult>();
    bridge.mockReturnValueOnce(originalFetch); // call 1: the fetch already in flight
    const { promise: trailingFetch, resolve: resolveTrailing } = deferred<WorkspaceFileListResult>();
    bridge.mockReturnValueOnce(trailingFetch); // call 2: the one trailing refetch

    const cache = new WorkspaceFileListCache({ workspaceFileList: bridge });

    const original = cache.get(); // bridge call 1, in flight
    cache.invalidate();
    cache.invalidate();
    cache.invalidate();
    const duringFlightGet = cache.get();
    const duringFlightFresh = cache.getFresh();
    // Three invalidations plus a get() and a getFresh(), all arriving while the one fetch above is
    // still in flight, add nothing: there is nothing more to fire until that fetch settles.
    expect(bridge).toHaveBeenCalledTimes(1);

    resolveOriginal(makeResult(["a.ts"]));
    await expect(original).resolves.toEqual(makeResult(["a.ts"])); // the original caller still gets its own result
    // Settling the original fetch is what starts the one trailing refetch every call above
    // coalesced into.
    expect(bridge).toHaveBeenCalledTimes(2);

    resolveTrailing(makeResult(["c.ts"]));
    await expect(duringFlightGet).resolves.toEqual(makeResult(["c.ts"]));
    await expect(duringFlightFresh).resolves.toEqual(makeResult(["c.ts"]));
    await expect(cache.get()).resolves.toEqual(makeResult(["c.ts"]));
    expect(bridge).toHaveBeenCalledTimes(2);
  });

  it("an in-flight fetch failing after invalidate() still runs the trailing refetch, which populates the cache", async () => {
    const bridge = vi.fn();
    const { promise: originalFetch, reject: rejectOriginal } = deferred<WorkspaceFileListResult>();
    bridge.mockReturnValueOnce(originalFetch); // call 1: the fetch already in flight
    bridge.mockResolvedValueOnce(makeResult(["c.ts"])); // call 2: the trailing refetch

    const cache = new WorkspaceFileListCache({ workspaceFileList: bridge });

    const original = cache.get(); // bridge call 1, in flight
    cache.invalidate();

    rejectOriginal(new Error("boom"));
    await expect(original).rejects.toThrow("boom"); // the original caller sees its own failure

    // The trailing refetch invalidate() scheduled runs regardless of how the flight it was chained
    // after settled — success or failure — and its own success populates the cache.
    await expect(cache.get()).resolves.toEqual(makeResult(["c.ts"]));
    expect(bridge).toHaveBeenCalledTimes(2);
  });

  it("get() and getFresh() called during an in-flight fetch with no invalidation dedupe into that one fetch — no trailing call fires", async () => {
    const bridge = vi.fn();
    const { promise: originalFetch, resolve: resolveOriginal } = deferred<WorkspaceFileListResult>();
    bridge.mockReturnValueOnce(originalFetch);

    const cache = new WorkspaceFileListCache({ workspaceFileList: bridge });

    const first = cache.get();
    const second = cache.get();
    const third = cache.getFresh();
    expect(bridge).toHaveBeenCalledTimes(1);

    resolveOriginal(makeResult(["a.ts"]));
    await expect(first).resolves.toEqual(makeResult(["a.ts"]));
    await expect(second).resolves.toEqual(makeResult(["a.ts"]));
    await expect(third).resolves.toEqual(makeResult(["a.ts"]));
    // No invalidate() happened, so no trailing request was ever owed — the count stays at 1.
    expect(bridge).toHaveBeenCalledTimes(1);
  });
});

describe("WorkspaceFileListCache — invalidate()'s unconsumed trailing refetch", () => {
  // Flush both the microtask queue (promise reaction chains) and a macrotask tick (setTimeout),
  // a couple of times, so a rejection that would otherwise surface as an unhandled rejection has
  // had every chance to do so before we assert it didn't.
  async function flushAsync(): Promise<void> {
    for (let i = 0; i < 3; i++) {
      await Promise.resolve();
      await new Promise((resolve) => setTimeout(resolve, 0));
    }
  }

  it("a trailing refetch with no get()/getFresh() consumer does not surface as an unhandled rejection, and a later get() still recovers", async () => {
    const unhandled = vi.fn();
    process.on("unhandledRejection", unhandled);
    try {
      const bridge = vi.fn();
      const { promise: originalFetch, resolve: resolveOriginal } = deferred<WorkspaceFileListResult>();
      bridge.mockReturnValueOnce(originalFetch); // call 1: the fetch already in flight
      bridge.mockRejectedValueOnce(new Error("boom")); // call 2: the trailing refetch, rejects
      bridge.mockResolvedValueOnce(makeResult(["a.ts"])); // call 3: a later get() recovers

      const cache = new WorkspaceFileListCache({ workspaceFileList: bridge });

      const first = cache.get(); // bridge call 1, in flight
      cache.invalidate(); // schedules a trailing refetch with no consumer of its own

      resolveOriginal(makeResult(["stale.ts"]));
      await expect(first).resolves.toEqual(makeResult(["stale.ts"]));

      // The trailing refetch (bridge call 2) fires now and rejects. Nothing calls get()/getFresh()
      // to join it — that's the point — so its rejection must be absorbed rather than escape as an
      // unhandled rejection.
      await flushAsync();
      expect(unhandled).not.toHaveBeenCalled();

      // The cache recovers on the next call rather than latching the trailing failure.
      await expect(cache.get()).resolves.toEqual(makeResult(["a.ts"]));
      expect(bridge).toHaveBeenCalledTimes(3);
    } finally {
      process.off("unhandledRejection", unhandled);
    }
  });
});

describe("WorkspaceFileListCache — snapshot()", () => {
  it("is undefined before any fetch has ever succeeded", () => {
    const cache = new WorkspaceFileListCache({ workspaceFileList: vi.fn() });
    expect(cache.snapshot()).toBeUndefined();
  });

  it("returns the last successful result once a fetch resolves", async () => {
    const bridge = vi.fn().mockResolvedValue(makeResult(["a.ts"]));
    const cache = new WorkspaceFileListCache({ workspaceFileList: bridge });

    await cache.get();

    expect(cache.snapshot()).toEqual(makeResult(["a.ts"]));
  });

  it("survives invalidate() — unlike `cached`, the pre-invalidation listing is still worth showing until the refetch lands", async () => {
    const bridge = vi.fn().mockResolvedValue(makeResult(["a.ts"]));
    const cache = new WorkspaceFileListCache({ workspaceFileList: bridge });

    await cache.get();
    cache.invalidate();

    expect(cache.snapshot()).toEqual(makeResult(["a.ts"]));
  });

  it("updates once a revalidation resolves", async () => {
    const bridge = vi.fn();
    bridge.mockResolvedValueOnce(makeResult(["a.ts"]));
    bridge.mockResolvedValueOnce(makeResult(["a.ts", "b.ts"]));
    const cache = new WorkspaceFileListCache({ workspaceFileList: bridge });

    await cache.get();
    expect(cache.snapshot()).toEqual(makeResult(["a.ts"]));

    await cache.getFresh();
    expect(cache.snapshot()).toEqual(makeResult(["a.ts", "b.ts"]));
  });

  it("updates from a request whose generation went stale — a stale result is still newer than whatever it held before", async () => {
    const bridge = vi.fn();
    const { promise: staleFetch, resolve: resolveStale } = deferred<WorkspaceFileListResult>();
    bridge.mockReturnValueOnce(staleFetch); // call 1: in flight when invalidate() fires
    const { promise: trailingFetch, resolve: resolveTrailing } = deferred<WorkspaceFileListResult>();
    bridge.mockReturnValueOnce(trailingFetch); // call 2: the trailing refetch, held open deliberately
    const cache = new WorkspaceFileListCache({ workspaceFileList: bridge });

    const first = cache.get(); // bridge call 1, in flight
    cache.invalidate(); // bumps generation before call 1 settles; schedules the trailing refetch

    resolveStale(makeResult(["stale.ts"]));
    await expect(first).resolves.toEqual(makeResult(["stale.ts"]));
    // The stale result never became `cached` (invalidate() bumped generation first), but it's still
    // recorded as the last-known-good snapshot — newer than nothing at all. The trailing refetch
    // (bridge call 2) is already in flight here but deliberately held open so it can't have
    // overwritten this yet.
    expect(cache.snapshot()).toEqual(makeResult(["stale.ts"]));

    resolveTrailing(makeResult(["c.ts"]));
    await expect(cache.get()).resolves.toEqual(makeResult(["c.ts"]));
    expect(cache.snapshot()).toEqual(makeResult(["c.ts"]));
  });
});
