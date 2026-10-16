import { initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { defineSecret } from "firebase-functions/params";
import { onRequest } from "firebase-functions/v2/https";
import { Http2ApnsSender } from "./apns/http2";
import { parseCapabilityKey } from "./core/seal";
import { handleRequest, type RelayDeps } from "./core/relay";
import { FirestoreStore } from "./store/firestore";

/** The iOS app target's bundle id (apps/ios/project.yml). */
const APNS_TOPIC = "dev.usespaces.spacesmobile";

const APNS_KEY_P8 = defineSecret("APNS_KEY_P8");
const APNS_KEY_ID = defineSecret("APNS_KEY_ID");
const APNS_TEAM_ID = defineSecret("APNS_TEAM_ID");
const CAPABILITY_KEY = defineSecret("CAPABILITY_KEY");

initializeApp();

// Built on first request so secrets are available, then reused across requests on the instance
// to keep the APNs HTTP/2 sessions and provider JWT warm.
let deps: RelayDeps | undefined;
function getDeps(): RelayDeps {
  deps ??= {
    store: new FirestoreStore(getFirestore()),
    sender: new Http2ApnsSender({
      keyP8: APNS_KEY_P8.value(),
      keyID: APNS_KEY_ID.value().trim(),
      teamID: APNS_TEAM_ID.value().trim(),
      topic: APNS_TOPIC,
    }),
    capabilityKey: parseCapabilityKey(CAPABILITY_KEY.value()),
    now: () => Date.now(),
  };
  return deps;
}

export const pushRelay = onRequest(
  {
    region: "us-central1",
    secrets: [APNS_KEY_P8, APNS_KEY_ID, APNS_TEAM_ID, CAPABILITY_KEY],
    maxInstances: 10,
    // Daemons call from anywhere and authenticate with the capability, not IAM.
    invoker: "public",
  },
  async (req, res) => {
    try {
      const result = await handleRequest(getDeps(), { method: req.method, path: req.path, body: req.body });
      res.status(result.status).json(result.body);
    } catch (e) {
      console.error("relay error", e instanceof Error ? e.message : "unknown");
      res.status(500).json({ error: "internal" });
    }
  },
);
