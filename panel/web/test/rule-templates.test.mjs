import test from "node:test";
import assert from "node:assert/strict";
import { TEMPLATES, nextSid, fill, insertInto, SID_MIN, SID_MAX } from "../modules/rule-templates.js";

test("every template is one complete rule with a sid placeholder and a real description", () => {
  assert.ok(TEMPLATES.length >= 6);
  const ids = new Set();
  for (const t of TEMPLATES) {
    assert.ok(!ids.has(t.id), t.id);
    ids.add(t.id);
    assert.match(t.rule, /^(alert|drop|pass) \w+ .+ \(msg:"[^"]+";.*sid:@SID@; rev:1;\)$/, t.id);
    assert.ok(t.description.length > 200, `${t.id}: the description says what it matches and what to change`);
    assert.ok(t.summary.length > 10 && t.title.length > 5, t.id);
    assert.ok(!/[!]/.test(t.title + t.summary), t.id);
  }
});

test("the next sid is the first of the local range, then one after the highest local sid", () => {
  assert.equal(nextSid(""), 9001000);
  assert.equal(nextSid("alert ip any any -> any any (msg:\"x\"; sid:9001004; rev:1;)"), 9001005);
  assert.equal(nextSid("alert ip any any -> any any (msg:\"x\"; sid:2100498; rev:1;)"), 9001000, "a sid of a rule set is not a local one");
  assert.equal(nextSid(`x (sid:${SID_MAX};)`), null);
});

test("a filled template has a sid inside the local range and two inserts get two sids", () => {
  for (const t of TEMPLATES) {
    const rule = fill(t.id, "");
    const sid = Number(/sid:(\d+);/.exec(rule)[1]);
    assert.ok(sid >= SID_MIN && sid <= SID_MAX, t.id);
    assert.ok(!rule.includes("@SID@"));
  }
  const once = insertInto("# my rules\n", "dns-domain");
  const twice = insertInto(once, "tls-sni");
  const sids = [...twice.matchAll(/sid:(\d+);/g)].map((m) => m[1]);
  assert.deepEqual(sids, ["9001000", "9001001"]);
  assert.ok(twice.startsWith("# my rules\n\n# DNS query for a domain\n"));
  assert.ok(twice.endsWith(")\n"));
  assert.equal(fill("nope", ""), null);
  assert.equal(insertInto("", "nope"), null);
});
