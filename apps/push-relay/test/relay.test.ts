import assert from "node:assert/strict";
import test from "node:test";
import { phoneKey } from "../src/core/relay";
import { TOKEN, makeRelay } from "./helpers";

test("register returns a capability and stores nothing", async () => {
  const r = makeRelay();
  const res = await r.call("/v1/register", { apnsToken: TOKEN.toUpperCase(), environment: "production", installID: "x" });
  assert.equal(res.status, 200);
  assert.equal(typeof res.body.capability, "string");
  assert.equal(r.store.states.size, 0);
});

test("report stores counts keyed by hashed installID, never the token", async () => {
  const r = makeRelay();
  const cap = await r.register("install-1");
  assert.equal((await r.report(cap, "mac", 2, 1, true)).status, 200);
  const [[key, state]] = [...r.store.states];
  assert.equal(key, phoneKey("install-1"));
  assert.notEqual(key, "install-1");
  assert.ok(!JSON.stringify(state).includes(TOKEN));
  assert.equal(state.devices[0].deviceID, "mac");
  assert.equal(r.sender.sent[0].token, TOKEN);
  assert.equal(r.sender.sent[0].env, "sandbox");
});

test("multi-device totals sum into the badge and body", async () => {
  const r = makeRelay();
  const cap = await r.register();
  await r.report(cap, "mac", 3, 1, true);
  await r.report(cap, "linux", 1, 1, true);
  const aps = (r.sender.sent[1].push.payload as any).aps;
  assert.equal(aps.badge, 4);
  assert.equal(aps.alert.body, "4 alerts, 2 agents need input");
});

test("a repeated report replaces that device's entry", async () => {
  const r = makeRelay();
  const cap = await r.register();
  await r.report(cap, "mac", 3, 0, false);
  await r.report(cap, "mac", 1, 0, false);
  assert.equal([...r.store.states.values()][0].devices.length, 1);
  assert.equal((r.sender.sent[1].push.payload as any).aps.badge, 1);
});

test("badge-only on count change, nothing when unchanged, withdraw at zero", async () => {
  const r = makeRelay();
  const cap = await r.register();
  await r.report(cap, "mac", 2, 0, false);
  assert.equal(r.sender.sent.at(-1)!.push.kind, "badge");
  await r.report(cap, "mac", 2, 1, false);
  assert.equal(r.sender.sent.length, 1);
  await r.report(cap, "mac", 0, 0, false);
  assert.equal(r.sender.sent.at(-1)!.push.kind, "withdraw");
  await r.report(cap, "mac", 0, 0, false);
  assert.equal(r.sender.sent.length, 2);
});

test("concurrent reports from several devices do not lose updates", async () => {
  const r = makeRelay();
  const cap = await r.register();
  await Promise.all(["a", "b", "c", "d"].map((d) => r.report(cap, d, 1, 0, false)));
  assert.equal([...r.store.states.values()][0].devices.length, 4);
});

test("APNs 410 deletes state and answers 410", async () => {
  const r = makeRelay();
  const cap = await r.register();
  await r.report(cap, "mac", 1, 0, false);
  r.sender.next = { status: "gone", reason: "Unregistered" };
  const res = await r.report(cap, "mac", 2, 0, true);
  assert.equal(res.status, 410);
  assert.equal(r.store.states.size, 0);
});

test("APNs transient failure keeps state and answers 502", async () => {
  const r = makeRelay();
  const cap = await r.register();
  r.sender.next = { status: "failed", reason: "timeout" };
  assert.equal((await r.report(cap, "mac", 1, 0, true)).status, 502);
  assert.equal(r.store.states.size, 1);
});

test("unregister removes the device and pushes the recomputed total", async () => {
  const r = makeRelay();
  const cap = await r.register();
  await r.report(cap, "mac", 3, 0, false);
  await r.report(cap, "linux", 2, 0, false);
  let res = await r.call("/v1/unregister", { capability: cap, deviceID: "mac" });
  assert.equal(res.status, 200);
  assert.equal(r.sender.sent.at(-1)!.push.kind, "badge");
  assert.equal((r.sender.sent.at(-1)!.push.payload as any).aps.badge, 2);
  res = await r.call("/v1/unregister", { capability: cap, deviceID: "linux" });
  assert.equal(r.sender.sent.at(-1)!.push.kind, "withdraw");
  assert.equal(r.store.states.size, 0);
  const before = r.sender.sent.length;
  await r.call("/v1/unregister", { capability: cap, deviceID: "ghost" });
  assert.equal(r.sender.sent.length, before);
});

