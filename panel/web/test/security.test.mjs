import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { levelOf, levelWord, checkSummary, scopeText, tokenBody, sessionRows, tokenRows, loginRows, resultWord, SCOPES, SIGN_OUT_ALL_QUESTION, TOKEN_SHOWN_ONCE, TOKEN_NAME_RE } from "../modules/security-model.js";
import { start } from "../modules/security.js";

const here = (f) => readFileSync(new URL("../" + f, import.meta.url), "utf8");

test("levels and words", () => {
  assert.equal(levelOf("crit"), "crit");
  assert.equal(levelOf("na"), "na");
  assert.equal(levelOf("weird"), "na");
  assert.equal(levelWord("warn"), "warning");
  assert.equal(levelWord("na"), "not known");
  assert.equal(checkSummary({ ok: 3, warn: 1, crit: 2, na: 0 }), "3 ok, 1 warning, 2 critical, 0 not known");
  assert.equal(checkSummary({ ok: 1, warn: 2, crit: 0, na: 1 }), "1 ok, 2 warnings, 0 critical, 1 not known");
  assert.equal(checkSummary(null), "");
});

test("a scope is read only or a role, and never more than the owner", () => {
  assert.match(scopeText("read"), /read only/);
  assert.match(scopeText("analyst"), /role analyst, never more than its owner may do/);
  assert.deepEqual(SCOPES, ["read", "viewer", "analyst", "operator", "admin"]);
});

test("the body of a new token is checked before it is sent", () => {
  assert.deepEqual(tokenBody("ci job", "read", "30").body, { name: "ci job", scope: "read", days: 30 });
  assert.deepEqual(tokenBody("x", "admin", 365).body, { name: "x", scope: "admin", days: 365 });
  for (const bad of ["", "Upper", "-x", "a;b", "a".repeat(33)]) assert.match(tokenBody(bad, "read", 30).error, /name is 1 to 32/, bad);
  assert.match(tokenBody("x", "root", 30).error, /Choose a scope/);
  assert.match(tokenBody("x", "custom", 30).error, /Choose a scope/);
  for (const d of ["0", "366", "1.5", "abc", "", "-1"]) assert.match(tokenBody("x", "read", d).error, /1 to 365/, d);
  assert.ok(TOKEN_NAME_RE.test("a b.c_d-e"));
});

test("session, token and login rows say what the lists need", () => {
  const s = sessionRows([{ handle: "h1", user: "an", ip: "10.0.0.1", user_agent: "Firefox", created: "2026-01-01T00:00:00Z", expires: "2026-01-01T12:00:00Z", current: true }, { handle: "h2", user: "an", created: "x", expires: "y" }]);
  assert.equal(s[0].where, "10.0.0.1");
  assert.equal(s[0].current, true);
  assert.equal(s[1].where, "unknown");
  assert.equal(s[1].client, "unknown");
  assert.equal(s[1].current, false);
  const t = tokenRows([{ id: "1", name: "a", user: "an", scope: "read", created: "2026-01-01T00:00:00Z", expires: "2026-04-01T00:00:00Z", expired: false, last_used: "2026-01-02T00:00:00Z" }, { id: "2", name: "b", user: "an", scope: "admin", created: "c", expires: "e", expired: true }]);
  assert.equal(t[0].status, "active");
  assert.equal(t[1].status, "expired");
  assert.equal(t[1].lastUsed, "not since the panel started");
  assert.notEqual(t[0].lastUsed, "not since the panel started");
  const l = loginRows([{ ts: "2026-01-01T00:00:00Z", user: "an", ip: "1.2.3.4", result: "ok" }, { ts: "x", user: "an", ip: "", result: "denied" }, { ts: "y", user: "an", result: "error" }]);
  assert.deepEqual(l.map((x) => x.level), ["ok", "warn", "warn"]);
  assert.equal(resultWord("denied"), "refused: wrong user or password");
  assert.equal(resultWord("error"), "refused: too many tries");
  assert.equal(sessionRows(null).length, 0);
});

test("the texts say what a person needs to know before they act", () => {
  assert.match(SIGN_OUT_ALL_QUESTION, /yours too/);
  assert.match(SIGN_OUT_ALL_QUESTION, /API tokens are not affected/);
  assert.match(TOKEN_SHOWN_ONCE, /only once/);
});

// ---- the screen, on a small DOM ----

