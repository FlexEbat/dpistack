import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { CSV_COLUMNS, activeFilters, cell, domainOf, exportName, filterEvents, groupBy, matches, related, since, sidHistory, toCSV, toJSON } from "../modules/events-model.js";

const read = (p) => readFileSync(new URL("../" + p, import.meta.url), "utf8");
const alert = (o = {}) => ({
  type: "alert",
  time: o.time || "2026-11-08T10:00:00Z",
  event: { src_ip: o.src || "10.0.0.5", src_port: 40000, dest_ip: o.dst || "1.1.1.1", dest_port: 22, proto: o.proto || "TCP", flow_id: o.flow ?? 111,
    alert: { signature_id: o.sid ?? 2001219, signature: o.sig || "ET SCAN SSH", category: o.cat || "Attempted Information Leak", severity: o.sev ?? 2 } },
});
const dns = (name, o = {}) => ({ type: "dns", time: o.time || "2026-11-08T10:00:01Z", event: { src_ip: o.src || "10.0.0.5", dest_ip: "9.9.9.9", proto: "UDP", flow_id: o.flow ?? 111, dns: { type: "query", rrname: name } } });
const tls = (sni) => ({ type: "tls", time: "2026-11-08T10:00:02Z", event: { src_ip: "10.0.0.6", dest_ip: "2.2.2.2", proto: "TCP", app_proto: "tls", flow_id: 222, tls: { sni } } });

test("since: the time choices become an ISO time, all loaded stays empty", () => {
  const now = Date.parse("2026-11-08T12:00:00Z");
  assert.equal(since("", now), "");
  assert.equal(since("bogus", now), "");
  assert.equal(since("15m", now), "2026-11-08T11:45:00.000Z");
  assert.equal(since("1h", now), "2026-11-08T11:00:00.000Z");
  assert.equal(since("24h", now), "2026-11-07T12:00:00.000Z");
  assert.equal(since("7d", now), "2026-11-01T12:00:00.000Z");
});

test("domainOf: DNS name, TLS name or HTTP host", () => {
  assert.equal(domainOf(dns("a.example").event), "a.example");
  assert.equal(domainOf(tls("b.example").event), "b.example");
  assert.equal(domainOf({ http: { hostname: "c.example" } }), "c.example");
  assert.equal(domainOf({}), "");
});

test("matches: each filter works alone, and a filter on a missing field fails the event", () => {
  const a = alert();
  assert.equal(matches(a, {}), true);
  assert.equal(matches(a, { ip: "10.0.0" }), true);
  assert.equal(matches(a, { ip: "1.1.1.1" }), true);
  assert.equal(matches(a, { ip: "8.8" }), false);
  assert.equal(matches(a, { sid: "2001219" }), true);
  assert.equal(matches(a, { sid: "200121" }), false);
  assert.equal(matches(a, { category: "information leak" }), true);
  assert.equal(matches(a, { category: "malware" }), false);
  assert.equal(matches(a, { proto: "tcp" }), true);
  assert.equal(matches(a, { proto: "udp" }), false);
  assert.equal(matches(tls("x.example"), { proto: "TLS" }), true);
  assert.equal(matches(a, { severity: "2" }), true);
  assert.equal(matches(a, { severity: "1" }), false);
  assert.equal(matches(dns("a.example"), { severity: "2" }), false);
  assert.equal(matches(dns("Mail.Example.COM"), { domain: "mail.example" }), true);
  assert.equal(matches(a, { domain: "example" }), false);
});

test("matches: filters combine, and spaces around a value are ignored", () => {
  const a = alert();
  assert.equal(matches(a, { ip: " 10.0.0.5 ", sid: " 2001219 ", severity: "2", proto: "tcp" }), true);
  assert.equal(matches(a, { ip: "10.0.0.5", sid: "999" }), false);
});

test("filterEvents and activeFilters", () => {
  const evs = [alert(), alert({ sid: 5, src: "10.0.0.9" }), dns("a.example")];
  assert.equal(filterEvents(evs, { sid: "5" }).length, 1);
  assert.equal(filterEvents(evs, { ip: "10.0.0" }).length, 3);
  assert.equal(activeFilters({}), 0);
  assert.equal(activeFilters({ ip: "x", sid: " ", severity: "1", domain: "d" }), 3);
});

test("groupBy: by rule, source, destination and category, most events first, worst severity kept", () => {
  const evs = [alert({ sev: 3 }), alert({ sev: 1, time: "2026-11-08T11:00:00Z" }), alert({ sid: 7, sig: "Other", src: "10.0.0.9", dst: "1.1.1.1", cat: "Malware", sev: 2 }), dns("a.example")];
  const bySig = groupBy(evs, "signature");
  assert.deepEqual(bySig.map((g) => [g.key, g.count, g.severity, g.field, g.value]), [["2001219 ET SCAN SSH", 2, 1, "sid", "2001219"], ["7 Other", 1, 2, "sid", "7"]]);
  assert.equal(bySig[0].last, "2026-11-08T11:00:00Z");
  assert.deepEqual(groupBy(evs, "source").map((g) => [g.key, g.count]), [["10.0.0.5", 3], ["10.0.0.9", 1]]);
  assert.deepEqual(groupBy(evs, "destination").map((g) => [g.key, g.count]), [["1.1.1.1", 3], ["9.9.9.9", 1]]);
  const cat = groupBy(evs, "category");
  assert.deepEqual(cat.map((g) => [g.key, g.count, g.field]), [["Attempted Information Leak", 2, "category"], ["Malware", 1, "category"]]);
  assert.deepEqual(groupBy(evs, "nonsense"), []);
});

