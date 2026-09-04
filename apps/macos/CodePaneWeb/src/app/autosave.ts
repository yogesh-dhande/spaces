/**
 * Autosave scheduling for Editor mode: the timing policy that sits between keystrokes and the
 * host's actual write. It is deliberately free of DOM and bridge calls (the host interface below
 * is the only contact with the outside world) so the policy is unit-testable on its own, the same
 * split `state.ts` uses for the pane's mode/scope reducer.
 *
 * The policy is: coalesce a burst of edits into one write, never overlap writes, back off
 * exponentially on transient failures, and stop writing entirely while the host reports something
 * only the user can resolve (a conflict, a deleted file). Content coalescing itself belongs to the
 * host: this scheduler decides only when `performSave` runs, never what it writes.
 */

export const AUTOSAVE_DEBOUNCE_MS = 800;
export const AUTOSAVE_RETRY_FLOOR_MS = 1000;
export const AUTOSAVE_RETRY_CAP_MS = 30_000;
/** How often a pending retry republishes its remaining wait, so the chip counts seconds down. */
const TICK_MS = 1000;

/** Backoff for the Nth consecutive failure (failures >= 1): min(cap, floor * 2^(failures-1)). */
export function retryDelayMs(
  failures: number,
  floorMs = AUTOSAVE_RETRY_FLOOR_MS,
  capMs = AUTOSAVE_RETRY_CAP_MS,
): number {
  return Math.min(capMs, floorMs * 2 ** (failures - 1));
}

/** What one save attempt reported. `clean` = nothing to write (buffer matched disk already);
 *  `saved` = wrote; `blocked` = the host cannot write until the user resolves something
 *  (conflict, file deleted); `{ failed }` = a transient failure worth retrying, reason for display. */
export type SaveOutcome = "clean" | "saved" | "blocked" | { failed: string };

export type AutosaveStatus =
  | { kind: "idle" }
  | { kind: "dirty" }
  | { kind: "saving" }
  | { kind: "saved" }
  | { kind: "failed"; reason: string; retryInMs: number }
  | { kind: "blocked"; reason: string };

export interface AutosaveHost {
  isDirty(): boolean;
  /** Reason the host cannot write right now (conflict text, "File deleted on disk"), or undefined when it can. */
  blockedReason(): string | undefined;
  /** Never called while a previous call is still in flight. */
  performSave(): Promise<SaveOutcome>;
  /** Called on every status change, never twice in a row with the same status. */
  onStatus(status: AutosaveStatus): void;
}

export interface AutosaveOptions {
  debounceMs?: number;
  retryFloorMs?: number;
  retryCapMs?: number;
}

export class AutosaveScheduler {
  private readonly host: AutosaveHost;
  private readonly debounceMs: number;
  private readonly retryFloorMs: number;
  private readonly retryCapMs: number;

  private current: AutosaveStatus = { kind: "idle" };
  private debounceTimer: ReturnType<typeof setTimeout> | undefined;
  private retryTimer: ReturnType<typeof setTimeout> | undefined;
  /** Runs alongside `retryTimer` only, republishing the failed status once a second so the chip's
   *  "retry in N s" counts down instead of freezing at the delay it was armed with. Cleared with the
   *  retry itself, so every transition that drops the retry drops the countdown with it. */
  private retryTicker: ReturnType<typeof setInterval> | undefined;
  /** Set while a run loop is live; also the handle `flush` awaits so two writes never overlap. */
  private runPromise: Promise<void> | undefined;
  /** An edit arrived mid-write, so the settled write is already stale and the loop runs again. */
  private rearm = false;
  private failures = 0;
  /** Distinguishes "saved" from "idle" for a `clean` outcome: a session that has written something
   *  keeps showing the reassuring saved state, one that never has has nothing to report. */
  private hasSavedThisSession = false;
  private cancelled = false;

