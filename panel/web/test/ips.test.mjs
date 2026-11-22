import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { headline, checkRows, counterRows, ruleLines, parseSids, requestedText, testSummary, levelOf } from "../modules/ips-model.js";
import { start } from "../modules/ips.js";

const here = (f) => readFileSync(new URL("../" + f, import.meta.url), "utf8");

const ready = {
  mode: "ips", method: "nfq", pending: false, remaining_sec: 0, ready: true,
  checks: [{ id: "queue", state: "ok", text: "Suricata listens on queue 0" }, { id: "firewall", state: "fail", text: "missing" }, { id: "confirm", state: "na", text: "-" }],
  counters: { accepted: 5, blocked: 2, rejected: 1, replaced: 0 },
  drop_rules: { enabled: 4, disabled: 1, local_enabled: 2, local_disabled: 0 },
  blocked: [{ time: "t", src: "10.0.0.1", dest: "10.0.0.2", proto: "TCP", sid: 1000002, msg: "drop two" }],
};

test("the headline: ids says nothing is dropped, a pending switch warns, a failing check is critical, ready is ok", () => {
  assert.deepEqual(headline({ mode: "ids" }).level, "na");
  assert.match(headline({ mode: "ids" }).text, /nothing is dropped/);
  assert.equal(headline({ ...ready, pending: true, remaining_sec: 42 }).level, "warn");
  assert.match(headline({ ...ready, pending: true, remaining_sec: 42 }).text, /42 s/);
  assert.equal(headline({ ...ready, ready: false }).level, "crit");
  assert.equal(headline(ready).level, "ok");
  assert.equal(headline(null).level, "na");
});

test("check states map to badge levels: a failure is crit, an unknown state is na", () => {
  assert.deepEqual(["ok", "warn", "fail", "na", "weird"].map(levelOf), ["ok", "warn", "crit", "na", "na"]);
  assert.deepEqual(checkRows(ready).map((c) => [c.title, c.level]), [["Queue", "ok"], ["Queue rules", "crit"], ["Confirmation", "na"]]);
  assert.deepEqual(checkRows(null), []);
});

test("counters are shown only when Suricata reported them", () => {
  assert.deepEqual(counterRows({ counters: null }), []);
  assert.deepEqual(counterRows(ready).map((r) => [r.id, r.value]), [["accepted", 5], ["blocked", 2], ["rejected", 1], ["replaced", 0]]);
});

test("the rule lines carry the numbers of the verb", () => {
  assert.deepEqual(ruleLines(ready), ["Rule set: 4 drop rules active, 1 disabled.", "Local rules: 2 active, 0 disabled."]);
  assert.deepEqual(ruleLines(null), []);
});

test("rule numbers: whole numbers, commas or spaces, 20 at most, empty means all", () => {
  assert.deepEqual(parseSids("").sids, []);
  assert.deepEqual(parseSids("1000002, 9000001 5").sids, [1000002, 9000001, 5]);
  assert.match(parseSids("abc").error, /not a rule number/);
  assert.match(parseSids("1.5").error, /not a rule number/);
  assert.match(parseSids("-1").error, /not a rule number/);
  assert.match(parseSids("12345678901").error, /not a rule number/);
  assert.match(parseSids(Array.from({ length: 21 }, (_, i) => i + 1).join(",")).error, /At most 20/);
});

test("the test summary says it did not run, with the reason, or what would drop", () => {
  assert.match(testSummary({ ran: false, reason: "suricata is not installed" }), /did not run: suricata is not installed/);
  assert.match(testSummary({ ran: true, pcap: "bittorrent", loaded: 3, would_drop: 1, matched: [{}] }), /3 rules: 1 would drop, 1 matched/);
  assert.match(testSummary({ ran: true, pcap: "bittorrent", loaded: 1, would_drop: 0, matched: [] }), /1 rule: 0 would drop/);
  assert.equal(testSummary(null), "");
  assert.equal(requestedText({ state: "alert_only" }), "alerts only (not a drop rule)");
  assert.equal(requestedText({ state: "not_found" }), "was not found");
});

