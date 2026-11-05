import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { viewFromHash, hashOf, syncGroups, readCollapsed, saveCollapsed, collapse } from "../modules/shell.js";

const VIEWS = ["overview", "events", "backups"];
const web = join(dirname(fileURLToPath(import.meta.url)), "..");

test("the address names a screen, and only a screen", () => {
  assert.equal(viewFromHash("#events", VIEWS), "events");
  assert.equal(viewFromHash("#/events", VIEWS), "events");
  assert.equal(viewFromHash("#nothing", VIEWS), "");
  assert.equal(viewFromHash("#events?x=1", VIEWS), "");
  assert.equal(viewFromHash("", VIEWS), "");
  assert.equal(viewFromHash(undefined, VIEWS), "");
  assert.equal(hashOf("backups"), "#backups");
});

test("a group of the menu disappears when none of its entries is allowed", () => {
  const group = (hidden) => ({ hidden: false, querySelectorAll: () => hidden.map((h) => ({ hidden: h })) });
  const groups = [group([true, true]), group([true, false]), group([])];
  syncGroups({ querySelectorAll: () => groups });
  assert.deepEqual(groups.map((g) => g.hidden), [true, false, true]);
});

test("the collapsed state is remembered and a browser that refuses storage does not break it", () => {
  const mem = new Map();
  const storage = { getItem: (k) => mem.get(k) ?? null, setItem: (k, v) => mem.set(k, v) };
  assert.equal(readCollapsed(storage), false);
  saveCollapsed(storage, true);
  assert.equal(readCollapsed(storage), true);
  saveCollapsed(storage, false);
  assert.equal(readCollapsed(storage), false);
  const broken = { getItem() { throw new Error("denied"); }, setItem() { throw new Error("denied"); } };
  assert.equal(readCollapsed(broken), false);
  assert.doesNotThrow(() => saveCollapsed(broken, true));
});

test("the button folds the menu, tells the state to assistive tools and stores it", () => {
  const attrs = new Set();
  const page = { toggleAttribute: (n, on) => (on ? attrs.add(n) : attrs.delete(n)), hasAttribute: (n) => attrs.has(n) };
  const aria = {};
  let click;
  const button = { setAttribute: (n, v) => (aria[n] = v), addEventListener: (t, f) => t === "click" && (click = f) };
  const mem = new Map([["dpistack.nav.collapsed", "1"]]);
  const storage = { getItem: (k) => mem.get(k) ?? null, setItem: (k, v) => mem.set(k, v) };
  collapse({ getElementById: (id) => (id === "overview" ? page : button) }, storage);
  assert.ok(attrs.has("data-collapsed"), "starts collapsed when it was left collapsed");
  assert.equal(aria["aria-expanded"], "false");
  click();
  assert.ok(!attrs.has("data-collapsed"));
  assert.equal(aria["aria-expanded"], "true");
  assert.equal(mem.get("dpistack.nav.collapsed"), "0");
});

test("every screen is in exactly one group of the menu", () => {
  const html = readFileSync(join(web, "index.html"), "utf8");
  const app = readFileSync(join(web, "app.js"), "utf8");
  const views = JSON.parse(app.match(/const VIEWS = (\[.*?\]);/)[1]);
  const groups = [...html.matchAll(/<div class="nav-group"[\s\S]*?<\/div>/g)].map((m) => [...m[0].matchAll(/data-view="(\w+)"/g)].map((x) => x[1]));
  assert.deepEqual(groups.flat().sort(), [...views].sort());
});
