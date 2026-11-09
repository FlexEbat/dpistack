import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { LIMITS, defaultText, expiryText, formToBody, fromEvent, ordered, scopeText, setDraft, summary, takeDraft } from "../modules/exceptions-model.js";

const read = (p) => readFileSync(new URL("../" + p, import.meta.url), "utf8");
const entry = (o) => ({ id: "x", kind: "suppress", sid: 1, track: "src", ip: "10.0.0.5", count: 0, seconds: 0, expires: "2026-12-01", days_left: 23, expired: false, ...o });

test("scopeText: one address, every address, a limit per side", () => {
  assert.equal(scopeText(entry({})), "source 10.0.0.5");
  assert.equal(scopeText(entry({ track: "dst", ip: "10.0.0.0/24" })), "destination 10.0.0.0/24");
  assert.equal(scopeText(entry({ track: "any", ip: "any" })), "every address");
  assert.equal(scopeText(entry({ kind: "limit", track: "dst", count: 5, seconds: 60, ip: "any" })), "at most 5 alerts per 60 seconds for each destination address");
});

test("expiryText: never, days left with the right plural, the last day, expired", () => {
  assert.equal(expiryText(entry({ expires: "never", days_left: null })), "never expires");
  assert.equal(expiryText(entry({ days_left: 23 })), "until 2026-12-01, 23 days left");
  assert.equal(expiryText(entry({ days_left: 1 })), "until 2026-12-01, 1 day left");
  assert.equal(expiryText(entry({ days_left: 0, expires: "2026-11-08" })), "last day is today (2026-11-08)");
  assert.match(expiryText(entry({ expired: true, days_left: -3, expires: "2026-11-05" })), /^expired on 2026-11-05/);
});

test("ordered: expired first, then the soonest, then the ones that never end", () => {
  const got = ordered([
    entry({ id: "never", expires: "never", days_left: null }),
    entry({ id: "late", days_left: 40 }),
    entry({ id: "dead", expired: true, days_left: -1 }),
    entry({ id: "soon", days_left: 2 }),
  ]).map((e) => e.id);
  assert.deepEqual(got, ["dead", "soon", "late", "never"]);
});

test("summary and defaultText say what is there and what a new entry gets", () => {
  assert.equal(summary({ entries: [] }), "No exceptions. Every rule alerts as written.");
  assert.equal(summary({ entries: [entry({ days_left: 3 }), entry({ id: "b", days_left: 30 }), entry({ id: "c", expired: true, days_left: -1 }), { kind: "other", id: "other:1" }] }),
    "3 exceptions, 1 ending within 7 days, 1 expired, 1 written by hand, not managed here.");
  assert.equal(summary({ entries: [entry({ days_left: 30 })] }), "1 exception.");
  assert.match(defaultText({ default_days: 30 }), /lasts 30 days/);
  assert.match(defaultText({ default_days: 1 }), /lasts 1 day /);
  assert.match(defaultText({ default_days: 0 }), /never expires/);
  assert.match(defaultText(null), /lasts 30 days/);
});

const base = { kind: "suppress", sid: "2001219", scope: "one", side: "src", ip: "10.0.0.5", count: "", seconds: "", expiry: "default", days: "", note: "" };

test("formToBody: suppress for one address builds the body the API takes", () => {
  const r = formToBody(base);
  assert.deepEqual(r.body, { kind: "suppress", sid: 2001219, track: "src", ip: "10.0.0.5" });
  assert.deepEqual(r.warnings, []);
  assert.deepEqual(formToBody({ ...base, side: "dst", ip: " 10.0.0.0/24 ", expiry: "days", days: "10", note: " printer scans " }).body,
    { kind: "suppress", sid: 2001219, track: "dst", ip: "10.0.0.0/24", days: 10, note: "printer scans" });
});

test("formToBody: a bare SID is allowed and comes with a warning, never expiring too", () => {
  const bare = formToBody({ ...base, scope: "everyone", ip: "ignored", expiry: "never" });
  assert.deepEqual(bare.body, { kind: "suppress", sid: 2001219, never: true });
  assert.equal(bare.warnings.length, 2);
  assert.match(bare.warnings[0], /silent for every address/);
  assert.match(bare.warnings[1], /never expires/);
});