function node(tag) {
  return {
    tag, textContent: "", className: "", children: [], value: "", checked: false, disabled: false, hidden: false, type: "", attrs: {}, listeners: {},
    append(...c) { this.children.push(...c); },
    replaceChildren(...c) { this.children = c; },
    setAttribute(k, v) { this.attrs[k] = v; },
    addEventListener(n, f) { this.listeners[n] = f; },
    removeEventListener(n) { delete this.listeners[n]; },
  };
}
const find = (n, pred, out = []) => (pred(n) && out.push(n), (n.children || []).forEach((c) => find(c, pred, out)), out);
const text = (n) => [n.textContent, ...(n.children || []).map(text)].join(" ");

function screen(perms, over = {}) {
  globalThis.document = { createElement: node };
  const confirms = [];
  globalThis.window = { confirm: (m) => (confirms.push(m), over.confirm ?? true) };
  Object.defineProperty(globalThis, "navigator", { value: { clipboard: { writeText: async (t) => { screen.copied = t; } } }, configurable: true, writable: true });
  const areas = {};
  for (const k of ["error", "message", "checkBox", "checkSummary", "checkList", "sessions", "tokens", "tokenAllBox", "secretBox", "secret", "secretNote", "logins", "loginScopeBox", "signOutAll"]) areas[k] = node("div");
  for (const k of ["run", "endOthers", "tokenCreate", "secretCopy", "secretHide", "tokenAll", "tokenName", "tokenScope", "tokenDays", "loginScope"]) areas[k] = node("input");
  areas.tokenDays.value = "90";
  areas.loginScope.value = "mine";
  return { areas, confirms, perms };
}

const checkDoc = { counts: { ok: 1, warn: 1, crit: 0, na: 0 }, checks: [{ id: "tls", level: "warn", title: "Encryption", detail: "plain HTTP", fix: "dpistack settings set NGINX_TLS=selfsigned" }, { id: "x", level: "ok", title: "Fine", detail: "ok", fix: "" }] };
const sessionsDoc = { sessions: [{ handle: "aaaaaaaaaaaaaaaa", user: "an", ip: "10.0.0.1", user_agent: "Firefox", created: "2026-01-01T00:00:00Z", expires: "2026-01-01T12:00:00Z", current: true }, { handle: "bbbbbbbbbbbbbbbb", user: "an", ip: "10.0.0.2", user_agent: "curl", created: "2026-01-01T00:00:00Z", expires: "2026-01-01T12:00:00Z", current: false }] };
const tokensDoc = { tokens: [{ id: "11111111", name: "backup", user: "an", scope: "read", created: "2026-01-01T00:00:00Z", expires: "2026-04-01T00:00:00Z", expired: false }] };
const loginsDoc = { logins: [{ ts: "2026-01-01T00:00:00Z", user: "an", ip: "10.0.0.1", result: "ok" }] };

function apiFor(log, over = {}) {
  return async (p, o) => {
    log.push([p, o && o.method, o && o.body]);
    if (over[p]) return over[p](o);
    if (p === "/api/security/check") return checkDoc;
    if (p.startsWith("/api/security/sessions/revoke")) return { ended: 2 };
    if (p.startsWith("/api/security/sessions")) return o && o.method === "DELETE" ? { ok: true } : sessionsDoc;
    if (p.startsWith("/api/security/tokens")) return o && o.method === "POST" ? { id: "abcd1234", token: "dpt_SECRET", expires: "2030-01-01T00:00:00Z" } : o && o.method === "DELETE" ? { ok: true } : tokensDoc;
    if (p.startsWith("/api/security/logins")) return loginsDoc;
    return {};
  };
}
const ADMIN = ["view", "audit.view", "users.manage"];
const wait = () => new Promise((r) => setTimeout(r, 15));

test("an admin sees every part: the check, sessions, tokens, history", async () => {
  const { areas, perms } = screen(ADMIN);
  const stop = start(apiFor([]), areas, () => assert.fail(), perms);
  await wait();
  stop();
  assert.equal(areas.checkSummary.textContent, "1 ok, 1 warning, 0 critical, 0 not known");
  assert.match(text(areas.checkList), /To fix: dpistack settings set NGINX_TLS=selfsigned/);
  assert.match(text(areas.sessions), /10\.0\.0\.1/);
  assert.match(text(areas.sessions), /this one/);
  assert.match(text(areas.tokens), /backup/);
  assert.match(text(areas.logins), /signed in/);
  assert.equal(areas.checkBox.hidden, false);
  assert.equal(areas.signOutAll.hidden, false);
  assert.equal(areas.tokenAllBox.hidden, false);
  assert.equal(areas.loginScopeBox.hidden, false);
  assert.equal(areas.secretBox.hidden, true, "no secret on a fresh screen");
  assert.equal(areas.tokenScope.children.length, 5);
});

