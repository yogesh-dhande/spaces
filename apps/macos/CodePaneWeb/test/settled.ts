import { vi } from "vitest";

/**
 * A completion point for a result produced by the mocked bridge, so a test asserts after the work
 * that fills in the result has finished instead of polling for it against a clock.
 *
 * The producers are promise chains over fakes that resolve immediately, plus `setTimeout(0)` hops
 * (the comments press gate) that a test runs under fake timers. `settled` runs that work to
 * quiescence and then evaluates `check` exactly once, so there is no deadline and no retry:
 *
 * - a real macrotask turn drains every microtask chain, which is all the immediately-resolving
 *   fakes need (a macrotask never starts while a microtask is queued);
 * - under fake timers it then fires queued timers one at a time until none is left (bounded at 100
 *   rounds, so a self-rearming timer cannot spin it). That is bounded by the work in the queue, not
 *   by a clock: a delayed reply costs one round however long its delay is.
 *
 * `check`'s own error is the failure, so the failing assertion is what the test reports. A result
 * that depends on a real animation frame or a real timer is not something this can drain: those
 * tests use fake timers with the immediate-paint frame stub, or a real signal (`arrivals`,
 * `untilMutated`).
 */

// Captured at import, before a test installs fake timers that would replace it.
const realTurn: (callback: () => void) => unknown = setImmediate;

function nextTurn(): Promise<void> {
  return new Promise((resolve) => realTurn(resolve));
}

export async function settled<T>(check: () => T): Promise<T> {
  await nextTurn();
  if (vi.isFakeTimers()) {
    for (let round = 0; round < 100 && vi.getTimerCount() > 0; round++) await vi.advanceTimersToNextTimerAsync();
  }
  return check();
}
