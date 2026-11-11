import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { actionsFor, query, summaryLine, stateDetail, seenText, decisions, bodyFor, stateWord, severityLevel, stateLevel, sourceWord, actionWord } from "../modules/alertcenter-model.js";
import { start } from "../modules/alertcenter.js";
import { bellChip, start as startTop } from "../modules/topbar.js";

const here = (f) => readFileSync(new URL("../" + f, import.meta.url), "utf8");

test("the actions fit the state: a cleared alert is dismissed, not reopened", () => {
  const names = (a) => actionsFor(a).map((x) => x.action);
  assert.deepEqual(names({ state: "new" }), ["ack", "snooze", "resolve"]);
  assert.deepEqual(names({ state: "acknowledged" }), ["snooze", "resolve", "reopen"]);
  assert.deepEqual(names({ state: "snoozed" }), ["ack", "resolve", "reopen"]);
  assert.deepEqual(actionsFor({ state: "resolved", cleared: true }), [{ action: "reopen", label: "Dismiss" }]);
  assert.deepEqual(actionsFor({ state: "resolved", cleared: false }), [{ action: "reopen", label: "Reopen" }]);
  assert.deepEqual(actionsFor({ state: "weird" }), []);
  assert.deepEqual(actionsFor(null), []);
});

test("words and levels", () => {
  assert.equal(stateWord("acknowledged"), "Acknowledged");
  assert.equal(severityLevel("crit"), "crit");
  assert.equal(severityLevel("info"), "na");
  assert.equal(stateLevel("resolved"), "ok");
  assert.equal(sourceWord({ source: "suricata" }), "Suricata");
  assert.equal(sourceWord({ source: "watchdog" }), "Watchdog");
  assert.equal(actionWord("ack"), "acknowledged");
});

test("the query leaves empty filters out", () => {
  assert.equal(query({ state: "", source: "", severity: "" }), "");
  assert.equal(query({ state: "new", source: "suricata", severity: "" }), "?state=new&source=suricata");
  assert.equal(query(null), "");
});

test("the summary line and the state detail", () => {
  assert.equal(summaryLine({ new: 3, new_crit: 1, acknowledged: 2, snoozed: 1, resolved: 4 }), "3 new (1 critical), 2 acknowledged, 1 snoozed, 4 resolved");
  assert.equal(summaryLine(null), "");
  assert.equal(stateDetail({ state: "acknowledged", by: "admin", note: "ticket 7" }), "by admin, ticket 7");
  assert.match(stateDetail({ state: "snoozed", until: 1767229200, by: "a" }), /^until .*, by a$/);
  assert.equal(stateDetail({ state: "resolved", cleared: true }), "cleared on its own");
  assert.equal(stateDetail({ state: "new" }), "");
});

test("seen text says how many times for a Suricata alert and reads its time zone form", () => {
  assert.match(seenText({ count: 3, last_seen: "2026-01-01T00:00:30.000000+0000" }), /^3 times, last /);
  assert.match(seenText({ count: 1, last_seen: "2026-01-01T00:00:30.000000+0000" }), /^1 time, last /);
  assert.doesNotMatch(seenText({ count: 1, last_seen: "2026-01-01T00:00:30.000000+0000" }), /Invalid/);
  assert.match(seenText({ count: null, last_seen: "2026-01-01T00:00:00Z" }), /2026|01/);
});

test("decisions keep what people did and drop the watchdog's status changes", () => {
  assert.deepEqual(decisions({ history: [{ kind: "event" }, { kind: "action", key: "a" }] }), [{ kind: "action", key: "a" }]);
  assert.deepEqual(decisions(null), []);
});

test("the request body: snooze carries its time, the note is optional and checked", () => {
  assert.deepEqual(bodyFor("ack", "sid:1", "", "").body, { action: "ack", key: "sid:1" });
  assert.deepEqual(bodyFor("snooze", "sid:1", "4h", "later").body, { action: "snooze", key: "sid:1", for: "4h", note: "later" });
  assert.match(bodyFor("ack", "sid:1", "", 'a"b').error, /80 characters/);
  assert.match(bodyFor("ack", "sid:1", "", "x".repeat(81)).error, /80 characters/);
});

