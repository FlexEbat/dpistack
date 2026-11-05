import { test } from "node:test";
import assert from "node:assert/strict";
import { alertsOf, since, severityCounts, captureLoss, stateCards, warnings } from "../modules/overview-model.js";

const ev = (id, time, sev, sig = "ET TEST") => ({ id, time, type: "alert", event: { alert: { signature: sig, severity: sev }, src_ip: "10.0.0.1", dest_ip: "10.0.0.2" } });
const now = Date.parse("2026-11-05T12:00:00Z");

test("alerts: an off viewer or a missing answer is null, not an empty list", () => {
  assert.equal(alertsOf(undefined), null);
  assert.equal(alertsOf({ available: false, events: [] }), null);
  assert.deepEqual(alertsOf({ available: true, events: [] }), []);
});

test("alerts carry a severity from 1 to 3, anything else is unknown", () => {
  const a = alertsOf({ available: true, events: [ev(1, "2026-11-05T11:00:00Z", 1), ev(2, "x", 9), { id: 3, event: {} }] });
  assert.deepEqual(a.map((x) => x.severity), [1, 0, 0]);
  assert.match(a[0].text, /ET TEST/);
});

test("the last 24 hours leave out older alerts and alerts without a time", () => {
  const a = alertsOf({ available: true, events: [ev(1, "2026-11-05T11:00:00Z", 1), ev(2, "2026-11-03T11:00:00Z", 1), ev(3, "", 1)] });
  assert.deepEqual(since(a, 24 * 3600 * 1000, now).map((x) => x.id), [1]);
});

test("severity counts", () => {
  const a = alertsOf({ available: true, events: [ev(1, "t", 1), ev(2, "t", 2), ev(3, "t", 2), ev(4, "t", 3), ev(5, "t", 7)] });
  assert.deepEqual(severityCounts(a), { high: 1, medium: 2, low: 1, unknown: 1 });
});

test("capture loss is unknown when the host did not flag any interface", () => {
  assert.equal(captureLoss(undefined), null);
  assert.equal(captureLoss({ interfaces: [{ name: "eth0" }] }), null);
  assert.deepEqual(captureLoss({ interfaces: [{ capture: true, rx_dropped: 3, tx_dropped: 4 }, { capture: false, rx_dropped: 100 }] }), { interfaces: 1, dropped: 7 });
});

const status = { components: [
  { id: "suricata", state: "active", enabled: true },
  { id: "evebox", state: "failed", enabled: true },
  { id: "ntopng", state: "inactive", enabled: true },
  { id: "redis", state: "absent", enabled: false },
] };

test("the four cards: a source that did not answer gives no card", () => {
  const system = { interfaces: [{ capture: true, rx_dropped: 0, tx_dropped: 0 }] };
  const alerts = alertsOf({ available: true, events: [ev(1, "2026-11-05T11:00:00Z", 1)] });
  const cards = stateCards({ status, system, mode: { mode: "ips", method: "nfqueue", pending: false }, alerts, now });
  assert.deepEqual(cards.map((c) => c.label), ["Protection", "Components", "Alerts, 24 h", "Packets lost"]);
  assert.equal(cards[0].value, "IPS");
  assert.equal(cards[1].value, "1 of 3");
  assert.equal(cards[1].level, "crit");
  assert.equal(cards[2].note, "1 high severity");
  assert.equal(cards[3].level, "ok");
  assert.deepEqual(stateCards({ now }), []);
});

test("a pending IPS switch is a warning and no capture interface is said so", () => {
  const cards = stateCards({ status: { components: [] }, system: { interfaces: [{ capture: false }] }, mode: { mode: "ips", pending: true }, now });
  assert.equal(cards[0].level, "warn");
  assert.equal(cards.at(-1).value, "none");
});

test("warnings name what needs a look and nothing else", () => {
  const system = { interfaces: [{ capture: true, rx_dropped: 5, tx_dropped: 0 }], disks: [{ path: "/", total_bytes: 100, free_bytes: 5 }, { path: "/var/log", total_bytes: 100, free_bytes: 90 }] };
  const w = warnings({ status, system });
  assert.deepEqual(w, ["evebox has failed.", "ntopng is stopped but set to start on boot.", "5 packets were dropped on the capture interfaces since boot.", "The disk / is more than 90 % full."]);
  assert.deepEqual(warnings({ status: { components: [{ id: "suricata", state: "active", enabled: true }] }, system: { interfaces: [{ capture: false }] } }), ["Suricata is running but no interface is set to be captured."]);
  assert.deepEqual(warnings({}), []);
});

test("the watchdog's rules age and eve checks are warnings, the others are left to the screen", () => {
  const health = { checks: [
    { id: "rules.age", status: "warn", detail: "rules are 9.00 days old" },
    { id: "suricata.eve_fresh", status: "crit", detail: "no new events for 400 s" },
    { id: "disk.free", status: "crit", detail: "disk /var is full" },
    { id: "process.suricata", status: "crit", detail: "not running" },
    { id: "rules.age_x", status: "warn", detail: "other" },
  ] };
  assert.deepEqual(warnings({ status: { components: [] }, health }), ["Rules are 9.00 days old.", "No new events for 400 s."]);
  assert.deepEqual(warnings({ status: { components: [] }, health: { checks: [{ id: "rules.age", status: "ok", detail: "" }, { id: "rules.age", status: "na", detail: "rule updates are off" }] } }), []);
  assert.deepEqual(warnings({ status: { components: [] }, health: null }), []);
});