test("invalid or foreign capabilities are 401", async () => {
  const r = makeRelay();
  const other = makeRelay();
  const foreign = await other.register();
  for (const cap of ["junk", foreign]) {
    assert.equal((await r.report(cap, "mac", 1, 0, true)).status, 401);
    assert.equal((await r.call("/v1/unregister", { capability: cap, deviceID: "mac" })).status, 401);
  }
  assert.equal(r.sender.sent.length, 0);
});

test("strict input validation", async () => {
  const r = makeRelay();
  const cap = await r.register();
  const ok = { capability: cap, deviceID: "mac", total: 2, blockedAgents: 1, notify: true };
  const bad: Record<string, unknown>[] = [
    { ...ok, total: -1 },
    { ...ok, total: 1.5 },
    { ...ok, total: "2" },
    { ...ok, blockedAgents: 3 },
    { ...ok, blockedAgents: -1 },
    { ...ok, notify: "true" },
    { ...ok, notify: undefined },
    { ...ok, deviceID: "" },
    { ...ok, deviceID: "x".repeat(129) },
    { ...ok, capability: 5 },
  ];
  for (const body of bad) assert.equal((await r.call("/v1/report", body)).status, 400, JSON.stringify(body));
  assert.equal((await r.call("/v1/report", ok)).status, 200);

  const reg = { apnsToken: TOKEN, environment: "sandbox", installID: "i" };
  for (const body of [
    { ...reg, apnsToken: "zz" },
    { ...reg, apnsToken: "ab" },
    { ...reg, environment: "dev" },
    { ...reg, installID: "" },
    { ...reg, installID: "i".repeat(129) },
  ]) {
    assert.equal((await r.call("/v1/register", body)).status, 400, JSON.stringify(body));
  }
  assert.equal((await r.call("/v1/unregister", { capability: cap })).status, 400);
});

test("routing: unknown path 404, wrong method 405, non-object body 400", async () => {
  const r = makeRelay();
  assert.equal((await r.call("/v1/nope", {})).status, 404);
  assert.equal((await r.call("/v1/report", {}, "GET")).status, 405);
  assert.equal((await r.call("/v1/report", [])).status, 400);
  assert.equal((await r.call("/v1/report", null)).status, 400);
});

test("a phone cannot grow unbounded device entries", async () => {
  const r = makeRelay();
  const cap = await r.register();
  for (let i = 0; i < 64; i++) await r.report(cap, `d${i}`, 0, 0, false);
  assert.equal((await r.report(cap, "one-too-many", 1, 0, false)).status, 400);
  assert.equal((await r.report(cap, "d0", 1, 0, false)).status, 200);
});

test("a failed send is retried by an identical report", async () => {
  const r = makeRelay();
  const cap = await r.register();
  r.sender.next = { status: "failed", reason: "timeout" };
  assert.equal((await r.report(cap, "mac", 2, 0, false)).status, 502);
  r.sender.next = { status: "sent" };
  assert.equal((await r.report(cap, "mac", 2, 0, false)).status, 200);
  assert.equal(r.sender.sent.length, 2);
  assert.equal(r.sender.sent[1].push.kind, "badge");
  // Delivered now, so a third identical report is a no-op.
  await r.report(cap, "mac", 2, 0, false);
  assert.equal(r.sender.sent.length, 2);
});

test("a failed withdraw on unregister is retried", async () => {
  const r = makeRelay();
  const cap = await r.register();
  await r.report(cap, "mac", 2, 0, false);
  r.sender.next = { status: "failed", reason: "timeout" };
  assert.equal((await r.call("/v1/unregister", { capability: cap, deviceID: "mac" })).status, 502);
  r.sender.next = { status: "sent" };
  assert.equal((await r.call("/v1/unregister", { capability: cap, deviceID: "mac" })).status, 200);
  assert.deepEqual(r.sender.sent.slice(-2).map((s) => s.push.kind), ["withdraw", "withdraw"]);
  assert.equal(r.store.states.size, 0);
});

test("410 removes only the reporting device's entry", async () => {
  const r = makeRelay();
  const cap = await r.register();
  await r.report(cap, "new-daemon", 2, 0, false);
  r.sender.next = { status: "sent" };
  await r.report(cap, "old-daemon", 1, 0, false);
  r.sender.next = { status: "gone", reason: "BadDeviceToken" };
  assert.equal((await r.report(cap, "old-daemon", 3, 0, true)).status, 410);
  const devices = [...r.store.states.values()][0].devices;
  assert.deepEqual(devices.map((d) => d.deviceID), ["new-daemon"]);
});
