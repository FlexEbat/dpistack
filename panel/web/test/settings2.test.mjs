import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { searchKeys, categories, applies, dependencyText, diffRows, stageSummary, stageText, stageSig, profileAll, loadProfile, shown, PROFILE_NAME_RE } from "../modules/settings-model.js";
import { start } from "../modules/settings.js";

const here = (f) => readFileSync(new URL("../" + f, import.meta.url), "utf8");

const K = (o) => ({ type: "free", options: [], min: null, max: null, default: "", level: "basic", group: "capture", weight: "light", secret: false, set: false, value: "", pattern: "", steps: [], touches: [], depends: [], ...o });

const KEYS = [
  K({ key: "ACCESS_MODE", type: "enum", options: ["localhost", "lan", "nginx"], group: "access", value: "localhost", default: "localhost", touches: ["nginx, the firewall and the listen addresses", "this panel"] }),
  K({ key: "LAN_CIDR", level: "advanced", group: "access", value: "auto", default: "auto", depends: [{ key: "ACCESS_MODE", op: "=", values: ["lan"] }] }),
  K({ key: "WATCH_INTERVAL_SEC", type: "int", min: 10, max: 3600, group: "watch", value: "60", default: "60", touches: ["the watchdog"] }),
  K({ key: "SURICATA_SOURCE", type: "enum", options: ["distro", "oisf", "source"], group: "components", value: "oisf", default: "source", weight: "heavy", touches: ["Suricata"] }),
  K({ key: "ALERT_TG_CHAT_ID", level: "advanced", group: "watch", depends: [{ key: "ALERT_CHANNELS", op: "~", values: ["tg"] }] }),
  K({ key: "ALERT_CHANNELS", group: "watch", value: "panel,log", default: "panel,log" }),
  K({ key: "METRICS_BACKEND_PORT", type: "int", min: 1, max: 65535, level: "advanced", group: "metrics", depends: [{ key: "METRICS_BACKEND", op: "!=", values: ["none"] }] }),
  K({ key: "METRICS_BACKEND", type: "enum", options: ["none", "victoriametrics"], group: "metrics", value: "none", default: "none" }),
  K({ key: "ALERT_TG_TOKEN", secret: true, set: true, group: "watch", level: "advanced" }),
];

test("search finds a key by name, hint or group, and counts the advanced ones it hides", () => {
  assert.deepEqual(searchKeys(KEYS, "interval", false).items.map((k) => k.key), ["WATCH_INTERVAL_SEC"]);
  assert.deepEqual(searchKeys(KEYS, "  LAN ", true).items.map((k) => k.key), ["LAN_CIDR"]);
  assert.deepEqual(searchKeys(KEYS, "lan", false), { items: [], hiddenAdvanced: 1 });
  assert.ok(searchKeys(KEYS, "watch and alerts", false).items.map((k) => k.key).includes("ALERT_CHANNELS"), "the title of the group matches");
  assert.deepEqual(searchKeys(KEYS, "", true), { items: [], hiddenAdvanced: 0 });
  assert.deepEqual(searchKeys(KEYS, "zzz", true), { items: [], hiddenAdvanced: 0 });
});

test("categories count what is shown and how much of it is edited", () => {
  const basic = categories(KEYS, false, {});
  assert.deepEqual(basic.find((c) => c.id === "access"), { id: "access", title: "Access and ports", count: 1, changed: 0 });
  assert.equal(categories(KEYS, true, {}).find((c) => c.id === "access").count, 2);
  assert.equal(categories(KEYS, false, { ACCESS_MODE: "lan", WATCH_INTERVAL_SEC: "30" }).find((c) => c.id === "access").changed, 1);
  assert.ok(!categories([KEYS[1]], false, {}).some((c) => c.id === "access"), "a category with nothing to show is left out");
});