test("what needs a permission is hidden and not even requested without it", async () => {
  for (const [perms, check, signOut, all] of [[["view", "audit.view"], true, false, false], [["view"], false, false, false]]) {
    const { areas } = screen(perms);
    const log = [];
    const stop = start(apiFor(log), areas, () => assert.fail(), perms);
    await wait();
    stop();
    assert.equal(!areas.checkBox.hidden, check);
    assert.equal(!areas.signOutAll.hidden, signOut);
    assert.equal(!areas.tokenAllBox.hidden, all);
    assert.equal(log.some((c) => c[0] === "/api/security/check"), check);
    assert.equal(!areas.loginScopeBox.hidden, check);
  }
});

test("making a token: refused locally when wrong, else posted, the secret shown once, the list read again", async () => {
  const { areas, perms } = screen(ADMIN);
  const log = [];
  const stop = start(apiFor(log), areas, () => assert.fail(), perms);
  await wait();
  const posts = () => log.filter((c) => c[1] === "POST" && c[0] === "/api/security/tokens");
  areas.tokenName.value = "Bad Name";
  areas.tokenScope.value = "read";
  await areas.tokenCreate.listeners.click();
  assert.match(areas.error.textContent, /name is 1 to 32/);
  assert.equal(posts().length, 0);
  areas.tokenName.value = "backup script";
  areas.tokenScope.value = "analyst";
  areas.tokenDays.value = "30";
  const before = log.filter((c) => c[0].startsWith("/api/security/tokens") && !c[1]).length;
  await areas.tokenCreate.listeners.click();
  assert.deepEqual(JSON.parse(posts()[0][2]), { name: "backup script", scope: "analyst", days: 30 });
  assert.equal(areas.secret.textContent, "dpt_SECRET");
  assert.equal(areas.secretBox.hidden, false);
  assert.match(areas.secretNote.textContent, /only once/);
  assert.equal(areas.tokenName.value, "");
  assert.equal(areas.tokenCreate.disabled, false);
  assert.ok(log.filter((c) => c[0].startsWith("/api/security/tokens") && !c[1]).length > before, "the list is read again");
  await areas.secretHide.listeners.click();
  assert.equal(areas.secret.textContent, "");
  assert.equal(areas.secretBox.hidden, true);
  stop();
});

test("the secret is cleared when the screen is left, and can be copied", async () => {
  const { areas, perms } = screen(ADMIN);
  const stop = start(apiFor([]), areas, () => assert.fail(), perms);
  await wait();
  areas.tokenName.value = "x";
  areas.tokenScope.value = "read";
  await areas.tokenCreate.listeners.click();
  await areas.secretCopy.listeners.click();
  assert.equal(screen.copied, "dpt_SECRET");
  assert.equal(areas.message.textContent, "Copied.");
  stop();
  assert.equal(areas.secret.textContent, "", "leaving the screen forgets the secret");
  assert.equal(areas.secretBox.hidden, true);
  assert.equal(areas.run.listeners.click, undefined, "the listeners are removed");
});

test("a refused token (the server says why) shows its words and the button is free again", async () => {
  const { areas, perms } = screen(["view"]);
  const stop = start(apiFor([], { "/api/security/tokens": (o) => { if (o && o.method === "POST") throw Object.assign(new Error("tokens create: the scope admin holds more than an may do"), { status: 400 }); return tokensDoc; } }), areas, () => assert.fail(), perms);
  await wait();
  areas.tokenName.value = "x";
  areas.tokenScope.value = "admin";
  await areas.tokenCreate.listeners.click();
  stop();
  assert.match(areas.error.textContent, /more than an may do/);
  assert.equal(areas.tokenCreate.disabled, false);
  assert.equal(areas.secretBox.hidden, true);
});

test("revoking a token asks first, and declining sends nothing", async () => {
  for (const [answer, sent] of [[true, true], [false, false]]) {
    const { areas, confirms, perms } = screen(ADMIN, { confirm: answer });
    const log = [];
    const stop = start(apiFor(log), areas, () => assert.fail(), perms);
    await wait();
    await find(areas.tokens, (n) => n.tag === "button" && n.textContent === "Revoke")[0].listeners.click();
    stop();
    assert.match(confirms[0], /Revoke the token "backup"/);
    assert.equal(log.some((c) => c[1] === "DELETE" && c[0] === "/api/security/tokens/11111111"), sent);
  }
});