test("related: the events of one flow in time order, none for no flow id", () => {
  const evs = [dns("late.example", { time: "2026-11-08T10:05:00Z" }), alert({ flow: 999 }), alert({ time: "2026-11-08T10:01:00Z" }), dns("early.example", { time: "2026-11-08T10:00:00Z" })];
  assert.deepEqual(related(evs, 111).map((e) => e.time), ["2026-11-08T10:00:00Z", "2026-11-08T10:01:00Z", "2026-11-08T10:05:00Z"]);
  assert.deepEqual(related(evs, "111").length, 3);
  assert.deepEqual(related(evs, undefined), []);
  assert.deepEqual(related(evs, ""), []);
  assert.deepEqual(related(evs, 424242), []);
});

test("sidHistory: count, first and last time, top sources and destinations of one rule", () => {
  const evs = [alert({ time: "2026-11-08T10:00:00Z" }), alert({ time: "2026-11-08T09:00:00Z", src: "10.0.0.9" }), alert({ time: "2026-11-08T11:00:00Z" }), alert({ sid: 5 }), dns("a.example")];
  const h = sidHistory(evs, 2001219);
  assert.equal(h.count, 3);
  assert.equal(h.first, "2026-11-08T09:00:00Z");
  assert.equal(h.last, "2026-11-08T11:00:00Z");
  assert.equal(h.signature, "ET SCAN SSH");
  assert.deepEqual(h.sources, [{ value: "10.0.0.5", count: 2 }, { value: "10.0.0.9", count: 1 }]);
  assert.deepEqual(h.destinations, [{ value: "1.1.1.1", count: 3 }]);
  assert.equal(sidHistory(evs, 12345).count, 0);
});

test("cell: quotes commas, quotes and newlines, and defuses a formula", () => {
  assert.equal(cell("plain"), "plain");
  assert.equal(cell(5), "5");
  assert.equal(cell(undefined), "");
  assert.equal(cell("a,b"), '"a,b"');
  assert.equal(cell('say "hi"'), '"say ""hi"""');
  assert.equal(cell("line1\nline2"), '"line1\nline2"');
  for (const risky of ["=1+1", "+1", "-1", "@SUM(A1)", "\tcmd", "\rcmd"]) assert.ok(cell(risky).startsWith("'") || cell(risky).startsWith('"\''), risky);
  assert.equal(cell("=HYPERLINK(\"http://evil\",\"x\")"), `"'=HYPERLINK(""http://evil"",""x"")"`);
});

test("toCSV: a header, one row per event in the column order, and CRLF lines", () => {
  const csv = toCSV([alert({ sig: "=cmd|' /C calc'!A0" }), dns("a.example")]);
  const lines = csv.split("\r\n");
  assert.equal(lines[0], CSV_COLUMNS.join(","));
  assert.equal(lines.length, 4);
  assert.equal(lines[3], "");
  assert.ok(lines[1].startsWith("2026-11-08T10:00:00Z,alert,10.0.0.5,40000,1.1.1.1,22,TCP,,2001219,"));
  assert.ok(lines[1].includes("'=cmd|' /C calc'!A0"));
  assert.ok(lines[2].includes(",dns,10.0.0.5,,9.9.9.9,,UDP,"));
  assert.ok(lines[2].includes(",a.example,111"));
});

test("toJSON: the events as an array with their time and type", () => {
  const out = JSON.parse(toJSON([alert(), dns("a.example")]));
  assert.equal(out.length, 2);
  assert.deepEqual(Object.keys(out[0]).sort(), ["event", "time", "type"]);
  assert.equal(out[0].event.alert.signature_id, 2001219);
  assert.equal(JSON.parse(toJSON([])).length, 0);
});

test("exportName: kind, a sortable stamp and the extension", () => {
  assert.equal(exportName("events", "csv", new Date("2026-11-08T09:05:07Z")), "dpistack-events-20261108-090507.csv");
});

test("the page: every new element exists and is wired, the stream and the buttons are in the module", () => {
  const html = read("index.html");
  const app = read("app.js");
  const ids = ["ev-range", "ev-ip", "ev-sid", "ev-category", "ev-proto", "ev-severity", "ev-domain", "ev-group", "ev-export-json", "ev-export-csv", "ev-status"];
  for (const id of ids) {
    assert.match(html, new RegExp(`id="${id}"`), id);
    assert.ok(app.includes(`$("${id}")`), id);
  }
  const src = read("modules/events.js");
  for (const needle of ["Related events", "History of this rule", "Create exception", "Export", "since(els.range.value)", "filterEvents(loaded, filters())"]) {
    assert.ok(src.includes(needle) || html.includes(needle), needle);
  }
  assert.ok(!/localStorage|sessionStorage/.test(src), "no browser storage");
  assert.ok(!/innerHTML/.test(src), "no innerHTML: events hold text from packets");
});
