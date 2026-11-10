import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const read = (p) => readFileSync(new URL("../" + p, import.meta.url), "utf8");
const IDS = ["stats", "history", "class", "source", "state", "text", "find", "find-note", "find-results", "editor", "reload", "check", "save", "apply", "report", "versions", "diff"];

test("the Rules view has every element of the Rules v2 part, inside its own view, and app.js wires each", () => {
  const html = read("index.html");
  const app = read("app.js");
  const view = html.slice(html.indexOf('<div id="view-rules"'), html.indexOf('<div id="view-exceptions"'));
  for (const id of IDS) {
    assert.ok(view.includes(`id="r2-${id}"`), `${id} is inside the Rules view`);
    assert.ok(app.includes(`$("r2-${id}")`), `${id} is wired`);
  }
});

test("the Rules screen starts both parts and stops both", () => {
  const app = read("app.js");
  assert.match(app, /const stopRules = startRules\(/);
  assert.match(app, /const stopRules2 = startRules2\(/);
  assert.match(app, /stopRules\(\);\s*stopRules2\(\);/);
});

test("the save and apply buttons start disabled, so nothing is saved before a check", () => {
  const html = read("index.html");
  assert.match(html, /id="r2-save"[^>]*disabled/);
  assert.match(html, /id="r2-apply"[^>]*disabled/);
});

test("the module calls only the Rules v2 and config routes, saves like the Configs screen, and never builds HTML from text", () => {
  const src = read("modules/rules2.js");
  const paths = [...src.matchAll(/api\(\s*[`"]([^`"?$]+)/g)].map((m) => m[1]);
  assert.deepEqual([...new Set(paths)].sort(), ["/api/config/local.rules", "/api/config/local.rules/history", "/api/config/local.rules/history/", "/api/rules/facets", "/api/rules/find", "/api/rules/history", "/api/rules/local/check", "/api/rules/stats"].sort());
  assert.match(src, /api\(`\/api\/config\/local\.rules\?apply=\$\{apply \? 1 : 0\}`, \{ method: "PUT", headers: \{ "Content-Type": "text\/plain" \}/);
  assert.ok(!/innerHTML|insertAdjacentHTML|localStorage|sessionStorage/.test(src));
  assert.match(src, /confirm\("Save local\.rules and apply\?/);
});
