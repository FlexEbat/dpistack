import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { hostText, stateChip, modeChip, nextTheme, readTheme, saveTheme, applyTheme, themeSwitchable, themeLabel, start, userMenu } from "../modules/topbar.js";

const here = (f) => readFileSync(new URL("../" + f, import.meta.url), "utf8");

test("the host chip shows the name the server read and nothing when it could not", () => {
  assert.equal(hostText({ hostname: " ids-gw-01 " }), "ids-gw-01");
  assert.equal(hostText({}), "");
  assert.equal(hostText(null), "");
});

test("the state chip follows the watchdog and says no data for an unknown value", () => {
  assert.deepEqual(stateChip({ health: { overall: "crit" } }), { text: "Faults", level: "crit" });
  assert.deepEqual(stateChip({ health: { overall: "ok" } }), { text: "All good", level: "ok" });
  assert.deepEqual(stateChip({}), { text: "No data", level: "na" });
  assert.deepEqual(stateChip({ health: { overall: "weird" } }), { text: "No data", level: "na" });
});

test("the mode chip: IDS is calm, IPS is a warning and a pending IPS says so", () => {
  assert.deepEqual(modeChip({ mode: "ids" }), { text: "IDS", level: "ok" });
  assert.deepEqual(modeChip({ mode: "ips", pending: false }), { text: "IPS", level: "warn" });
  assert.match(modeChip({ mode: "ips", pending: true }).text, /confirmation/);
  assert.equal(modeChip({ mode: "nonsense" }), null);
  assert.equal(modeChip(undefined), null);
});

test("the theme cycles system, light, dark and an unknown stored value means system", () => {
  assert.deepEqual(["system", "light", "dark"].map((t) => nextTheme(t)), ["light", "dark", "system"]);
  const store = (v) => ({ getItem: () => v });
  assert.equal(readTheme(store("dark")), "dark");
  assert.equal(readTheme(store("purple")), "system");
  assert.equal(readTheme(store(null)), "system");
  assert.equal(themeLabel("light"), "Theme: light");
});

test("a browser that refuses storage does not break the theme", () => {
  const broken = { getItem() { throw new Error("denied"); }, setItem() { throw new Error("denied"); } };
  assert.equal(readTheme(broken), "system");
  assert.doesNotThrow(() => saveTheme(broken, "dark"));
});

test("a chosen theme is an attribute on the root and system removes it", () => {
  const attrs = new Map();
  const root = { setAttribute: (k, v) => attrs.set(k, v), removeAttribute: (k) => attrs.delete(k) };
  applyTheme(root, "dark");
  assert.equal(attrs.get("data-theme"), "dark");
  applyTheme(root, "light");
  assert.equal(attrs.get("data-theme"), "light");
  applyTheme(root, "system");
  assert.equal(attrs.has("data-theme"), false);
});

test("the theme switch is offered only where both palettes exist", () => {
  assert.equal(themeSwitchable("light dark"), true);
  assert.equal(themeSwitchable("dark"), false);
  assert.equal(themeSwitchable(""), false);
});

test("the lite stylesheet has both overrides and the full one stays dark only", () => {
  const lite = here("lite.css");
  assert.match(lite, /:root\[data-theme="light"\]\s*\{[^}]*color-scheme: light/);
  assert.match(lite, /:root\[data-theme="dark"\]\s*\{[^}]*color-scheme: dark/);
  assert.match(lite, /color-scheme: light dark/);
  assert.doesNotMatch(here("full.css"), /data-theme/);
  assert.doesNotMatch(here("full.css"), /color-scheme: light/);
});

test("the page has the chips, the user menu with Sign out and the theme item hidden until the script decides", () => {
  const html = here("index.html");
  for (const id of ["top-host", "top-state", "top-mode", "user-btn", "user-menu", "user-account", "theme-btn", "logout"]) {
    assert.match(html, new RegExp(`id="${id}"`), id);
  }
  assert.match(html, /id="theme-btn"[^>]*hidden/);
  assert.match(html, /id="user-menu"[^>]*hidden/);
});

function chips() {
  const node = () => ({ hidden: true, textContent: "", dataset: {} });
  return { host: node(), state: node(), mode: node() };
}

test("start paints the three chips from the three answers", async () => {
  const els = chips();
  const answers = { "/api/status": { health: { overall: "warn" } }, "/api/system": { hostname: "ids-gw-01" }, "/api/mode": { mode: "ips", pending: false } };
  const stop = start(async (path) => answers[path], els, () => assert.fail("no sign out"));
  await new Promise((r) => setTimeout(r, 10));
  stop();
  assert.equal(els.host.textContent, "ids-gw-01");
  assert.equal(els.host.hidden, false);
  assert.equal(els.state.textContent, "Warnings");
  assert.equal(els.state.dataset.level, "warn");
  assert.equal(els.mode.textContent, "IPS");
});

test("a failing source leaves only its own chip out", async () => {
  const els = chips();
  const stop = start(
    async (path) => {
      if (path === "/api/system") throw Object.assign(new Error("not found"), { status: 404 });
      return path === "/api/status" ? { health: { overall: "ok" } } : { mode: "ids" };
    },
    els,
    () => assert.fail("a 404 is not a sign out"),
  );
  await new Promise((r) => setTimeout(r, 10));
  stop();
  assert.equal(els.host.hidden, true);
  assert.equal(els.state.hidden, false);
  assert.equal(els.mode.textContent, "IDS");
});

test("a 401 is passed on and paints nothing", async () => {
  const els = chips();
  let signedOut = 0;
  const stop = start(async () => { throw Object.assign(new Error("no"), { status: 401 }); }, els, () => signedOut++);
  await new Promise((r) => setTimeout(r, 10));
  stop();
  assert.equal(signedOut, 1);
  assert.equal(els.state.hidden, true);
});

test("the user menu opens, and Escape and an outside click close it", () => {
  const listeners = { click: [], keydown: [] };
  const doc = {
    addEventListener: (t, f) => listeners[t].push(f),
    getElementById: (id) => (id === "user-btn" ? btn : menu),
  };
  let focused = false;
  const btn = { attrs: {}, setAttribute(k, v) { this.attrs[k] = v; }, addEventListener: (t, f) => (btn.onclick = f), contains: (n) => n === btn, focus() { focused = true; } };
  const menu = { hidden: true, contains: (n) => n === menu };
  userMenu(doc);
  btn.onclick();
  assert.equal(menu.hidden, false);
  assert.equal(btn.attrs["aria-expanded"], "true");
  listeners.keydown[0]({ key: "Escape" });
  assert.equal(menu.hidden, true);
  assert.equal(focused, true);
  btn.onclick();
  listeners.click[0]({ target: {} });
  assert.equal(menu.hidden, true);
  btn.onclick();
  listeners.click[0]({ target: menu });
  assert.equal(menu.hidden, false);
});
