import test from "node:test";
import assert from "node:assert/strict";
import { start as startEvents } from "../modules/events.js";
import { start as startTraffic } from "../modules/traffic.js";
import { start as startBackups } from "../modules/backups.js";
import { render as renderNetwork } from "../modules/network.js";

// A small stand-in for the page: elements keep their children and the
// properties that the screens set, and an element asked for by name is made.
function node() {
  const kids = [];
  return {
    textContent: "", hidden: false, className: "", value: "", checked: false, disabled: false,
    dataset: {}, style: {}, children: kids, classList: { add() {}, remove() {}, toggle() {} },
    append(...c) { kids.push(...c); },
    replaceChildren(...c) { kids.length = 0; kids.push(...c); },
    querySelectorAll: () => [], querySelector: () => null,
    addEventListener() {}, removeEventListener() {}, setAttribute() {}, remove() {},
  };
}
const page = () => new Proxy({}, { get: (t, k) => (k in t ? t[k] : (t[k] = node())) });
const textOf = (n) => [n.textContent, ...(n.children || []).map(textOf)].join(" ");
const tick = () => new Promise((r) => setTimeout(r, 15));
const fail = (status) => Object.assign(new Error("failed"), { status });

globalThis.document = { createElement: () => node() };
globalThis.window = { location: { protocol: "http:", hostname: "host", port: "" } };

test("Events: with the viewer off the filters and the export are hidden, with events they are back", async () => {
  const els = page();
  els.limit.value = "50";
  const off = startEvents(async () => ({ available: false, reason: "event view is off (EVE_FILE=no)" }), els, () => {});
  await tick();
  off();
  assert.equal(els.filters.hidden, true);
  assert.equal(els.actions.hidden, true);
  assert.match(textOf(els.list), /event view is off/);

  const on = startEvents(async () => ({ available: true, file_present: true, types: ["alert"], events: [] }), els, () => {});
  await tick();
  on();
  assert.equal(els.filters.hidden, false);
  assert.equal(els.actions.hidden, false);
});

test("Traffic: the controls are hidden while there is no event view and shown with data", async () => {
  const els = page();
  const api = (res) => async (path) => {
    if (path === "/api/settings") throw fail(500);
    return res;
  };
  const off = startTraffic(api({ available: false, reason: "event view is off (EVE_FILE=no)" }), els, () => {});
  await tick();
  off();
  assert.equal(els.controls.hidden, true);
  assert.equal(els.body.hidden, true);

  const flow = { id: 1, type: "flow", time: "2026-11-17T09:00:00Z", event: { src_ip: "10.0.0.5", dest_ip: "1.1.1.1", src_port: 5, dest_port: 443, proto: "TCP", flow: { bytes_toserver: 1, bytes_toclient: 2, pkts_toserver: 1, pkts_toclient: 1 } } };
  const on = startTraffic(api({ available: true, file_present: true, types: ["flow"], events: [flow] }), els, () => {});
  await tick();
  on();
  assert.equal(els.controls.hidden, false);
  assert.equal(els.body.hidden, false);
});

test("Backups: a list that cannot be read leaves no loading placeholder behind", async () => {
  const els = page();
  els.list.children.push(node()); // the placeholder of the page
  const stop = startBackups(async () => { throw fail(500); }, els, () => assert.fail("a 500 is not a sign out"));
  await tick();
  stop();
  assert.match(els.error.textContent, /failed/);
  assert.equal(els.list.children.length, 0);
});

test("Network: a speed the host did not report says so, the other parts sit in a card", () => {
  const areas = { topology: node(), others: node(), ifaces: node() };
  const status = { components: [{ id: "ntopng", runtime: "host", state: "active", enabled: true, version: "" }] };
  const system = { hostname: "h", interfaces: [{ name: "eth0", state: "up", rx_bytes: 1, tx_bytes: 1 }] };
  renderNetwork({ status, system, mode: null }, areas);
  assert.match(textOf(areas.ifaces), /not reported/);
  const card = areas.others.children.find((c) => /\bcard\b/.test(c.className));
  assert.ok(card, "the parts are in a card");
  assert.match(textOf(card), /ntopng/);
});