function fakeDom() {
  globalThis.document = {
    createElement: () => ({ className: "", textContent: "", children: [], append(...c) { this.children.push(...c); } }),
  };
  globalThis.Node = undefined;
  const area = () => ({ textContent: "", children: null, replaceChildren(...c) { this.children = c; } });
  const handlers = {};
  return {
    handlers,
    areas: {
      error: area(), summary: area(), checks: area(), counters: area(), rules: area(), blocked: area(), note: area(), result: area(),
      sids: { value: "" },
      run: { disabled: false, addEventListener: (n, f) => (handlers[n] = f), removeEventListener: (n) => delete handlers[n] },
    },
  };
}

const wait = () => new Promise((r) => setTimeout(r, 10));

test("the screen reads /api/ips and draws every part", async () => {
  const { areas } = fakeDom();
  const stop = start(async (p) => { assert.equal(p, "/api/ips"); return ready; }, areas, () => assert.fail());
  await wait();
  stop();
  for (const k of ["summary", "checks", "counters", "rules", "blocked"]) assert.ok(areas[k].children, k);
  assert.equal(areas.error.textContent, "");
});

test("a failing read shows its message, a 401 is passed on", async () => {
  let f = fakeDom();
  let stop = start(async () => { throw Object.assign(new Error("boom"), { status: 500 }); }, f.areas, () => assert.fail());
  await wait();
  stop();
  assert.equal(f.areas.error.textContent, "boom");
  f = fakeDom();
  let out = 0;
  stop = start(async () => { throw Object.assign(new Error("no"), { status: 401 }); }, f.areas, () => out++);
  await wait();
  stop();
  assert.equal(out, 1);
});

test("the rule test refuses a bad number before any request, and posts the numbers otherwise", async () => {
  const f = fakeDom();
  const calls = [];
  const stop = start(async (p, o) => { calls.push([p, o && o.method, o && o.body]); return p === "/api/ips" ? ready : { ran: true, pcap: "bittorrent", loaded: 1, would_drop: 1, matched: [{ sid: 1, msg: "m", would_drop: true }], requested: [] }; }, f.areas, () => {});
  await wait();
  f.areas.sids.value = "abc";
  await f.handlers.click();
  assert.match(f.areas.note.textContent, /not a rule number/);
  assert.equal(calls.filter((c) => c[0] === "/api/ips/test").length, 0);
  f.areas.sids.value = "1000002";
  await f.handlers.click();
  const post = calls.find((c) => c[0] === "/api/ips/test");
  assert.equal(post[1], "POST");
  assert.deepEqual(JSON.parse(post[2]), { pcap: "bittorrent", sids: [1000002] });
  assert.ok(f.areas.result.children.length >= 1);
  assert.equal(f.areas.run.disabled, false);
  stop();
  assert.equal(f.handlers.click, undefined, "the stop function removes the click handler");
});

test("an empty field posts no sids, so all drop rules are tested", async () => {
  const f = fakeDom();
  let body;
  const stop = start(async (p, o) => { if (p === "/api/ips/test") { body = JSON.parse(o.body); return { ran: false, reason: "x" }; } return ready; }, f.areas, () => {});
  await wait();
  await f.handlers.click();
  stop();
  assert.deepEqual(body, { pcap: "bittorrent" });
});

test("a failing test run shows its message and frees the button", async () => {
  const f = fakeDom();
  const stop = start(async (p) => { if (p === "/api/ips/test") throw Object.assign(new Error("a rule test is already running"), { status: 409 }); return ready; }, f.areas, () => assert.fail());
  await wait();
  await f.handlers.click();
  stop();
  assert.equal(f.areas.error.textContent, "a rule test is already running");
  assert.equal(f.areas.run.disabled, false);
});