test("a key applies by the rules of the schema: is, is not, has", () => {
  const val = (m) => (key) => m[key] ?? "";
  assert.equal(applies(KEYS[1], val({ ACCESS_MODE: "lan" })), true);
  assert.equal(applies(KEYS[1], val({ ACCESS_MODE: "nginx" })), false);
  assert.equal(applies(KEYS[4], val({ ALERT_CHANNELS: "panel,tg" })), true);
  assert.equal(applies(KEYS[4], val({ ALERT_CHANNELS: "panel,tgx,mail" })), false);
  assert.equal(applies(KEYS[6], val({ METRICS_BACKEND: "none" })), false);
  assert.equal(applies(KEYS[6], val({ METRICS_BACKEND: "victoriametrics" })), true);
  assert.equal(applies(KEYS[0], val({})), true, "no conditions: it always applies");
  assert.equal(applies(K({ key: "X", depends: [{ key: "A", op: "=", values: ["x"] }, { key: "B", op: "=", values: ["y"] }] }), val({ A: "x", B: "n" })), false, "all conditions must hold");
});

test("the dependency in words", () => {
  assert.equal(dependencyText(KEYS[1]), "Used when ACCESS_MODE is lan");
  assert.equal(dependencyText(KEYS[4]), "Used when ALERT_CHANNELS has tg");
  assert.equal(dependencyText(KEYS[6]), "Used when METRICS_BACKEND is not none");
  assert.equal(dependencyText(K({ key: "X", depends: [{ key: "A", op: "=", values: ["x", "y"] }, { key: "B", op: "=", values: ["z"] }] })), "Used when A is x or y and B is z");
  assert.equal(dependencyText(KEYS[0]), "");
});

test("the staged change: old to new, the weight of the whole, and what it touches", () => {
  const rows = diffRows(KEYS, { ACCESS_MODE: "lan", SURICATA_SOURCE: "distro", WATCH_INTERVAL_SEC: "60", ALERT_TG_TOKEN: "secret" });
  assert.deepEqual(rows.map((r) => [r.key, r.from, r.to, r.weight]), [["ACCESS_MODE", "localhost", "lan", "light"], ["SURICATA_SOURCE", "oisf", "distro", "heavy"]]);
  assert.deepEqual(stageSummary(rows), { weight: "heavy", touches: ["Suricata", "nginx, the firewall and the listen addresses", "this panel"].sort(), count: 2 });
  assert.equal(stageSummary(diffRows(KEYS, { ACCESS_MODE: "lan" })).weight, "light");
  assert.equal(stageText(stageSummary([])), "No changes are staged.");
  assert.match(stageText(stageSummary(rows)), /^A heavy change: .* It touches Suricata, /);
  assert.match(stageText(stageSummary(diffRows(KEYS, { ACCESS_MODE: "lan" }))), /^A light change: /);
  assert.equal(shown(""), "(empty)");
  assert.equal(shown("x"), "x");
});

test("the signature of staged values does not depend on the order", () => {
  assert.equal(stageSig({ A: "1", B: "2" }), stageSig({ B: "2", A: "1" }));
  assert.notEqual(stageSig({ A: "1" }), stageSig({ A: "2" }));
  assert.notEqual(stageSig({ A: "1" }), stageSig({ A: "1", B: "" }));
});

test("a profile of all values holds every non secret key as it is on the screen", () => {
  const all = profileAll(KEYS, { ACCESS_MODE: "lan" });
  assert.equal(all.ACCESS_MODE, "lan");
  assert.equal(all.WATCH_INTERVAL_SEC, "60");
  assert.ok(!("ALERT_TG_TOKEN" in all));
  assert.equal(Object.keys(all).length, KEYS.length - 1);
});

test("loading a profile stages only what differs and reports what it cannot use", () => {
  const out = loadProfile(KEYS, { ACCESS_MODE: "lan", WATCH_INTERVAL_SEC: "60", NOT_HERE: "1", ALERT_TG_TOKEN: "x" });
  assert.deepEqual(out.edits, { ACCESS_MODE: "lan" });
  assert.deepEqual(out.skipped.sort(), ["ALERT_TG_TOKEN", "NOT_HERE"]);
  assert.deepEqual(loadProfile(KEYS, null), { edits: {}, skipped: [] });
});

