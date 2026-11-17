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
  next(): Promise<void>;
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
    next() {
      if (pending > 0) {
        pending -= 1;
        return Promise.resolve();
      }
      return new Promise<void>((resolve) => waiters.push(resolve));
    },
  };
}
