import { createHash } from "node:crypto";
import type { ApnsSender } from "../apns/sender";
import type { PhoneStateStore } from "../store/store";
import { decidePush, sumTotals, type ApnsPush } from "./decide";
import { sealCapability, unsealCapability } from "./seal";
import type { DeviceCounts, PhoneState } from "./types";
import { MAX_DEVICES_PER_PHONE, parseRegister, parseReport, parseUnregister } from "./validate";

export interface RelayDeps {
  store: PhoneStateStore;
  sender: ApnsSender;
  capabilityKey: Buffer;
  now: () => number;
}

export interface RelayRequest {
  method: string;
  path: string;
  body: unknown;
}

export interface RelayResponse {
  status: number;
  body: Record<string, unknown>;
}

/** Firestore document key. Derived from installID so the APNs token is never stored. */
export function phoneKey(installID: string): string {
  return createHash("sha256").update(`phone:${installID}`).digest("hex");
}

const reply = (status: number, body: Record<string, unknown>): RelayResponse => ({ status, body });
const err = (status: number, error: string) => reply(status, { error });

export async function handleRequest(deps: RelayDeps, req: RelayRequest): Promise<RelayResponse> {
  const route = ["/v1/register", "/v1/report", "/v1/unregister"].includes(req.path) ? req.path : undefined;
  if (!route) return err(404, "not_found");
  if (req.method !== "POST") return err(405, "method_not_allowed");
  if (typeof req.body !== "object" || req.body === null || Array.isArray(req.body)) {
    return err(400, "invalid_body");
  }
  const body = req.body as Record<string, unknown>;

  if (route === "/v1/register") {
    const parsed = parseRegister(body);
    if (!parsed.ok) return err(400, parsed.error);
    const { apnsToken, environment, installID } = parsed.value;
    const capability = sealCapability(deps.capabilityKey, { v: 1, token: apnsToken, env: environment, installID });
    return reply(200, { capability });
  }

  if (route === "/v1/report") {
    const parsed = parseReport(body);
    if (!parsed.ok) return err(400, parsed.error);
    const { capability, deviceID, total, blockedAgents, notify } = parsed.value;
    return applyChange(deps, capability, deviceID, notify, (devices) => {
      const others = devices.filter((d) => d.deviceID !== deviceID);
      if (others.length >= MAX_DEVICES_PER_PHONE) return undefined;
      const entry: DeviceCounts = { deviceID, total, blockedAgents, updatedAt: deps.now() };
      return [...others, entry];
    });
  }

  const parsed = parseUnregister(body);
  if (!parsed.ok) return err(400, parsed.error);
  const { capability, deviceID } = parsed.value;
  return applyChange(deps, capability, deviceID, false, (devices) => devices.filter((d) => d.deviceID !== deviceID));
}

type TransactionOutcome = { rejected: true } | { rejected: false; push: ApnsPush | undefined };

/**
 * A phone document with no devices and nothing delivered carries no information.
 *
 * Accepted risk: if the last device unregisters while another request's push to that phone is
 * still in flight, the document is dropped before that push records its badge, so the phone can
 * keep a stale notification and badge. It needs two requests for one phone to overlap, which a
 * daemon's serial reporting rules out for its own requests, and the app resets its badge from its
 * own count whenever it opens.
 */
function keepOrDrop(state: PhoneState): PhoneState | undefined {
  return state.devices.length === 0 && state.deliveredTotal === 0 ? undefined : state;
}

/**
 * Applies a state change in a transaction, then pushes outside it. The push is decided inside
 * the transaction but sent after commit, because a transaction body may be retried and a push
 * cannot be undone. `deliveredTotal` is advanced in a second transaction only after APNs accepts
 * the push, so a failed send leaves the decision intact and an identical retry sends again.
 * Two near-simultaneous reports can reach APNs out of order; the next report corrects the badge.
 *
 * There is no relay-side rate limit: the daemon only reports on count changes and debounces
 * them, APNs coalesces by collapse id, and the capability is an unguessable bearer, so abuse
 * is bounded to a phone's own daemons.
 */
async function applyChange(
  deps: RelayDeps,
  sealed: string,
  deviceID: string,
  notify: boolean,
  change: (devices: DeviceCounts[]) => DeviceCounts[] | undefined,
): Promise<RelayResponse> {
  const capability = unsealCapability(deps.capabilityKey, sealed);
  if (!capability) return err(401, "invalid_capability");
  const key = phoneKey(capability.installID);

  const outcome = await deps.store.transact<TransactionOutcome>(key, (current) => {
    const devices = change(current?.devices ?? []);
    if (devices === undefined) return { next: current, result: { rejected: true } };
    const next: PhoneState = { devices, deliveredTotal: current?.deliveredTotal ?? 0 };
    const push = decidePush(next.deliveredTotal, sumTotals(next), notify);
    return { next: keepOrDrop(next), result: { rejected: false, push } };
  });
  if (outcome.rejected) return err(400, "too_many_devices");
  if (!outcome.push) return reply(200, { ok: true });
  const { push } = outcome;

  const result = await deps.sender.send(capability.token, capability.env, push);
  if (result.status === "gone") {
    // Only this device's entry goes: after a token rotation, other devices have been reporting
    // through the new token and their counts are still valid.
    await deps.store.transact<void>(key, (current) => {
      const devices = (current?.devices ?? []).filter((d) => d.deviceID !== deviceID);
      // With no devices left, deliveredTotal described a token that no longer exists.
      return { next: current && devices.length > 0 ? { ...current, devices } : undefined, result: undefined };
    });
    return err(410, "apns_unregistered");
  }
  if (result.status === "failed") return err(502, "apns_failed");
  await deps.store.transact<void>(key, (current) => ({
    next: current && keepOrDrop({ ...current, deliveredTotal: push.badge }),
    result: undefined,
  }));
  return reply(200, { ok: true });
}
