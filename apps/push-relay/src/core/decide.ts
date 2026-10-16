import type { PhoneState, Totals } from "./types";

export const COLLAPSE_ID = "spaces-alerts";

export function sumTotals(state: PhoneState | undefined): Totals {
  let total = 0;
  let blockedAgents = 0;
  for (const d of state?.devices ?? []) {
    total += d.total;
    blockedAgents += d.blockedAgents;
  }
  return { total, blockedAgents };
}

/** "4 alerts, 1 agent needs input" / "2 agents need input" rule; the blocked clause only when B > 0. */
export function bodyText({ total, blockedAgents }: Totals): string {
  let text = `${total} ${total === 1 ? "alert" : "alerts"}`;
  if (blockedAgents > 0) {
    text += `, ${blockedAgents} ${blockedAgents === 1 ? "agent needs" : "agents need"} input`;
  }
  return text;
}

export type PushKind = "alert" | "badge" | "withdraw";

export interface ApnsPush {
  kind: PushKind;
  /** apns-push-type header. */
  pushType: "alert";
  /** apns-priority header. */
  priority: 10 | 5;
  collapseId: string;
  /** The badge total the phone holds once this push is delivered. */
  badge: number;
  payload: Record<string, unknown>;
}

/**
 * Decides what to send after a state change. `deliveredTotal` is the badge total of the last
 * push APNs accepted; every push carries the absolute total, so nothing else is remembered.
 */
export function decidePush(deliveredTotal: number, totals: Totals, notify: boolean): ApnsPush | undefined {
  const { total } = totals;
  if (total === 0) {
    return deliveredTotal > 0 ? withdrawPush() : undefined;
  }
  if (notify) return alertPush(totals);
  if (total !== deliveredTotal) return badgePush(total);
  return undefined;
}

function alertPush(totals: Totals): ApnsPush {
  return {
    kind: "alert",
    pushType: "alert",
    priority: 10,
    collapseId: COLLAPSE_ID,
    badge: totals.total,
    payload: {
      aps: {
        alert: { title: "Spaces", body: bodyText(totals) },
        badge: totals.total,
        sound: "default",
        "interruption-level": "active",
      },
    },
  };
}

// An aps dictionary holding only `badge` updates the icon without showing anything.
function badgePush(total: number): ApnsPush {
  return {
    kind: "badge",
    pushType: "alert",
    priority: 10,
    collapseId: COLLAPSE_ID,
    badge: total,
    payload: { aps: { badge: total } },
  };
}

// APNs rejects badge, alert and sound keys in a background-type push, so the withdraw is an
// alert-type push with no alert: it sets the badge to 0 and, via content-available, wakes the app
// to remove the delivered notification when it sees `spaces.withdraw`.
function withdrawPush(): ApnsPush {
  return {
    kind: "withdraw",
    pushType: "alert",
    priority: 10,
    collapseId: COLLAPSE_ID,
    badge: 0,
    payload: { aps: { badge: 0, "content-available": 1 }, spaces: { withdraw: true } },
  };
}
