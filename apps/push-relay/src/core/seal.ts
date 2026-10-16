import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";
import type { Capability } from "./types";

const NONCE_BYTES = 12;
const TAG_BYTES = 16;

/** Parses the CAPABILITY_KEY secret: base64 of exactly 32 bytes (`openssl rand -base64 32`). */
export function parseCapabilityKey(secret: string): Buffer {
  const key = Buffer.from(secret.trim(), "base64");
  if (key.length !== 32) {
    throw new Error("CAPABILITY_KEY must be base64 of exactly 32 bytes");
  }
  return key;
}

/** Seals to base64url of nonce(12) | ciphertext | GCM tag(16). */
export function sealCapability(key: Buffer, capability: Capability): string {
  const nonce = randomBytes(NONCE_BYTES);
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  const body = Buffer.concat([cipher.update(JSON.stringify(capability), "utf8"), cipher.final()]);
  return Buffer.concat([nonce, body, cipher.getAuthTag()]).toString("base64url");
}

/** Returns undefined for anything that is not an authentic, well-formed v1 capability. */
export function unsealCapability(key: Buffer, sealed: string): Capability | undefined {
  try {
    const raw = Buffer.from(sealed, "base64url");
    if (raw.length < NONCE_BYTES + TAG_BYTES + 1) return undefined;
    const decipher = createDecipheriv("aes-256-gcm", key, raw.subarray(0, NONCE_BYTES));
    decipher.setAuthTag(raw.subarray(raw.length - TAG_BYTES));
    const plain = Buffer.concat([
      decipher.update(raw.subarray(NONCE_BYTES, raw.length - TAG_BYTES)),
      decipher.final(),
    ]);
    const value = JSON.parse(plain.toString("utf8"));
    if (
      value?.v !== 1 ||
      typeof value.token !== "string" ||
      typeof value.installID !== "string" ||
      (value.env !== "sandbox" && value.env !== "production")
    ) {
      return undefined;
    }
    return { v: 1, token: value.token, env: value.env, installID: value.installID };
  } catch {
    return undefined;
  }
}
