import { randomBytes } from "node:crypto";
import type { ApnsResult, ApnsSender } from "../src/apns/sender";
import type { ApnsPush } from "../src/core/decide";
import { handleRequest, type RelayDeps, type RelayResponse } from "../src/core/relay";
import type { ApnsEnvironment } from "../src/core/types";
import { MemoryStore } from "../src/store/memory";

export class FakeSender implements ApnsSender {
  sent: { token: string; env: ApnsEnvironment; push: ApnsPush }[] = [];
  next: ApnsResult = { status: "sent" };
  async send(token: string, env: ApnsEnvironment, push: ApnsPush): Promise<ApnsResult> {
    this.sent.push({ token, env, push });
    return this.next;
  }
}

export const TOKEN = "ab".repeat(32);

/** The paired devices a test phone registers with unless a test lists its own. */
export const PAIRED = ["mac", "linux", "new-daemon", "old-daemon", "a", "b", "c", "d", "ghost"];

export function makeRelay() {
  const store = new MemoryStore();
  const sender = new FakeSender();
  let clock = 1000;
  const deps: RelayDeps = { store, sender, capabilityKey: randomBytes(32), now: () => clock++ };
  const call = (path: string, body: unknown, method = "POST"): Promise<RelayResponse> =>
    handleRequest(deps, { method, path, body });
  const registerRaw = (installID: string, deviceIDs: string[]) =>
    call("/v1/register", { apnsToken: TOKEN, environment: "sandbox", installID, deviceIDs });
  const register = async (installID = "install-1", deviceIDs = PAIRED) => {
    const res = await registerRaw(installID, deviceIDs);
    return res.body.capability as string;
  };
  const report = (capability: string, deviceID: string, total: number, blockedAgents: number, notify: boolean) =>
    call("/v1/report", { capability, deviceID, total, blockedAgents, notify });
  return { store, sender, deps, call, register, registerRaw, report };
}
