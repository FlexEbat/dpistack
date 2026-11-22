import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { parseConf } from "../modules/rules.js";

const read = (p) => readFileSync(new URL("../" + p, import.meta.url), "utf8");

test("task 58: drop.conf is read the way enable.conf is: groups and sids, comments ignored", () => {
  const c = parseConf("# written by dpistack\n2100498\ngroup:emerging-p2p.rules\n re:classtype:trojan \n\n2210044\n");
  assert.deepEqual(c.sids, ["2100498", "2210044"]);
  assert.deepEqual(c.groups, ["emerging-p2p.rules"]);
});

test("task 58: the Rules view has the Rules that drop section and app.js wires it", () => {
  const html = read("index.html");
  const view = html.slice(html.indexOf('<div id="view-rules"'), html.indexOf('<div id="view-exceptions"'));
  assert.ok(view.includes('id="rules-dropping"'));
  assert.match(view, /Rules that drop/);
  assert.match(read("app.js"), /dropping: \$\("rules-dropping"\)/);
});

test("task 58: a rule or a group is switched to drop and back through the API verbs, and drop asks first", () => {
  const src = read("modules/rules.js");
  assert.match(src, /conf\("drop\.conf"\)/);
  assert.match(src, /\/api\/rules\/sid\/\$\{sid\}\/\$\{verb\}/);
  assert.match(src, /\/api\/rules\/groups\/\$\{encodeURIComponent\(group\)\}\/\$\{verb\}/);
  // the confirmation comes before the request, and only for drop
  assert.match(src, /verb === "drop" && !confirm\(`Make rule/);
  assert.match(src, /verb === "drop" && !confirm\(`Make every rule of/);
  // search results and groups offer it, and a disabled rule does not
  assert.match(src, /els\.dropping && !off/);
  assert.match(src, /"Alert only" : "Drop"/);
});

test("task 58: the section is optional, so a page without it still works", () => {
  const src = read("modules/rules.js");
  assert.match(src, /if \(!els\.dropping\) return;/);
  assert.match(src, /els\.dropping \? conf\("drop\.conf"\)/);
});
