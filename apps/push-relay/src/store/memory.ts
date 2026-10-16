import type { PhoneState } from "../core/types";
import type { PhoneStateStore } from "./store";

export class MemoryStore implements PhoneStateStore {
  readonly states = new Map<string, PhoneState>();

  async transact<T>(
    key: string,
    fn: (current: PhoneState | undefined) => { next: PhoneState | undefined; result: T },
  ): Promise<T> {
    const current = this.states.get(key);
    const { next, result } = fn(current && structuredClone(current));
    if (next === undefined) this.states.delete(key);
    else this.states.set(key, structuredClone(next));
    return result;
  }
}
