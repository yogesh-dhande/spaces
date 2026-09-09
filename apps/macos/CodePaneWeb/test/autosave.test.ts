import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  AUTOSAVE_RETRY_CAP_MS,
  AutosaveScheduler,
  type AutosaveHost,
  type AutosaveStatus,
  type SaveOutcome,
  retryDelayMs,
} from "../src/app/autosave";

/** Lets a resolved `performSave` promise's continuation (and the next loop turn it starts) run
 *  without moving fake time, so tests can assert "the next write happened with no timer advance". */
async function tick(): Promise<void> {
  for (let i = 0; i < 8; i++) await Promise.resolve();
}

/**
 * Host whose writes never settle on their own: each `performSave` parks until the test calls
 * `settle`, which is what makes "an edit arrived mid-write" and "flush awaited the in-flight
 * write" expressible at all.
 */
class ScriptedHost implements AutosaveHost {
  dirty = false;
  blocked: string | undefined = undefined;
  calls = 0;
  readonly statuses: AutosaveStatus[] = [];
  private readonly pending: ((outcome: SaveOutcome) => void)[] = [];

  isDirty(): boolean {
    return this.dirty;
  }

  blockedReason(): string | undefined {
    return this.blocked;
  }

  performSave(): Promise<SaveOutcome> {
    if (this.pending.length > 0) throw new Error("performSave called while one was in flight");
    this.calls += 1;
    // A real host snapshots the buffer when the write starts, so it reads clean until the next edit.
    this.dirty = false;
    return new Promise<SaveOutcome>((resolve) => {
      this.pending.push(resolve);
    });
  }

  onStatus(status: AutosaveStatus): void {
    this.statuses.push(status);
  }

  kinds(): string[] {
    return this.statuses.map((status) => status.kind);
  }

  async settle(outcome: SaveOutcome): Promise<void> {
    const resolve = this.pending.shift();
    if (!resolve) throw new Error("settle() with no performSave in flight");
    // Nothing reached disk on a failure or a block, so the buffer is dirty again.
    if (typeof outcome === "object" || outcome === "blocked") this.dirty = true;
    resolve(outcome);
    await tick();
  }

  edit(scheduler: AutosaveScheduler): void {
    this.dirty = true;
    scheduler.noteEdit();
  }
}

describe("retryDelayMs", () => {
  it("doubles from the floor and caps", () => {
    expect(retryDelayMs(1)).toBe(1000);
    expect(retryDelayMs(2)).toBe(2000);
    expect(retryDelayMs(3)).toBe(4000);
    expect(retryDelayMs(5)).toBe(16_000);
    expect(retryDelayMs(6)).toBe(AUTOSAVE_RETRY_CAP_MS);
    expect(retryDelayMs(40)).toBe(AUTOSAVE_RETRY_CAP_MS);
  });

  it("honors overridden floor and cap", () => {
    expect(retryDelayMs(3, 50, 10_000)).toBe(200);
    expect(retryDelayMs(9, 50, 10_000)).toBe(10_000);
  });
});