test("the page has the IPS screen: view, menu entry in Protection, route and start function", () => {
  const html = here("index.html");
  const app = here("app.js");
  assert.match(html, /id="view-ips"/);
  const protection = html.match(/aria-label="Protection">[\s\S]*?<\/div>/)[0];
  assert.match(protection, /data-view="ips"/);
  const ids = ["ips-error", "ips-summary", "ips-checks", "ips-counters", "ips-rules", "ips-blocked", "ips-sids", "ips-run", "ips-test-note", "ips-test-result"];
  for (const id of ids) {
    assert.match(html, new RegExp(`id="${id}"`), id);
    assert.ok(app.includes(`$("${id}")`), id);
  }
  assert.match(app, /"components", "ips", "settings"/);
  assert.match(app, /ips: \(\) =>/);
});

import { hostRows, hostBody, hostExpiry, blockTargets } from "../modules/ips-model.js";
import { renderHosts } from "../modules/ips.js";

test("task 58: a list of hosts shows the address, the rule, when it ends, who and why", () => {
  const rows = hostRows([
    { address: "198.51.100.7", sid: 9100000, expires: "never", by: "admin", note: "scanner" },
    { address: "203.0.113.0/24", sid: 9100001, expires: "2026-12-01" },
  ]);
  assert.deepEqual(rows[0], { address: "198.51.100.7", sid: 9100000, expires: "never", by: "admin", note: "scanner" });
  assert.equal(rows[1].expires, "until 2026-12-01");
  assert.equal(rows[1].by, "");
  assert.deepEqual(hostRows(null), []);
  assert.equal(hostExpiry({ expires: "never" }), "never");
});

test("task 58: the form sends an address with days and a note, or says why not", () => {
  assert.deepEqual(hostBody(" 203.0.113.7 ", "", "").body, { address: "203.0.113.7" });
  assert.deepEqual(hostBody("203.0.113.0/24", "7", "scanner").body, { address: "203.0.113.0/24", days: 7, note: "scanner" });
  assert.deepEqual(hostBody("2001:db8::1", "", "").body, { address: "2001:db8::1" });
  assert.match(hostBody("not an ip", "", "").error, /IP address/);
  assert.match(hostBody("", "", "").error, /IP address/);
  assert.match(hostBody("203.0.113.7", "0", "").error, /1 to 3650/);
  assert.match(hostBody("203.0.113.7", "3651", "").error, /1 to 3650/);
  assert.match(hostBody("203.0.113.7", "x", "").error, /1 to 3650/);
  assert.match(hostBody("203.0.113.7", "", "bad;note").error, /note/);
});

test("task 58: an alert offers its source and destination to block, nothing else does", () => {
  const alert = { type: "alert", event: { src_ip: "10.0.0.5", dest_ip: "203.0.113.7" } };
  assert.deepEqual(blockTargets(alert), [{ side: "source", ip: "10.0.0.5" }, { side: "destination", ip: "203.0.113.7" }]);
  assert.deepEqual(blockTargets({ type: "dns", event: { src_ip: "10.0.0.5" } }), []);
  assert.deepEqual(blockTargets({ type: "alert", event: { src_ip: "127.0.0.1", dest_ip: "::1" } }), []);
  assert.deepEqual(blockTargets({ type: "alert", event: { src_ip: "10.0.0.5", dest_ip: "10.0.0.5" } }).length, 1);
  assert.deepEqual(blockTargets(null), []);
});

test("task 58: the IPS page has its lists and form, wired in app.js", () => {
  const html = here("index.html");
  for (const id of ["ips-host-address", "ips-host-days", "ips-host-note", "ips-host-block", "ips-host-allow", "ips-host-msg", "ips-block", "ips-allow"]) {
    assert.match(html, new RegExp(`id="${id}"`), id);
    assert.match(here("app.js"), new RegExp(`"${id}"`), id);
  }
});

test("task 58: Events offers Block for the hosts of an alert and asks first", () => {
  const src = here("modules/events.js");
  assert.match(src, /blockTargets\(ev\)/);
  assert.match(src, /confirm\(`Block \$\{t\.ip\}\?/);
  assert.match(src, /"\/api\/ips\/block"/);
});
