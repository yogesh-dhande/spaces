import { createPrivateKey, sign, type KeyObject } from "node:crypto";
import http2 from "node:http2";
import type { ApnsPush } from "../core/decide";
import type { ApnsEnvironment } from "../core/types";
import type { ApnsResult, ApnsSender } from "./sender";

const HOSTS: Record<ApnsEnvironment, string> = {
  production: "api.push.apple.com",
  sandbox: "api.sandbox.push.apple.com",
};

// APNs rejects provider tokens older than 60 minutes and throttles refreshing more often than
// every 20, so reuse one for 50.
const JWT_TTL_MS = 50 * 60 * 1000;
const REQUEST_TIMEOUT_MS = 10_000;

export interface ApnsCredentials {
  keyP8: string;
  keyID: string;
  teamID: string;
  topic: string;
}

export class Http2ApnsSender implements ApnsSender {
  private readonly key: KeyObject;
  private jwt: { value: string; issuedAt: number } | undefined;
  private readonly sessions = new Map<ApnsEnvironment, http2.ClientHttp2Session>();

  constructor(private readonly creds: ApnsCredentials) {
    this.key = createPrivateKey(creds.keyP8);
  }

  private providerToken(now = Date.now()): string {
    if (this.jwt && now - this.jwt.issuedAt < JWT_TTL_MS) return this.jwt.value;
    const b64 = (o: object) => Buffer.from(JSON.stringify(o)).toString("base64url");
    const input = `${b64({ alg: "ES256", kid: this.creds.keyID })}.${b64({
      iss: this.creds.teamID,
      iat: Math.floor(now / 1000),
    })}`;
    // APNs wants the raw r|s signature (IEEE P1363), not DER.
    const signature = sign("sha256", Buffer.from(input), { key: this.key, dsaEncoding: "ieee-p1363" });
    this.jwt = { value: `${input}.${signature.toString("base64url")}`, issuedAt: now };
    return this.jwt.value;
  }

  private session(env: ApnsEnvironment): http2.ClientHttp2Session {
    const existing = this.sessions.get(env);
    if (existing && !existing.closed && !existing.destroyed) return existing;
    const session = http2.connect(`https://${HOSTS[env]}`);
    const drop = () => {
      if (this.sessions.get(env) === session) this.sessions.delete(env);
    };
    session.on("error", drop);
    session.on("close", drop);
    session.on("goaway", drop);
    this.sessions.set(env, session);
    return session;
  }

  send(token: string, env: ApnsEnvironment, push: ApnsPush): Promise<ApnsResult> {
    return new Promise((resolve) => {
      let settled = false;
      const done = (r: ApnsResult) => {
        if (!settled) {
          settled = true;
          resolve(r);
        }
      };
      try {
        const req = this.session(env).request({
          ":method": "POST",
          ":path": `/3/device/${token}`,
          authorization: `bearer ${this.providerToken()}`,
          "apns-topic": this.creds.topic,
          "apns-push-type": push.pushType,
          "apns-priority": String(push.priority),
          "apns-collapse-id": push.collapseId,
          "content-type": "application/json",
        });
        req.setTimeout(REQUEST_TIMEOUT_MS, () => {
          req.close(http2.constants.NGHTTP2_CANCEL);
          done({ status: "failed", reason: "timeout" });
        });
        let status = 0;
        let data = "";
        req.on("response", (headers) => {
          status = Number(headers[":status"]);
        });
        req.setEncoding("utf8");
        req.on("data", (chunk) => (data += chunk));
        req.on("error", (e) => done({ status: "failed", reason: e.message }));
        req.on("end", () => {
          if (status === 200) return done({ status: "sent" });
          let reason = "";
          try {
            reason = JSON.parse(data).reason ?? "";
          } catch {
            // Non-JSON error bodies carry no reason.
          }
          if (status === 410 || reason === "Unregistered" || reason === "BadDeviceToken") {
            return done({ status: "gone", reason: reason || String(status) });
          }
          // A rejected provider token must not stay cached for its full TTL.
          if (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken") this.jwt = undefined;
          done({ status: "failed", reason: reason || String(status) });
        });
        req.end(JSON.stringify(push.payload));
      } catch (e) {
        done({ status: "failed", reason: e instanceof Error ? e.message : "send_error" });
      }
    });
  }
}