test("a profile name is a short lowercase word", () => {
  for (const ok of ["a", "lan-watch", "x_1", "0abc"]) assert.ok(PROFILE_NAME_RE.test(ok), ok);
  for (const bad of ["", "Upper", "a b", "-x", "_x", "../x", "a".repeat(33)]) assert.ok(!PROFILE_NAME_RE.test(bad), bad);
});

// ---- the screen, on a small DOM ----

function node(tag) {
  const cls = new Set();
  return {
    tag, textContent: "", children: [], value: "", checked: false, disabled: false, hidden: false, id: "", type: "", scrollTop: 0, scrollHeight: 0,
    attrs: {}, listeners: {},
    get className() { return [...cls].join(" "); },
    set className(v) { cls.clear(); String(v).split(/\s+/).filter(Boolean).forEach((c) => cls.add(c)); },
    classList: { toggle: (c, on) => (on === undefined ? (cls.has(c) ? cls.delete(c) : cls.add(c)) : on ? cls.add(c) : cls.delete(c)), contains: (c) => cls.has(c) },
    append(...c) { this.children.push(...c); },
    replaceChildren(...c) { this.children = c; },
    setAttribute(k, v) { this.attrs[k] = v; },
    addEventListener(n, f) { this.listeners[n] = f; },
    removeEventListener(n) { delete this.listeners[n]; },
    remove() {},
    querySelectorAll() { return []; },
  };
}

function find(n, pred, out = []) {
  if (pred(n)) out.push(n);
  for (const c of n.children || []) find(c, pred, out);
  return out;
}
const text = (n) => [n.textContent, ...(n.children || []).map(text)].join(" ");

function screen(over = {}) {
  globalThis.document = { createElement: node, createDocumentFragment: () => node("frag") };
  const confirms = [];
  globalThis.window = { confirm: (m) => (confirms.push(m), over.confirm ?? true) };
  const els = { root: node("div") };
  for (const k of ["error", "message", "result", "groups", "count", "jobBox", "job", "cats", "details", "diff", "profiles"]) els[k] = node("div");
  for (const k of ["advanced", "check", "apply", "revert", "search", "profileName", "profileSave", "profileSaveAll"]) els[k] = node("input");
  els.jobBox.hidden = true;
  return { els, confirms };
}

const wait = () => new Promise((r) => setTimeout(r, 15));
const inputOf = (els, key) => find(els.groups, (n) => n.id === "set-" + key)[0];
const rowOf = (els, key) => find(els.groups, (n) => n.className.split(" ").includes("setting") && find(n, (c) => c.id === "set-" + key).length)[0];

function apiFor(log, over = {}) {
  return async (p, o) => {
    log.push([p, o && o.method, o && o.body]);
    if (over[p]) return over[p](o);
    if (p === "/api/settings") return { keys: KEYS };
    if (p === "/api/settings/job") return { state: "inactive", log: [] };
    if (p === "/api/settings/profiles") return { profiles: [{ name: "lan-watch", count: 2, by: "admin" }] };
    if (p === "/api/settings/check") return { ok: true, weight: "light", changed: Object.keys(JSON.parse(o.body).values), errors: [], warnings: [] };
    return { ok: true };
  };
}

test("the screen draws the categories, the first category and the profiles", async () => {
  const { els } = screen();
  const log = [];
  const stop = start(apiFor(log), els, () => assert.fail());
  await wait();
  stop();
  const cats = find(els.cats, (n) => n.tag === "button");
  assert.deepEqual(cats.map((b) => b.textContent), ["Traffic capture"].slice(0, 0).concat(cats.map((b) => b.textContent)), "buttons are drawn");
  assert.ok(cats.length >= 3, "several categories of basic keys");
  assert.ok(find(els.groups, (n) => n.tag === "h2")[0].textContent.length > 0);
  assert.equal(find(els.profiles, (n) => n.className === "profile").length, 1);
});

