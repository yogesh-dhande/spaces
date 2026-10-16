import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import test from "node:test";
import { parseCapabilityKey, sealCapability, unsealCapability } from "../src/core/seal";
import type { Capability } from "../src/core/types";

const cap: Capability = { v: 1, token: "ab".repeat(32), env: "production", installID: "i-1" };

test("seal round-trips and is nondeterministic", () => {
  const key = randomBytes(32);
  const a = sealCapability(key, cap);
  assert.deepEqual(unsealCapability(key, a), cap);
  assert.notEqual(a, sealCapability(key, cap));
  assert.ok(!a.includes(cap.token));
});

test("tampered, truncated, wrong-key and garbage capabilities are rejected", () => {
  const key = randomBytes(32);
  const sealed = sealCapability(key, cap);
  const raw = Buffer.from(sealed, "base64url");
  for (const i of [0, 12, raw.length - 1]) {
    const bad = Buffer.from(raw);
    bad[i] ^= 1;
    assert.equal(unsealCapability(key, bad.toString("base64url")), undefined);
  }
  assert.equal(unsealCapability(key, sealed.slice(0, 10)), undefined);
  assert.equal(unsealCapability(randomBytes(32), sealed), undefined);
  assert.equal(unsealCapability(key, "!!not base64!!"), undefined);
  assert.equal(unsealCapability(key, ""), undefined);
});

test("capability key must be 32 bytes of base64", () => {
  assert.equal(parseCapabilityKey(randomBytes(32).toString("base64") + "\n").length, 32);
  assert.throws(() => parseCapabilityKey(randomBytes(16).toString("base64")));
});