// A small DOM: elements with children, listeners, value and dataset.
function fakeDom() {
  const make = (tag) => ({
    tag, className: "", textContent: "", children: [], value: "", listeners: {}, attrs: {},
    append(...c) { this.children.push(...c); },
    replaceChildren(...c) { this.children = c; },
    setAttribute(k, v) { this.attrs[k] = v; },
    addEventListener(n, f) { this.listeners[n] = f; },
    removeEventListener(n) { delete this.listeners[n]; },
  });
  globalThis.document = { createElement: make, hidden: false };
  const areas = {};
  for (const k of ["error", "summary", "list", "history"]) areas[k] = make("div");
  for (const k of ["state", "source", "severity", "note", "refresh"]) areas[k] = make("input");
  return areas;
}

function find(node, pred, out = []) {
  if (pred(node)) out.push(node);
  for (const c of node.children || []) find(c, pred, out);
  return out;
}

const alertsDoc = {
  alerts: [
    { key: "watch:disk.free", source: "watchdog", severity: "crit", title: "disk.free", detail: "2%", state: "new", count: null, last_seen: "2026-01-01T00:00:00Z" },
    { key: "sid:100", source: "suricata", severity: "warn", title: "ET one", detail: "Cat", state: "acknowledged", by: "admin", count: 3, last_seen: "2026-01-01T00:00:30.000000+0000" },
  ],
  counts: { new: 1, acknowledged: 1, snoozed: 0, resolved: 0, new_crit: 1 },
};
const historyDoc = { history: [{ ts: "2026-01-01T00:00:00Z", kind: "action", key: "sid:100", action: "ack", by: "admin", note: "seen", title: "ET one" }, { ts: "x", kind: "event" }] };
const wait = () => new Promise((r) => setTimeout(r, 10));

test("the screen draws the summary, the alerts and the decisions", async () => {
  const areas = fakeDom();
  const stop = start(async (p) => (p.startsWith("/api/alert-center/history") ? historyDoc : alertsDoc), areas, () => assert.fail(), true);
  await wait();
  stop();
  assert.equal(areas.summary.textContent, "1 new (1 critical), 1 acknowledged, 0 snoozed, 0 resolved");
  assert.equal(find(areas.list, (n) => n.tag === "tr").length, 3, "a header and two alerts");
  assert.equal(find(areas.history, (n) => n.tag === "tr").length, 2, "a header and the one decision");
});

test("without the permission there are no buttons", async () => {
  const areas = fakeDom();
  const stop = start(async (p) => (p.startsWith("/api/alert-center/history") ? historyDoc : alertsDoc), areas, () => assert.fail(), false);
  await wait();
  stop();
  assert.equal(find(areas.list, (n) => n.tag === "button").length, 0);
});

test("a click posts the decision with the note and reads the list again", async () => {
  const areas = fakeDom();
  const calls = [];
  const api = async (p, o) => {
    calls.push([p, o && o.method, o && o.body]);
    return p.startsWith("/api/alert-center/history") ? historyDoc : p === "/api/alert-center" && o ? { ok: true } : alertsDoc;
  };
  const stop = start(api, areas, () => assert.fail(), true);
  await wait();
  areas.note.value = "  ticket 7  ";
  const ack = find(areas.list, (n) => n.tag === "button" && n.textContent === "Acknowledge")[0];
  await ack.listeners.click();
  const post = calls.find((c) => c[1] === "POST");
  assert.deepEqual(JSON.parse(post[2]), { action: "ack", key: "watch:disk.free", note: "ticket 7" });
  assert.equal(areas.note.value, "", "the note is cleared after a change");
  assert.ok(calls.filter((c) => c[0] === "/api/alert-center").length >= 3, "the list is read again after the change");
  stop();
});

test("snooze sends the time chosen next to its button", async () => {
  const areas = fakeDom();
  let body;
  const api = async (p, o) => {
    if (o && o.method === "POST") { body = JSON.parse(o.body); return { ok: true }; }
    return p.startsWith("/api/alert-center/history") ? historyDoc : alertsDoc;
  };
  const stop = start(api, areas, () => assert.fail(), true);
  await wait();
  const row = find(areas.list, (n) => n.tag === "tr")[1];
  const sel = find(row, (n) => n.tag === "select")[0];
  sel.value = "24h";
  await find(row, (n) => n.tag === "button" && n.textContent === "Snooze")[0].listeners.click();
  stop();
  assert.deepEqual(body, { action: "snooze", key: "watch:disk.free", for: "24h" });
});

test("a bad note is refused before any request", async () => {
  const areas = fakeDom();
  let posts = 0;
  const api = async (p, o) => { if (o && o.method === "POST") posts++; return p.startsWith("/api/alert-center/history") ? historyDoc : alertsDoc; };
  const stop = start(api, areas, () => assert.fail(), true);
  await wait();
  areas.note.value = 'a"b';
  await find(areas.list, (n) => n.tag === "button" && n.textContent === "Acknowledge")[0].listeners.click();
  stop();
  assert.equal(posts, 0);
  assert.match(areas.error.textContent, /80 characters/);
});

