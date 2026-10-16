import type { ApnsPush } from "../core/decide";
import type { ApnsEnvironment } from "../core/types";

export type ApnsResult =
  | { status: "sent" }
  /** The token is dead (410, or 400 BadDeviceToken / Unregistered). */
  | { status: "gone"; reason: string }
  | { status: "failed"; reason: string };

export interface ApnsSender {
  send(token: string, environment: ApnsEnvironment, push: ApnsPush): Promise<ApnsResult>;
}