test("ending a session, the others, and everyone", async () => {
  const { areas, confirms, perms } = screen(ADMIN);
  const log = [];
  const stop = start(apiFor(log), areas, () => assert.fail(), perms);
  await wait();
  const buttons = find(areas.sessions, (n) => n.tag === "button");
  assert.deepEqual(buttons.map((b) => b.textContent), ["Sign out", "End"], "the current one is a sign out");
  await buttons[1].listeners.click();
  assert.ok(log.some((c) => c[1] === "DELETE" && c[0] === "/api/security/sessions/bbbbbbbbbbbbbbbb"));
  assert.equal(areas.message.textContent, "Session ended.");
  await areas.endOthers.listeners.click();
  assert.ok(log.some((c) => c[1] === "POST" && c[0] === "/api/security/sessions/revoke-others"));
  assert.equal(areas.message.textContent, "2 other sessions ended.");
  assert.equal(confirms.length, 0, "ending your own others needs no question");
  await areas.signOutAll.listeners.click();
  assert.match(confirms[0], /Sign everyone out/);
  assert.ok(log.some((c) => c[1] === "POST" && c[0] === "/api/security/sessions/revoke-all"));
  stop();
});

test("signing everyone out asks first and declining sends nothing", async () => {
  const { areas, perms } = screen(ADMIN, { confirm: false });
  const log = [];
  const stop = start(apiFor(log), areas, () => assert.fail(), perms);
  await wait();
  await areas.signOutAll.listeners.click();
  stop();
  assert.ok(!log.some((c) => c[0].endsWith("revoke-all")));
});

test("the scope of the history and of the token list follow their switches", async () => {
  const { areas, perms } = screen(ADMIN);
  const log = [];
  const stop = start(apiFor(log), areas, () => assert.fail(), perms);
  await wait();
  areas.loginScope.value = "all";
  await areas.loginScope.listeners.change();
  assert.ok(log.some((c) => c[0] === "/api/security/logins?all=1"));
  areas.tokenAll.checked = true;
  await areas.tokenAll.listeners.change();
  assert.ok(log.some((c) => c[0] === "/api/security/tokens?all=1"));
  stop();
  assert.equal(areas.loginScope.listeners.change, undefined);
});

test("a failing read shows its message, one part failing leaves the others, a 401 is passed on", async () => {
  let { areas, perms } = screen(ADMIN);
  let stop = start(apiFor([], { "/api/security/check": () => { throw Object.assign(new Error("security check: jq is needed"), { status: 500 }); } }), areas, () => assert.fail(), perms);
  await wait();
  stop();
  assert.match(areas.error.textContent, /jq is needed/);
  assert.match(text(areas.sessions), /10\.0\.0\.1/, "the sessions still drew");
  assert.match(text(areas.logins), /signed in/);

  ({ areas, perms } = screen(ADMIN));
  let out = 0;
  stop = start(async () => { throw Object.assign(new Error("no"), { status: 401 }); }, areas, () => out++, perms);
  await wait();
  stop();
  assert.ok(out >= 1);
});

test("the page has the Security screen: the menu entry in Admin, every element, and the wiring", () => {
  const html = here("index.html");
  const app = here("app.js");
  assert.match(html, /id="view-security"/);
  const admin = html.match(/aria-label="Admin">[\s\S]*?<\/div>/)[0];
  assert.match(admin, /data-view="security"/);
  const ids = ["sec-error", "sec-message", "sec-check-box", "sec-check-summary", "sec-check-list", "sec-run", "sec-sessions", "sec-others", "sec-signout-all", "sec-tokens", "sec-token-all-box", "sec-token-all", "sec-token-name", "sec-token-scope", "sec-token-days", "sec-token-create", "sec-secret-box", "sec-secret", "sec-secret-note", "sec-secret-copy", "sec-secret-hide", "sec-logins", "sec-login-scope-box", "sec-login-scope"];
  for (const id of ids) {
    assert.match(html, new RegExp(`id="${id}"`), id);
    assert.ok(app.includes(`$("${id}")`), id);
  }
  assert.match(app, /"audit", "security"/);
  assert.match(html, /id="sec-secret-box" class="secret-box" hidden/, "the secret box starts hidden");
  assert.match(html, /id="sec-token-days"[^>]*value="90"/);
  assert.match(html, /There is no session key to rotate/);
  assert.match(here("app.css"), /\.secret-box/);
  assert.match(here("app.css"), /\.secret-box/);
});