  constructor(host: AutosaveHost, options: AutosaveOptions = {}) {
    this.host = host;
    this.debounceMs = options.debounceMs ?? AUTOSAVE_DEBOUNCE_MS;
    this.retryFloorMs = options.retryFloorMs ?? AUTOSAVE_RETRY_FLOOR_MS;
    this.retryCapMs = options.retryCapMs ?? AUTOSAVE_RETRY_CAP_MS;
  }

  get status(): AutosaveStatus {
    return this.current;
  }

  /** An edit happened: (re)arm the debounce, cancel any pending retry (the debounced write is the
   *  retry), and if a write is in flight remember to run again as soon as it settles. */
  noteEdit(): void {
    if (this.cancelled) return;
    this.clearRetry();
    if (this.host.blockedReason() !== undefined) {
      // The block is what the user has to act on, so it outranks "dirty" in the status line, and a
      // debounced write would only be refused again until they resolve it.
      this.enterBlocked();
      return;
    }
    if (this.runPromise !== undefined) {
      this.rearm = true;
      return;
    }
    this.armDebounce();
  }

  /** The host's dirty or blocked state changed for a reason other than an edit: an external change
   *  reconciled, a conflict entered or resolved, the file deleted. */
  reevaluate(): void {
    if (this.cancelled) return;
    if (this.host.blockedReason() !== undefined) {
      this.enterBlocked();
      return;
    }
    if (this.runPromise !== undefined) return;
    if (this.host.isDirty()) {
      if (this.debounceTimer === undefined && this.retryTimer === undefined) this.armDebounce();
      return;
    }
    // Nothing left to write, so nothing scheduled has any work to do: a pending debounce or a
    // backoff retry (whose write an external reconcile has since made unnecessary by adopting
    // exactly these bytes) would only flash "saving" for a clean buffer. The failure count goes with
    // them, or the next edit would inherit a backoff earned by a write that is no longer owed.
    this.clearDebounce();
    this.clearRetry();
    this.failures = 0;
    this.emit(this.settledStatus());
  }

  /** Save now, for ⌘S, a "Retry now" control, and teardown-adjacent flushes: drops the pending
   *  timers, waits out any in-flight write, and runs until the host is clean, blocked, or a write
   *  fails. Resolves rather than rejecting so callers can await it from a UI handler. */
  async flush(): Promise<"clean" | "blocked" | "failed"> {
    if (this.cancelled) return "clean";
    this.clearDebounce();
    this.clearRetry();
    if (this.runPromise !== undefined) {
      // The live loop already keeps going while the host is dirty, so awaiting it is the whole job.
      await this.runPromise;
      return this.flushResult();
    }
    if (!this.host.isDirty()) return "clean";
    await this.ensureRun();
    return this.flushResult();
  }

  /**
   * Ends the current file's save session and starts a fresh one: pending work dropped, backoff
   * forgotten, nothing to report. Called by the host when a new file takes over the pane, since
   * every part of this scheduler's state is about the file that was open (a "Saved" belonging to the
   * previous file is not true of the new one, and its accumulated backoff is not the new file's to
   * inherit). Unlike `cancel`, the scheduler stays usable.
   */
  reset(): void {
    this.clearDebounce();
    this.clearRetry();
    this.rearm = false;
    this.failures = 0;
    this.hasSavedThisSession = false;
    this.emit({ kind: "idle" });
  }

  /** Drop all timers; no further `performSave` calls. Used at teardown. */
  cancel(): void {
    this.cancelled = true;
    this.rearm = false;
    this.clearDebounce();
    this.clearRetry();
  }

