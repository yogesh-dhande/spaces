export type ApnsEnvironment = "sandbox" | "production";

/** What a capability seals: everything needed to push to one phone, and nothing else. */
export interface Capability {
  v: 1;
  token: string;
  env: ApnsEnvironment;
  installID: string;
}

/** One daemon's latest report for one phone. Counts only, never content. */
export interface DeviceCounts {
  deviceID: string;
  total: number;
  blockedAgents: number;
  updatedAt: number;
}

/**
 * Per-phone state. An array rather than a map keyed by deviceID: device ids are
 * daemon-supplied strings, and arbitrary keys collide with reserved names
 * (`__proto__`, Firestore's `__x__` fields).
 */
export interface PhoneState {
  devices: DeviceCounts[];
  /**
   * The devices the phone is currently paired with, as of its last register. Only these may report.
   * A phone cannot reach a daemon that is offline when it unpairs it, so that daemon keeps a valid
   * capability and would restore its counts when it returned; the phone's own list is what stops it.
   * Required, not optional: the allowlist ships before any phone registered, so no stored document
   * predates the field and none needs a default.
   */
  pairedDeviceIDs: string[];
  /**
   * The badge total the phone last received from a successful push. Decisions compare against
   * this rather than the previously stored total, so retrying a report after a failed send
   * still sends.
   */
  deliveredTotal: number;
}

export interface Totals {
  total: number;
  blockedAgents: number;
}
