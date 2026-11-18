import { onTestFailed, onTestFinished } from "vitest";

/**
 * A rendezvous between a fake that parks a request and the test that needs to know it is parked,
 * so the test awaits the call that produces what it asserts instead of polling a captured resolver
 * against a wall-clock limit that a loaded machine overruns.
 *
 * Each `arrive()` is queued until a `next()` consumes it, so an arrival that lands between the
 * action and the `await` is not lost, and `next()` resolves immediately when one is already
 * pending. A request that never arrives fails at the test timeout, not at a polling deadline.
 */
export interface Arrivals {
  arrive(): void;
  /** `until` withdraws the pending wait when it aborts, so an abandoned waiter neither resolves
   *  later nor swallows an arrival meant for the next test's waiter. */
  next(until?: AbortSignal): Promise<void>;
}

/**
 * Resolves with `check`'s value as soon as it stops throwing, re-evaluating it each time a
 * request arrives (and once up front). For an effect of a fake's reply that makes the product issue
 * a further request: the reply may land arbitrarily late, and the request it triggers is the event
 * to wait for. A queued arrival that predates the call only costs one extra re-check.
 *
 * With no deadline of its own, a check that never passes fails at the test timeout, so the last
 * error `check` threw is attached to the failing test's errors. Vitest does not cancel the loop of
 * a test that timed out, and arrivals are shared across tests, so the wait is withdrawn when its
 * test finishes: a later test's request must never wake it and run its remaining steps.
 */
export async function untilArrived<T>(arrivals: Arrivals, check: () => T): Promise<T> {
  let lastError: unknown;
  let reported = false;
  const finished = new AbortController();
  onTestFinished(() => finished.abort());
  for (;;) {
    if (finished.signal.aborted) return new Promise<T>(() => {});
    try {
      const value = check();
      lastError = undefined; // a later, unrelated failure must not be blamed on this wait
      return value;
    } catch (error) {
      lastError = error;
      if (!reported) {
        reported = true;
        onTestFailed((context) => {
          const errors = context.task.result?.errors;
          if (lastError !== undefined && errors !== undefined) errors.push(lastError as (typeof errors)[number]);
        });
      }
    }
    await arrivals.next(finished.signal);
  }
}

export function makeArrivals(): Arrivals {
  let pending = 0;
  const waiters: Array<() => void> = [];
  return {
    arrive() {
      const waiter = waiters.shift();
      if (waiter) waiter();
      else pending += 1;
    },
    next(until) {
      if (pending > 0) {
        pending -= 1;
        return Promise.resolve();
      }
      return new Promise<void>((resolve) => {
        waiters.push(resolve);
        until?.addEventListener("abort", () => {
          const index = waiters.indexOf(resolve);
          if (index >= 0) waiters.splice(index, 1);
        });
      });
    },
  };
}