describe("AutosaveScheduler", () => {
  let host: ScriptedHost;
  let scheduler: AutosaveScheduler;

  beforeEach(() => {
    vi.useFakeTimers();
    host = new ScriptedHost();
    scheduler = new AutosaveScheduler(host);
  });

  afterEach(() => {
    scheduler.cancel();
    vi.useRealTimers();
  });

  it("coalesces a burst of edits into one write 800ms after the last one", async () => {
    for (let i = 0; i < 5; i++) {
      host.edit(scheduler);
      await vi.advanceTimersByTimeAsync(100);
    }
    expect(host.calls).toBe(0);

    await vi.advanceTimersByTimeAsync(700);
    expect(host.calls).toBe(1);

    await host.settle("saved");
    expect(host.calls).toBe(1);
    expect(host.kinds()).toEqual(["dirty", "saving", "saved"]);
    expect(scheduler.status).toEqual({ kind: "saved" });
  });

  it("runs exactly one more write right after an edit that arrived mid-write", async () => {
    host.edit(scheduler);
    await vi.advanceTimersByTimeAsync(800);
    expect(host.calls).toBe(1);

    host.edit(scheduler);
    expect(host.calls).toBe(1);

    await host.settle("saved");
    expect(host.calls).toBe(2);

    await host.settle("saved");
    expect(host.calls).toBe(2);
    expect(scheduler.status).toEqual({ kind: "saved" });
  });

  it("re-runs after a mid-write edit even when the host reads clean once the write settles", async () => {
    host.edit(scheduler);
    await vi.advanceTimersByTimeAsync(800);
    expect(host.calls).toBe(1);

    host.edit(scheduler);
    // The host folded the mid-write edit into the write it was already performing, so its own dirty
    // flag says nothing; only the recorded edit can tell the scheduler to look again.
    host.dirty = false;
    await host.settle("saved");
    expect(host.calls).toBe(2);

    await host.settle("clean");
    expect(host.calls).toBe(2);
    expect(scheduler.status).toEqual({ kind: "saved" });
  });

  it("flush cancels the debounce and resolves clean after one write", async () => {
    host.edit(scheduler);
    const flushed = scheduler.flush();
    await tick();
    expect(host.calls).toBe(1);

    await host.settle("saved");
    await expect(flushed).resolves.toBe("clean");

    await vi.advanceTimersByTimeAsync(2000);
    expect(host.calls).toBe(1);
  });

  it("flush awaits an in-flight write and runs once more while the host stays dirty", async () => {
    host.edit(scheduler);
    await vi.advanceTimersByTimeAsync(800);
    expect(host.calls).toBe(1);

    const flushed = scheduler.flush();
    host.dirty = true;
    await host.settle("saved");
    expect(host.calls).toBe(2);

    await host.settle("saved");
    await expect(flushed).resolves.toBe("clean");
    expect(host.calls).toBe(2);
  });

  it("reports the outcome of the in-flight write flush waited on", async () => {
    host.edit(scheduler);
    await vi.advanceTimersByTimeAsync(800);
    expect(host.calls).toBe(1);

    const flushed = scheduler.flush();
    host.blocked = "Conflict: file changed on disk";
    await host.settle("blocked");
    await expect(flushed).resolves.toBe("blocked");
    expect(host.calls).toBe(1);
  });

  it("starts no further write when the host blocks while one is in flight", async () => {
    host.edit(scheduler);
    await vi.advanceTimersByTimeAsync(800);
    expect(host.calls).toBe(1);

    host.edit(scheduler);
    host.blocked = "Conflict: file changed on disk";
    await host.settle("saved");

    expect(host.calls).toBe(1);
    expect(scheduler.status).toEqual({ kind: "blocked", reason: "Conflict: file changed on disk" });
    expect(vi.getTimerCount()).toBe(0);
  });

  it("resolves clean immediately and emits nothing when there is nothing to save", async () => {
    await expect(scheduler.flush()).resolves.toBe("clean");
    expect(host.calls).toBe(0);
    expect(host.statuses).toEqual([]);
    expect(scheduler.status).toEqual({ kind: "idle" });
  });

  it("backs off 1000, 2000, 4000 across consecutive failures and resets after a success", async () => {
    host.edit(scheduler);
    await vi.advanceTimersByTimeAsync(800);
    await host.settle({ failed: "disk full" });
    expect(scheduler.status).toEqual({ kind: "failed", reason: "disk full", retryInMs: 1000 });

    await vi.advanceTimersByTimeAsync(999);
    expect(host.calls).toBe(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(host.calls).toBe(2);

    await host.settle({ failed: "disk full" });
    expect(scheduler.status).toEqual({ kind: "failed", reason: "disk full", retryInMs: 2000 });
    await vi.advanceTimersByTimeAsync(2000);
    expect(host.calls).toBe(3);

    await host.settle({ failed: "disk full" });
    expect(scheduler.status).toEqual({ kind: "failed", reason: "disk full", retryInMs: 4000 });
    await vi.advanceTimersByTimeAsync(4000);
    expect(host.calls).toBe(4);

    await host.settle("saved");
    expect(scheduler.status).toEqual({ kind: "saved" });

    host.edit(scheduler);
    await vi.advanceTimersByTimeAsync(800);
    await host.settle({ failed: "disk full again" });
    expect(scheduler.status).toEqual({ kind: "failed", reason: "disk full again", retryInMs: 1000 });
  });

  it("counts the retry down once a second while the backoff runs", async () => {
    // Three failures to reach a 4s backoff, long enough to watch tick.
    host.edit(scheduler);
    await vi.advanceTimersByTimeAsync(800);
    await host.settle({ failed: "disk full" });
    await vi.advanceTimersByTimeAsync(1000);
    await host.settle({ failed: "disk full" });
    await vi.advanceTimersByTimeAsync(2000);
    await host.settle({ failed: "disk full" });
    expect(scheduler.status).toEqual({ kind: "failed", reason: "disk full", retryInMs: 4000 });
    host.statuses.length = 0;

    await vi.advanceTimersByTimeAsync(3000);

    // The chip reads 4, 3, 2, 1 rather than sitting on 4 for the whole wait.
    expect(host.statuses).toEqual([
      { kind: "failed", reason: "disk full", retryInMs: 3000 },
      { kind: "failed", reason: "disk full", retryInMs: 2000 },
      { kind: "failed", reason: "disk full", retryInMs: 1000 },
    ]);

    // The last second belongs to the retry itself, not to a "retry in 0 s" tick.
    await vi.advanceTimersByTimeAsync(1000);
    expect(host.calls).toBe(4);
    expect(host.kinds().at(-1)).toBe("saving");
  });

  it("stops counting down once an edit takes the retry over", async () => {
    host.edit(scheduler);
    await vi.advanceTimersByTimeAsync(800);
    await host.settle({ failed: "disk full" });
    await vi.advanceTimersByTimeAsync(1000);
    await host.settle({ failed: "disk full" }); // 2s backoff, so a tick is still due
    host.statuses.length = 0;

    host.edit(scheduler);
    await vi.advanceTimersByTimeAsync(5000);

    // The debounced write owns the next attempt: nothing may keep reporting a countdown that is no
    // longer running.
    expect(host.statuses.filter((status) => status.kind === "failed")).toEqual([]);
    expect(host.calls).toBe(3);
  });

  it("lets an edit during backoff replace the retry with the debounced write", async () => {
    host.edit(scheduler);
    await vi.advanceTimersByTimeAsync(800);
    await host.settle({ failed: "disk full" });
    expect(host.calls).toBe(1);

    await vi.advanceTimersByTimeAsync(400);
    host.edit(scheduler);
    expect(scheduler.status).toEqual({ kind: "dirty" });

    // The retry would have fired here; the debounce owns the next write now.
    await vi.advanceTimersByTimeAsync(600);
    expect(host.calls).toBe(1);

    await vi.advanceTimersByTimeAsync(200);
    expect(host.calls).toBe(2);
  });

  it("flush after a failure writes once immediately and resolves failed when that write fails", async () => {
    host.edit(scheduler);
    await vi.advanceTimersByTimeAsync(800);
    await host.settle({ failed: "disk full" });
    expect(host.calls).toBe(1);

    const flushed = scheduler.flush();
    expect(host.calls).toBe(2);

    await host.settle({ failed: "still full" });
    await expect(flushed).resolves.toBe("failed");
    expect(host.calls).toBe(2);
    expect(scheduler.status).toEqual({ kind: "failed", reason: "still full", retryInMs: 2000 });
  });

  it("stops writing while blocked and resumes on the debounce once the block clears", async () => {
    host.edit(scheduler);
    await vi.advanceTimersByTimeAsync(800);
    host.blocked = "Conflict: file changed on disk";
    await host.settle("blocked");
    expect(scheduler.status).toEqual({ kind: "blocked", reason: "Conflict: file changed on disk" });
    expect(vi.getTimerCount()).toBe(0);

    await vi.advanceTimersByTimeAsync(60_000);
    expect(host.calls).toBe(1);

    host.edit(scheduler);
    expect(scheduler.status).toEqual({ kind: "blocked", reason: "Conflict: file changed on disk" });
    expect(vi.getTimerCount()).toBe(0);
    await vi.advanceTimersByTimeAsync(60_000);
    expect(host.calls).toBe(1);
    expect(host.kinds()).toEqual(["dirty", "saving", "blocked"]);

    host.blocked = undefined;
    scheduler.reevaluate();
    expect(scheduler.status).toEqual({ kind: "dirty" });

    await vi.advanceTimersByTimeAsync(800);
    expect(host.calls).toBe(2);
    await host.settle("saved");
    expect(scheduler.status).toEqual({ kind: "saved" });
  });

  it("reports blocked and drops a pending debounce when the host blocks without any write", async () => {
    host.edit(scheduler);
    expect(scheduler.status).toEqual({ kind: "dirty" });

    host.blocked = "File deleted on disk";
    scheduler.reevaluate();
    expect(scheduler.status).toEqual({ kind: "blocked", reason: "File deleted on disk" });
    expect(vi.getTimerCount()).toBe(0);

    await vi.advanceTimersByTimeAsync(60_000);
    expect(host.calls).toBe(0);
  });

  it("cancel drops a pending debounce", async () => {
    host.edit(scheduler);
    expect(vi.getTimerCount()).toBe(1);

    scheduler.cancel();
    expect(vi.getTimerCount()).toBe(0);
    await vi.advanceTimersByTimeAsync(60_000);
    expect(host.calls).toBe(0);
  });

  it("cancel drops a pending retry", async () => {
    host.edit(scheduler);
    await vi.advanceTimersByTimeAsync(800);
    await host.settle({ failed: "disk full" });
    expect(host.calls).toBe(1);
    expect(vi.getTimerCount()).toBe(2); // the retry and the countdown that reports its remaining wait

    scheduler.cancel();
    expect(vi.getTimerCount()).toBe(0);
    await vi.advanceTimersByTimeAsync(60_000);
    expect(host.calls).toBe(1);
  });

  it("leaves a session that never wrote anything idle after a clean outcome", async () => {
    host.edit(scheduler);
    await vi.advanceTimersByTimeAsync(800);
    await host.settle("clean");
    expect(scheduler.status).toEqual({ kind: "idle" });
    expect(host.kinds()).toEqual(["dirty", "saving", "idle"]);
  });

  it("keeps saved for a clean outcome once the session has written something", async () => {
    host.edit(scheduler);
    await vi.advanceTimersByTimeAsync(800);
    await host.settle("saved");

    host.edit(scheduler);
    await vi.advanceTimersByTimeAsync(800);
    await host.settle("clean");
    expect(scheduler.status).toEqual({ kind: "saved" });
  });

  it("reset ends the session: pending work dropped, backoff forgotten, chip back to idle", async () => {
    host.edit(scheduler);
    await vi.advanceTimersByTimeAsync(800);
    await host.settle("saved");
    expect(scheduler.status).toEqual({ kind: "saved" });

    scheduler.reset();

    expect(scheduler.status).toEqual({ kind: "idle" });
    expect(host.kinds().at(-1)).toBe("idle");
    // A new session reports nothing until it writes something of its own: the previous file's
    // "Saved" is not carried over to a clean outcome here.
    host.dirty = false;
    scheduler.reevaluate();
    expect(scheduler.status).toEqual({ kind: "idle" });
  });

  it("reset drops a pending retry and the backoff it accumulated", async () => {
    host.edit(scheduler);
    await vi.advanceTimersByTimeAsync(800);
    await host.settle({ failed: "disk full" });
    await vi.advanceTimersByTimeAsync(1000);
    expect(host.calls).toBe(2);
    await host.settle({ failed: "disk full" });
    expect(scheduler.status).toEqual({ kind: "failed", reason: "disk full", retryInMs: 2000 });

    scheduler.reset();

    expect(scheduler.status).toEqual({ kind: "idle" });
    await vi.advanceTimersByTimeAsync(60_000);
    expect(host.calls).toBe(2); // the old session's retry never fires

    // The next session's first failure starts at the floor, not where the old one left off.
    host.edit(scheduler);
    await vi.advanceTimersByTimeAsync(800);
    await host.settle({ failed: "unrelated" });
    expect(scheduler.status).toEqual({ kind: "failed", reason: "unrelated", retryInMs: 1000 });
  });

  it("a host that goes clean during backoff drops the retry and the accumulated backoff", async () => {
    host.edit(scheduler);
    await vi.advanceTimersByTimeAsync(800);
    await host.settle({ failed: "disk full" });
    expect(host.calls).toBe(1);

    // An external reconcile adopted exactly these bytes, so there is nothing left for the pending
    // retry to write.
    host.dirty = false;
    scheduler.reevaluate();
    expect(scheduler.status).toEqual({ kind: "idle" });

    await vi.advanceTimersByTimeAsync(60_000);
    expect(host.calls).toBe(1); // no write at the old deadline

    // A brand-new edit gets the ordinary debounce and a first-failure backoff, not the old one.
    host.edit(scheduler);
    await vi.advanceTimersByTimeAsync(799);
    expect(host.calls).toBe(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(host.calls).toBe(2);
    await host.settle({ failed: "disk full" });
    expect(scheduler.status).toEqual({ kind: "failed", reason: "disk full", retryInMs: 1000 });
  });

  it("a host that goes clean while a debounce is pending drops it instead of writing nothing", async () => {
    host.edit(scheduler);
    await vi.advanceTimersByTimeAsync(400);

    host.dirty = false;
    scheduler.reevaluate();

    await vi.advanceTimersByTimeAsync(60_000);
    expect(host.calls).toBe(0);
    expect(host.kinds()).toEqual(["dirty", "idle"]);
  });

  it("never reports the same status twice in a row", async () => {
    host.edit(scheduler);
    host.edit(scheduler);
    host.edit(scheduler);
    expect(host.kinds()).toEqual(["dirty"]);

    await vi.advanceTimersByTimeAsync(800);
    await host.settle("saved");
    host.edit(scheduler);
    await vi.advanceTimersByTimeAsync(800);
    await host.settle("saved");
    expect(host.kinds()).toEqual(["dirty", "saving", "saved", "dirty", "saving", "saved"]);
  });
});
