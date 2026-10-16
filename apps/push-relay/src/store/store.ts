import type { PhoneState } from "../core/types";

/**
 * Per-phone state keyed by `phoneKey(installID)`. `transact` must be atomic per key: concurrent
 * reports from several devices of one phone may not lose each other's updates. `fn` may run
 * more than once (transaction retry), so it must not have side effects.
 */
export interface PhoneStateStore {
  transact<T>(
    key: string,
    fn: (current: PhoneState | undefined) => { next: PhoneState | undefined; result: T },
  ): Promise<T>;
}
