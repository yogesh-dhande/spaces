import assert from "node:assert/strict";
import test from "node:test";
import { bodyText, decidePush } from "../src/core/decide";

test("body text rule", () => {
  assert.equal(bodyText({ total: 1, blockedAgents: 0 }), "1 alert");
  assert.equal(bodyText({ total: 4, blockedAgents: 0 }), "4 alerts");
  assert.equal(bodyText({ total: 4, blockedAgents: 1 }), "4 alerts, 1 agent needs input");
  assert.equal(bodyText({ total: 2, blockedAgents: 2 }), "2 alerts, 2 agents need input");
  assert.equal(bodyText({ total: 1, blockedAgents: 1 }), "1 alert, 1 agent needs input");
});

test("notify sends a collapsed alert push even when the total is unchanged", () => {
  const p = decidePush(3, { total: 3, blockedAgents: 1 }, true)!;
  assert.equal(p.kind, "alert");
  assert.equal(p.pushType, "alert");
  assert.equal(p.collapseId, "spaces-alerts");
  assert.deepEqual(p.payload, {
    aps: {
      alert: { title: "Spaces", body: "3 alerts, 1 agent needs input" },
      badge: 3,
      sound: "default",
      "interruption-level": "active",
    },
  });
});

test("count change without notify is a badge-only update", () => {
  const p = decidePush(3, { total: 2, blockedAgents: 0 }, false)!;
  assert.equal(p.kind, "badge");
  assert.equal(p.pushType, "alert");
  assert.deepEqual(p.payload, { aps: { badge: 2 } });
  assert.equal(p.collapseId, "spaces-alerts");
});

test("drop to zero withdraws with a silent badge-clearing push, even when notify is set", () => {
  for (const notify of [false, true]) {
    const p = decidePush(2, { total: 0, blockedAgents: 0 }, notify)!;
    assert.equal(p.kind, "withdraw");
    // APNs forbids badge keys in a background-type push, so the withdraw is an alert-type push.
    assert.equal(p.pushType, "alert");
    assert.equal(p.priority, 10);
    assert.equal(p.collapseId, "spaces-alerts");
    assert.deepEqual(p.payload, {
      aps: { badge: 0, "content-available": 1 },
      spaces: { withdraw: true },
    });
  }
});

test("no change and no notify sends nothing; zero stays silent", () => {
  assert.equal(decidePush(3, { total: 3, blockedAgents: 1 }, false), undefined);
  assert.equal(decidePush(0, { total: 0, blockedAgents: 0 }, false), undefined);
  assert.equal(decidePush(0, { total: 0, blockedAgents: 0 }, true), undefined);
});