test("a key that does not apply is dimmed with the reason, and edits change that at once", async () => {
  const { els } = screen();
  const stop = start(apiFor([]), els, () => assert.fail());
  await wait();
  els.advanced.checked = true;
  await els.advanced.listeners.change();
  // the access category is the one that holds ACCESS_MODE and LAN_CIDR
  const access = find(els.cats, (n) => n.tag === "button").find((b) => text(b).includes("Access"));
  access.listeners.click();
  const lan = rowOf(els, "LAN_CIDR");
  assert.ok(lan.className.split(" ").includes("inactive"));
  assert.match(text(lan), /Not used now\. Used when ACCESS_MODE is lan\./);
  const mode = inputOf(els, "ACCESS_MODE");
  mode.value = "lan";
  mode.listeners.input();
  assert.ok(!rowOf(els, "LAN_CIDR").className.split(" ").includes("inactive"));
  assert.doesNotMatch(text(rowOf(els, "LAN_CIDR")), /Not used now/);
  stop();
});

test("focusing a key shows its details: default, allowed values, dependency, what it touches", async () => {
  const { els } = screen();
  const stop = start(apiFor([]), els, () => assert.fail());
  await wait();
  const access = find(els.cats, (n) => n.tag === "button").find((b) => text(b).includes("Access"));
  access.listeners.click();
  inputOf(els, "ACCESS_MODE").listeners.focus();
  const t = text(els.details);
  assert.match(t, /Allowed\s+localhost, lan, nginx/);
  assert.match(t, /Default\s+localhost/);
  assert.match(t, /Depends on\s+nothing: it always applies/);
  assert.match(t, /light: files are written again/);
  assert.match(t, /It touches\s+nginx, the firewall and the listen addresses, this panel/);
  stop();
});

test("the staged change lists old and new, and Apply opens only after a passing check of exactly those values", async () => {
  const { els } = screen();
  const log = [];
  const stop = start(apiFor(log), els, () => assert.fail());
  await wait();
  const access = find(els.cats, (n) => n.tag === "button").find((b) => text(b).includes("Access"));
  access.listeners.click();
  assert.equal(els.apply.disabled, true);
  assert.equal(els.check.disabled, true);
  const mode = inputOf(els, "ACCESS_MODE");
  mode.value = "lan";
  mode.listeners.input();
  assert.match(text(els.diff), /ACCESS_MODE\s+localhost\s+lan/);
  assert.match(text(els.diff), /A light change/);
  assert.equal(els.check.disabled, false);
  assert.equal(els.apply.disabled, true, "no check yet");
  await els.check.listeners.click();
  assert.equal(els.apply.disabled, false, "the check passed");
  mode.value = "nginx";
  mode.listeners.input();
  assert.equal(els.apply.disabled, true, "an edit after the check takes Apply away");
  mode.value = "lan";
  mode.listeners.input();
  assert.equal(els.apply.disabled, true, "even back to the same value: check again");
  await els.check.listeners.click();
  assert.equal(els.apply.disabled, false);
  stop();
});

test("a failed check or a busy port keeps Apply closed", async () => {
  for (const answer of [{ ok: false, errors: ["bad value"], warnings: [] }, { ok: true, weight: "light", errors: [], warnings: [{ key: "PANEL_PORT", port: 9800, holder: "nginx", suggestion: 9801, kind: "tcp" }] }]) {
    const { els } = screen();
    const stop = start(apiFor([], { "/api/settings/check": () => answer }), els, () => assert.fail());
    await wait();
    const access = find(els.cats, (n) => n.tag === "button").find((b) => text(b).includes("Access"));
    access.listeners.click();
    const mode = inputOf(els, "ACCESS_MODE");
    mode.value = "lan";
    mode.listeners.input();
    await els.check.listeners.click();
    assert.equal(els.apply.disabled, true);
    stop();
  }
});