test("a failing read shows its message, a refused change shows the server's words, a 401 is passed on", async () => {
  let areas = fakeDom();
  let stop = start(async () => { throw Object.assign(new Error("boom"), { status: 500 }); }, areas, () => assert.fail(), true);
  await wait();
  stop();
  assert.equal(areas.error.textContent, "boom");

  areas = fakeDom();
  stop = start(async (p, o) => { if (o && o.method === "POST") throw Object.assign(new Error("no such alert"), { status: 400 }); return p.startsWith("/api/alert-center/history") ? historyDoc : alertsDoc; }, areas, () => assert.fail(), true);
  await wait();
  await find(areas.list, (n) => n.tag === "button" && n.textContent === "Acknowledge")[0].listeners.click();
  stop();
  assert.equal(areas.error.textContent, "no such alert");

  areas = fakeDom();
  let out = 0;
  stop = start(async () => { throw Object.assign(new Error("no"), { status: 401 }); }, areas, () => out++, true);
  await wait();
  stop();
  assert.equal(out, 1);
});

test("changing a filter reads the list again with the filter, and stop removes the listeners", async () => {
  const areas = fakeDom();
  const paths = [];
  const stop = start(async (p) => { paths.push(p); return p.startsWith("/api/alert-center/history") ? historyDoc : alertsDoc; }, areas, () => assert.fail(), true);
  await wait();
  areas.state.value = "snoozed";
  areas.severity.value = "crit";
  await areas.state.listeners.change();
  assert.ok(paths.includes("/api/alert-center?state=snoozed&severity=crit"));
  stop();
  assert.equal(areas.state.listeners.change, undefined);
  assert.equal(areas.refresh.listeners.click, undefined);
});

test("the bell: red with a critical alert, yellow with others, green with none, hidden without data", () => {
  assert.deepEqual(bellChip({ counts: { new: 3, new_crit: 1 } }), { text: "3 new alerts", level: "crit" });
  assert.deepEqual(bellChip({ counts: { new: 1, new_crit: 0 } }), { text: "1 new alert", level: "warn" });
  assert.deepEqual(bellChip({ counts: { new: 0, new_crit: 0 } }), { text: "No new alerts", level: "ok" });
  assert.equal(bellChip(null), null);
  assert.equal(bellChip({}), null);
});

test("the top bar paints the bell from /api/alert-center and survives its failure", async () => {
  const chip = () => ({ hidden: true, textContent: "", dataset: {} });
  const els = { host: chip(), state: chip(), mode: chip(), bell: chip() };
  let fail = false;
  const api = async (p) => {
    if (p.startsWith("/api/alert-center")) { if (fail) throw Object.assign(new Error("x"), { status: 500 }); return { counts: { new: 2, new_crit: 0 } }; }
    return {};
  };
  const stop = startTop(api, els, () => assert.fail());
  await wait();
  assert.equal(els.bell.textContent, "2 new alerts");
  assert.equal(els.bell.hidden, false);
  assert.equal(els.bell.dataset.level, "warn");
  stop();
  const els2 = { host: chip(), state: chip(), mode: chip(), bell: chip() };
  fail = true;
  const stop2 = startTop(api, els2, () => assert.fail());
  await wait();
  stop2();
  assert.equal(els2.bell.hidden, true, "a failing source leaves the bell hidden");
});

test("the page has the Alert Center on the Alerts screen, the bell as a link, and the wiring", () => {
  const html = here("index.html");
  const app = here("app.js");
  assert.match(html, /<h2>Alert Center<\/h2>/);
  assert.match(html, /<h2>Status changes<\/h2>/);
  assert.match(html, /changes only what this page shows/);
  assert.match(html, /<a id="top-bell" class="chip" href="#alerts" hidden>/);
  for (const id of ["ac-error", "ac-summary", "ac-state", "ac-source", "ac-severity", "ac-note", "ac-refresh", "ac-list", "ac-history"]) {
    assert.match(html, new RegExp(`id="${id}"`), id);
    assert.ok(app.includes(`$("${id}")`), id);
  }
  assert.match(app, /bell: \$\("top-bell"\)/);
  assert.match(app, /me\.perms\.includes\("events\.ack"\)/);
  // the old feed keeps its own ids
  for (const id of ["alerts-error", "al-check", "al-limit", "al-refresh", "al-list"]) assert.match(html, new RegExp(`id="${id}"`), id);
});