  private async runLoop(): Promise<void> {
    for (;;) {
      if (this.cancelled) return;
      if (this.host.blockedReason() !== undefined) {
        this.enterBlocked();
        return;
      }
      this.rearm = false;
      this.emit({ kind: "saving" });
      let outcome: SaveOutcome;
      try {
        outcome = await this.host.performSave();
      } catch (error) {
        // A host that throws is reported like any other transient failure, so the pane still shows a
        // reason and a retry instead of a stuck "saving" and an unhandled rejection.
        outcome = { failed: error instanceof Error ? error.message : String(error) };
      }
      if (this.cancelled) return;
      if (typeof outcome === "object") {
        this.failures += 1;
        const delayMs = retryDelayMs(this.failures, this.retryFloorMs, this.retryCapMs);
        this.emit({ kind: "failed", reason: outcome.failed, retryInMs: delayMs });
        this.armRetry(delayMs, outcome.failed);
        return;
      }
      if (outcome === "blocked") {
        this.enterBlocked();
        return;
      }
      this.failures = 0;
      if (outcome === "saved") this.hasSavedThisSession = true;
      // Edits that landed during the write are written immediately: the debounce has already been
      // paid for them, and the host coalesces them into a single next write.
      if (this.rearm || this.host.isDirty()) continue;
      this.emit(this.settledStatus());
      return;
    }
  }

  private ensureRun(): Promise<void> {
    if (this.runPromise !== undefined) return this.runPromise;
    const run = this.runLoop().finally(() => {
      this.runPromise = undefined;
    });
    this.runPromise = run;
    return run;
  }

  private armDebounce(): void {
    this.clearDebounce();
    this.debounceTimer = setTimeout(() => {
      this.debounceTimer = undefined;
      if (this.cancelled) return;
      void this.ensureRun();
    }, this.debounceMs);
    this.emit({ kind: "dirty" });
  }

  private armRetry(delayMs: number, reason: string): void {
    this.clearRetry();
    this.retryTimer = setTimeout(() => {
      // Clears the countdown as well: the wait it was reporting is over.
      this.clearRetry();
      if (this.cancelled) return;
      void this.ensureRun();
    }, delayMs);
    let remainingMs = delayMs;
    this.retryTicker = setInterval(() => {
      remainingMs -= TICK_MS;
      // The final tick coincides with the retry firing, which emits `saving` of its own; reporting
      // "retry in 0 s" first would be a wrong reading of a wait that no longer exists.
      if (remainingMs <= 0) return;
      this.emit({ kind: "failed", reason, retryInMs: remainingMs });
    }, TICK_MS);
  }

  private clearDebounce(): void {
    if (this.debounceTimer === undefined) return;
    clearTimeout(this.debounceTimer);
    this.debounceTimer = undefined;
  }

  private clearRetry(): void {
    if (this.retryTicker !== undefined) {
      clearInterval(this.retryTicker);
      this.retryTicker = undefined;
    }
    if (this.retryTimer === undefined) return;
    clearTimeout(this.retryTimer);
    this.retryTimer = undefined;
  }

  /** Blocked is a hard stop: no timers, no writes, until `reevaluate` sees the host unblocked. */
  private enterBlocked(): void {
    this.clearDebounce();
    this.clearRetry();
    this.emit({ kind: "blocked", reason: this.host.blockedReason() ?? "Save blocked" });
  }

  private settledStatus(): AutosaveStatus {
    return this.hasSavedThisSession ? { kind: "saved" } : { kind: "idle" };
  }

  private flushResult(): "clean" | "blocked" | "failed" {
    if (this.current.kind === "blocked") return "blocked";
    if (this.current.kind === "failed") return "failed";
    return "clean";
  }

  private emit(status: AutosaveStatus): void {
    if (sameStatus(this.current, status)) return;
    this.current = status;
    this.host.onStatus(status);
  }
}

function sameStatus(a: AutosaveStatus, b: AutosaveStatus): boolean {
  if (a.kind !== b.kind) return false;
  if (a.kind === "failed" && b.kind === "failed") {
    return a.reason === b.reason && a.retryInMs === b.retryInMs;
  }
  if (a.kind === "blocked" && b.kind === "blocked") return a.reason === b.reason;
  return true;
}