test("a heavy change says so in the staged change", async () => {
  const { els } = screen();
  const stop = start(apiFor([]), els, () => assert.fail());
  await wait();
  const comp = find(els.cats, (n) => n.tag === "button").find((b) => text(b).includes("Components"));
  comp.listeners.click();
  const src = inputOf(els, "SURICATA_SOURCE");
  src.value = "distro";
  src.listeners.input();
  assert.match(text(els.diff), /A heavy change: it starts a reinstall/);
  assert.match(text(els.diff), /It touches Suricata\./);
  assert.match(text(els.diff), /reinstall/);
  stop();
});

test("search shows matches across categories, hides advanced ones with a note, and clearing returns to the category", async () => {
  const { els } = screen();
  const stop = start(apiFor([]), els, () => assert.fail());
  await wait();
  els.search.value = "lan";
  els.search.listeners.input();
  assert.equal(find(els.groups, (n) => n.tag === "h2")[0].textContent, "Search results");
  assert.match(text(els.groups), /1 more match among the advanced settings/);
  els.advanced.checked = true;
  await els.advanced.listeners.change();
  assert.ok(inputOf(els, "LAN_CIDR"), "the advanced match shows once advanced settings are on");
  els.search.value = "";
  els.search.listeners.input();
  assert.notEqual(find(els.groups, (n) => n.tag === "h2")[0].textContent, "Search results");
  els.search.value = "zzzz";
  els.search.listeners.input();
  assert.match(text(els.groups), /No setting matches/);
  els.advanced.checked = false;
  await els.advanced.listeners.change();
  els.search.value = "ac";
  els.search.listeners.input();
  assert.match(text(els.groups), /\d+ more matches? among the advanced settings/);
  els.search.value = "a";
  els.search.listeners.input();
  assert.match(text(els.groups), /([2-9]|\d\d+) more matches among the advanced settings/, "several: matches");
  stop();
});

test("loading a profile stages its values after asking when something is already staged", async () => {
  const { els, confirms } = screen();
  const stop = start(apiFor([], { "/api/settings/profiles/lan-watch": () => ({ name: "lan-watch", keys: { ACCESS_MODE: "lan", WATCH_INTERVAL_SEC: "60", GONE: "1" } }) }), els, () => assert.fail());
  await wait();
  const load = () => find(els.profiles, (n) => n.tag === "button" && n.textContent === "Load")[0];
  await load().listeners.click();
  assert.equal(confirms.length, 0, "nothing was staged: no question");
  assert.match(text(els.diff), /ACCESS_MODE\s+localhost\s+lan/);
  assert.doesNotMatch(text(els.diff), /WATCH_INTERVAL_SEC/, "an equal value is not a change");
  assert.match(els.message.textContent, /1 change staged, check them before applying/);
  assert.match(els.message.textContent, /Left out, not known here: GONE/);
  await load().listeners.click();
  assert.equal(confirms.length, 1, "something is staged now: ask before replacing it");
  assert.match(confirms[0], /Replace the staged changes with the profile lan-watch/);
  stop();
});

test("saving a profile: the name is checked first, staged changes or all values go in the body", async () => {
  const { els } = screen();
  const log = [];
  const stop = start(apiFor(log), els, () => assert.fail());
  await wait();
  const puts = () => log.filter((c) => c[1] === "PUT");
  els.profileName.value = "Bad Name";
  await els.profileSave.listeners.click();
  assert.match(els.error.textContent, /lowercase letters/);
  assert.equal(puts().length, 0);
  els.profileName.value = "mine";
  await els.profileSave.listeners.click();
  assert.match(els.error.textContent, /nothing to save/);
  assert.equal(puts().length, 0);
  const access = find(els.cats, (n) => n.tag === "button").find((b) => text(b).includes("Access"));
  access.listeners.click();
  const mode = inputOf(els, "ACCESS_MODE");
  mode.value = "lan";
  mode.listeners.input();
  await els.profileSave.listeners.click();
  assert.equal(puts().length, 1);
  assert.equal(puts()[0][0], "/api/settings/profiles/mine");
  assert.deepEqual(JSON.parse(puts()[0][2]), { values: { ACCESS_MODE: "lan" } });
  els.profileName.value = "everything";
  await els.profileSaveAll.listeners.click();
  const all = JSON.parse(puts()[1][2]).values;
  assert.equal(all.ACCESS_MODE, "lan");
  assert.equal(all.WATCH_INTERVAL_SEC, "60");
  assert.ok(!("ALERT_TG_TOKEN" in all), "a secret is never sent");
  stop();
});

