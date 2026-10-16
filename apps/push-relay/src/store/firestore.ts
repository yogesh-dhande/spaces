import type { Firestore } from "firebase-admin/firestore";
import type { PhoneState } from "../core/types";
import type { PhoneStateStore } from "./store";

const COLLECTION = "phones";

export class FirestoreStore implements PhoneStateStore {
  constructor(private readonly db: Firestore) {}

  transact<T>(
    key: string,
    fn: (current: PhoneState | undefined) => { next: PhoneState | undefined; result: T },
  ): Promise<T> {
    const ref = this.db.collection(COLLECTION).doc(key);
    return this.db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const { next, result } = fn(snap.exists ? (snap.data() as PhoneState) : undefined);
      if (next === undefined) {
        if (snap.exists) tx.delete(ref);
      } else {
        tx.set(ref, next);
      }
      return result;
    });
  }
}