test("formToBody: a limit needs a count and a window and tracks a side", () => {
  const r = formToBody({ ...base, kind: "limit", side: "dst", count: "5", seconds: "60", ip: "10.9.9.9" });
  assert.deepEqual(r.body, { kind: "limit", sid: 2001219, track: "dst", count: 5, seconds: 60 });
  assert.equal(formToBody({ ...base, kind: "limit", count: "0", seconds: "60" }).problem.includes("1 to " + LIMITS.countMax), true);
  assert.equal(formToBody({ ...base, kind: "limit", count: "5", seconds: "999999" }).problem.includes("1 to " + LIMITS.secondsMax), true);
});

test("formToBody: every wrong value gives a sentence and no body", () => {
  for (const f of [
    { sid: "" }, { sid: "abc" }, { sid: "0" }, { sid: "-5" }, { sid: "99999999999" },
    { ip: "" }, { ip: "10.0.0.1;rm" }, { ip: "host name" },
    { expiry: "days", days: "" }, { expiry: "days", days: "0" }, { expiry: "days", days: String(LIMITS.daysMax + 1) },
    { note: "a;b" }, { note: "x".repeat(81) },
  ]) {
    const r = formToBody({ ...base, ...f });
    assert.ok(r.problem && !r.body, JSON.stringify(f));
  }
  assert.ok(formToBody({ ...base, expiry: "days", days: String(LIMITS.daysMax) }).body);
  assert.ok(formToBody({ ...base, note: "x".repeat(80) }).body);
});

test("fromEvent: an alert gives the rule and its source address, anything else gives nothing", () => {
  const alert = { type: "alert", event: { src_ip: "10.0.0.5", dest_ip: "1.1.1.1", alert: { signature_id: 2001219, signature: "ET SCAN SSH" } } };
  assert.deepEqual(fromEvent(alert), { kind: "suppress", sid: "2001219", scope: "one", side: "src", ip: "10.0.0.5", expiry: "default", note: "", signature: "ET SCAN SSH", dest_ip: "1.1.1.1" });
  assert.equal(fromEvent({ type: "dns", event: { src_ip: "10.0.0.5", dns: {} } }), null);
  assert.equal(fromEvent({ type: "alert", event: { alert: {} } }), null);
  assert.equal(fromEvent(null), null);
  assert.equal(fromEvent({ type: "alert", event: { alert: { signature_id: 7 } } }).scope, "everyone");
  // The result is what the form wants: it builds a valid body as it is.
  assert.deepEqual(formToBody(fromEvent(alert)).body, { kind: "suppress", sid: 2001219, track: "src", ip: "10.0.0.5" });
});

test("the draft from an event is taken once", () => {
  setDraft({ sid: "5" });
  assert.deepEqual(takeDraft(), { sid: "5" });
  assert.equal(takeDraft(), null);
});

test("the page: view, menu entry in Protection, route, element ids, and the button in the Events detail", () => {
  const html = read("index.html");
  const app = read("app.js");
  assert.match(html, /id="view-exceptions"/);
  const protection = html.match(/aria-label="Protection">[\s\S]*?<\/div>/)[0];
  assert.match(protection, /data-view="exceptions"/);
  assert.match(app, /"rules", "exceptions", "logs"/);
  assert.match(app, /exceptions: \(\) =>/);
  const ids = ["error", "message", "summary", "hint", "list", "kind", "sid", "scope", "scope-box", "side", "side-box", "ip", "ip-box", "count", "count-box", "seconds", "seconds-box", "expiry", "days", "days-box", "note", "add"];
  for (const id of ids) {
    assert.match(html, new RegExp(`id="exc-${id}"`), id);
    assert.ok(app.includes(`$("exc-${id}")`), id);
  }
  const events = read("modules/events.js");
  assert.match(events, /Create exception/);
  assert.match(events, /location\.hash = "#exceptions"/);
});

test("the screen only calls the exceptions API, never a file or another route", () => {
  const src = read("modules/exceptions.js");
  const calls = [...src.matchAll(/(?:api|post)\(\s*"([^"]+)"/g)].map((m) => m[1]);
  assert.deepEqual([...new Set(calls)].sort(), ["/api/exceptions", "/api/exceptions/remove"]);
});