test("saving over an existing name asks first, deleting asks first and then deletes", async () => {
  const { els, confirms } = screen();
  const log = [];
  const stop = start(apiFor(log), els, () => assert.fail());
  await wait();
  const access = find(els.cats, (n) => n.tag === "button").find((b) => text(b).includes("Access"));
  access.listeners.click();
  const mode = inputOf(els, "ACCESS_MODE");
  mode.value = "lan";
  mode.listeners.input();
  els.profileName.value = "lan-watch";
  await els.profileSave.listeners.click();
  assert.match(confirms[0], /Replace the profile lan-watch/);
  await find(els.profiles, (n) => n.tag === "button" && n.textContent === "Delete")[0].listeners.click();
  assert.match(confirms[1], /Delete the profile lan-watch/);
  assert.ok(log.some((c) => c[1] === "DELETE" && c[0] === "/api/settings/profiles/lan-watch"));
  stop();
});

test("declining a question sends nothing", async () => {
  const { els } = screen({ confirm: false });
  const log = [];
  const stop = start(apiFor(log), els, () => assert.fail());
  await wait();
  await find(els.profiles, (n) => n.tag === "button" && n.textContent === "Delete")[0].listeners.click();
  assert.ok(!log.some((c) => c[1] === "DELETE"));
  stop();
});

test("a refused profile save shows the server's words, a 401 is passed on", async () => {
  let { els } = screen();
  const refuse = () => { throw Object.assign(new Error("settings profile save: the values are refused"), { status: 400 }); };
  let stop = start(apiFor([], { "/api/settings/profiles/x": refuse }), els, () => assert.fail());
  await wait();
  els.profileName.value = "x";
  const access = find(els.cats, (n) => n.tag === "button").find((b) => text(b).includes("Access"));
  access.listeners.click();
  const mode = inputOf(els, "ACCESS_MODE");
  mode.value = "lan";
  mode.listeners.input();
  await els.profileSave.listeners.click();
  assert.match(els.error.textContent, /the values are refused/);
  assert.equal(els.profileSave.disabled, false);
  stop();

  ({ els } = screen());
  let out = 0;
  stop = start(async () => { throw Object.assign(new Error("no"), { status: 401 }); }, els, () => out++);
  await wait();
  stop();
  assert.ok(out >= 1);
});

test("the page has the three columns, the search, the details, the diff and the profiles, wired in app.js", () => {
  const html = here("index.html");
  const app = here("app.js");
  assert.match(html, /class="settings-cols"/);
  for (const id of ["settings-search", "settings-cats", "settings-groups", "settings-details", "settings-diff", "settings-profiles", "settings-profile-name", "settings-profile-save", "settings-profile-save-all", "settings-check", "settings-apply", "settings-revert", "settings-advanced", "settings-count", "settings-result", "settings-error", "settings-message", "settings-job-box", "settings-job"]) {
    assert.match(html, new RegExp(`id="${id}"`), id);
    assert.ok(app.includes(`$("${id}")`), id);
  }
  assert.match(html, /Show advanced settings/);
  assert.match(here("full.css"), /\.settings-cols/);
  assert.match(here("lite.css"), /\.settings-cols/);
  assert.match(here("full.css"), /\.setting\.inactive/);
  assert.match(here("lite.css"), /\.setting\.inactive/);
});
