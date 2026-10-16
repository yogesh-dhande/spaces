import type { ApnsEnvironment } from "./types";

export const MAX_ID_LENGTH = 128;
export const MAX_COUNT = 1_000_000;
/** Bounds per-phone document growth; a phone pairs with a handful of daemons. */
export const MAX_DEVICES_PER_PHONE = 64;

export type Parsed<T> = { ok: true; value: T } | { ok: false; error: string };

type Body = Record<string, unknown>;

const fail = (error: string): { ok: false; error: string } => ({ ok: false, error });

function id(body: Body, field: string): string | undefined {
  const v = body[field];
  return typeof v === "string" && v.length >= 1 && v.length <= MAX_ID_LENGTH ? v : undefined;
}

function count(body: Body, field: string): number | undefined {
  const v = body[field];
  return typeof v === "number" && Number.isInteger(v) && v >= 0 && v <= MAX_COUNT ? v : undefined;
}

export function parseRegister(
  body: Body,
): Parsed<{ apnsToken: string; environment: ApnsEnvironment; installID: string }> {
  const token = body.apnsToken;
  // APNs tokens are 32 bytes today; the range leaves room for longer ones.
  if (typeof token !== "string" || !/^[0-9a-fA-F]{64,200}$/.test(token)) return fail("invalid_apnsToken");
  const environment = body.environment;
  if (environment !== "sandbox" && environment !== "production") return fail("invalid_environment");
  const installID = id(body, "installID");
  if (installID === undefined) return fail("invalid_installID");
  return { ok: true, value: { apnsToken: token.toLowerCase(), environment, installID } };
}

export function parseReport(
  body: Body,
): Parsed<{ capability: string; deviceID: string; total: number; blockedAgents: number; notify: boolean }> {
  if (typeof body.capability !== "string" || body.capability.length === 0 || body.capability.length > 2048) {
    return fail("invalid_capability");
  }
  const deviceID = id(body, "deviceID");
  if (deviceID === undefined) return fail("invalid_deviceID");
  const total = count(body, "total");
  if (total === undefined) return fail("invalid_total");
  const blockedAgents = count(body, "blockedAgents");
  if (blockedAgents === undefined || blockedAgents > total) return fail("invalid_blockedAgents");
  if (typeof body.notify !== "boolean") return fail("invalid_notify");
  return { ok: true, value: { capability: body.capability, deviceID, total, blockedAgents, notify: body.notify } };
}

export function parseUnregister(body: Body): Parsed<{ capability: string; deviceID: string }> {
  if (typeof body.capability !== "string" || body.capability.length === 0 || body.capability.length > 2048) {
    return fail("invalid_capability");
  }
  const deviceID = id(body, "deviceID");
  if (deviceID === undefined) return fail("invalid_deviceID");
  return { ok: true, value: { capability: body.capability, deviceID } };
}
