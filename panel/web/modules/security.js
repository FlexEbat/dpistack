// The Security screen (slice 45): the security check, the sessions of the
// signed in user, API tokens, and the history of sign ins. Everything is read
// from /api/security/*. Ending sessions and making or revoking tokens is a
// request each, after which the lists are read again. The secret of a new
// token is shown once, in a box that goes away with the next action. Only a
// 401 signs the user out.

import { levelOf, levelWord, checkSummary, SCOPES, scopeText, tokenBody, sessionRows, tokenRows, loginRows, SIGN_OUT_ALL_QUESTION, TOKEN_SHOWN_ONCE } from "./security-model.js";

const POLL_MS = 30000;

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

const badge = (level, text) => el("span", "badge " + (level || "na"), text);

function cell(...nodes) {
  const td = el("td");
  td.append(...nodes);
  return td;
}

function table(head, rows) {
  const t = el("table");
  const tr = el("tr");
  for (const h of head) tr.append(el("th", "", h));
  t.append(tr);
  for (const r of rows) t.append(r);
  return t;
}

function button(label, onClick) {
  const b = el("button", "small", label);
  b.type = "button";
  b.addEventListener("click", onClick);
  return b;
}

export function start(api, areas, onError, perms) {
  const can = (p) => perms.includes(p);
  let running = true;
  let timer = null;
  let busy = false;

  function fail(err) {
    if (err.status === 401) return onError(err);
    areas.error.textContent = err.message;
  }

  function say(text) {
    areas.message.textContent = text;
  }

  // The parts that need a permission are hidden without it.
  areas.checkBox.hidden = !can("audit.view");
  areas.loginScopeBox.hidden = !can("audit.view");
  areas.signOutAll.hidden = !can("users.manage");
  areas.tokenAllBox.hidden = !can("users.manage");

  function renderCheck(res) {
    areas.checkSummary.textContent = checkSummary(res.counts);
    const rows = (res.checks || []).map((c) => {
      const tr = el("tr");
      const what = el("div");
      what.append(el("div", "", c.title), el("div", "muted", c.detail));
      if (c.fix) what.append(el("div", "hint", "To fix: " + c.fix));
      tr.append(cell(badge(levelOf(c.level), levelWord(c.level))), cell(what));
      return tr;
    });
    areas.checkList.replaceChildren(rows.length ? table(["Level", "Check"], rows) : el("p", "muted empty", "No checks reported."));
  }

  function renderSessions(res) {
    const list = sessionRows(res.sessions);
    if (!list.length) {
      areas.sessions.replaceChildren(el("p", "muted empty", "No sessions."));
      return;
    }
    const rows = list.map((s) => {
      const tr = el("tr");
      const who = el("div");
      who.append(el("div", "", s.where), el("div", "muted", s.client));
      tr.append(cell(who), cell(el("span", "", s.started)), cell(el("span", "", s.expires)), cell(s.current ? badge("ok", "this one") : el("span", "", "")));
      tr.append(cell(button(s.current ? "Sign out" : "End", () => endSession(s))));
      return tr;
    });
    areas.sessions.replaceChildren(table(["From", "Started", "Expires", "", ""], rows));
  }

  function renderTokens(res) {
    const list = tokenRows(res.tokens);
    if (!list.length) {
      areas.tokens.replaceChildren(el("p", "muted empty", "No API tokens."));
      return;
    }
    const rows = list.map((t) => {
      const tr = el("tr");
      const what = el("div");
      what.append(el("div", "", t.name), el("div", "muted", scopeText(t.scope) + (t.user ? " (owner " + t.user + ")" : "")));
      tr.append(
        cell(what),
        cell(el("span", "", t.created)),
        cell(el("span", "", t.expires), " ", badge(t.status === "expired" ? "warn" : "ok", t.status)),
        cell(el("span", "", t.lastUsed)),
        cell(button("Revoke", () => revoke(t))),
      );
      return tr;
    });
    areas.tokens.replaceChildren(table(["Token", "Made", "Expires", "Last used", ""], rows));
  }

  function renderLogins(res) {
    const list = loginRows(res.logins);
    if (!list.length) {
      areas.logins.replaceChildren(el("p", "muted empty", "No sign ins on record."));
      return;
    }
    const rows = list.map((l) => {
      const tr = el("tr");
      tr.append(cell(el("span", "", l.when)), cell(el("span", "", l.user)), cell(el("span", "", l.ip)), cell(badge(l.level, l.word)));
      return tr;
    });
    areas.logins.replaceChildren(table(["When", "User", "From", "Result"], rows));
  }

  const q = (flag, path) => path + (flag ? "?all=1" : "");

  async function loadAll() {
    if (busy) return;
    busy = true;
    try {
      const jobs = [
        api("/api/security/sessions").then(renderSessions),
        api(q(areas.tokenAll.checked, "/api/security/tokens")).then(renderTokens),
        api(areas.loginScope.value === "all" ? "/api/security/logins?all=1" : "/api/security/logins").then(renderLogins),
      ];
      if (can("audit.view")) jobs.push(api("/api/security/check").then(renderCheck));
      const results = await Promise.allSettled(jobs);
      if (!running) return;
      const bad = results.find((r) => r.status === "rejected");
      areas.error.textContent = "";
      if (bad) fail(bad.reason);
    } finally {
      busy = false;
    }
  }

  // Only the lists that can change by themselves, and not the check, which
  // runs a command on the machine.
  async function refreshLists() {
    if (busy) return;
    busy = true;
    try {
      await Promise.all([api("/api/security/sessions").then(renderSessions), api(q(areas.tokenAll.checked, "/api/security/tokens")).then(renderTokens)]);
      if (running) areas.error.textContent = "";
    } catch (err) {
      if (running) fail(err);
    } finally {
      busy = false;
    }
  }

  async function act(fn, done) {
    areas.error.textContent = "";
    try {
      await fn();
      if (!running) return;
      if (done) say(done);
    } catch (err) {
      if (running) fail(err);
      return;
    }
    if (running) await refreshLists();
  }

  const endSession = (s) => act(() => api("/api/security/sessions/" + encodeURIComponent(s.handle), { method: "DELETE" }), s.current ? "" : "Session ended.");
  const revoke = (t) => {
    if (!window.confirm('Revoke the token "' + t.name + '"? Scripts that use it stop working at once.')) return;
    act(() => api("/api/security/tokens/" + encodeURIComponent(t.id), { method: "DELETE" }), 'Token "' + t.name + '" revoked.');
  };

  async function endOthers() {
    await act(async () => {
      const res = await api("/api/security/sessions/revoke-others", { method: "POST" });
      say(res.ended + " other session" + (res.ended === 1 ? "" : "s") + " ended.");
    });
  }

  async function signOutAll() {
    if (!window.confirm(SIGN_OUT_ALL_QUESTION)) return;
    areas.error.textContent = "";
    try {
      await api("/api/security/sessions/revoke-all", { method: "POST" });
    } catch (err) {
      if (running) fail(err);
      return;
    }
    // Our own session is gone too: the next request signs the page out.
    if (running) await refreshLists();
  }

  async function createToken() {
    const built = tokenBody(areas.tokenName.value.trim(), areas.tokenScope.value, areas.tokenDays.value);
    if (built.error) {
      areas.error.textContent = built.error;
      return;
    }
    areas.error.textContent = "";
    areas.secretBox.hidden = true;
    areas.tokenCreate.disabled = true;
    try {
      const res = await api("/api/security/tokens", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(built.body) });
      if (!running) return;
      areas.secret.textContent = res.token;
      areas.secretNote.textContent = TOKEN_SHOWN_ONCE;
      areas.secretBox.hidden = false;
      areas.tokenName.value = "";
      say('Token "' + built.body.name + '" made.');
    } catch (err) {
      // A refused request changed nothing: keep its words, read nothing again.
      if (running) fail(err);
      return;
    } finally {
      if (running) areas.tokenCreate.disabled = false;
    }
    if (running) await refreshLists();
  }

  async function copySecret() {
    try {
      await navigator.clipboard.writeText(areas.secret.textContent);
      say("Copied.");
    } catch {
      say("Select the token and copy it by hand.");
    }
  }

  function hideSecret() {
    areas.secret.textContent = "";
    areas.secretBox.hidden = true;
  }

  const onAll = () => refreshLists();
  const onLoginScope = () => loadAll();
  areas.run.addEventListener("click", loadAll);
  areas.endOthers.addEventListener("click", endOthers);
  areas.signOutAll.addEventListener("click", signOutAll);
  areas.tokenCreate.addEventListener("click", createToken);
  areas.secretCopy.addEventListener("click", copySecret);
  areas.secretHide.addEventListener("click", hideSecret);
  areas.tokenAll.addEventListener("change", onAll);
  areas.loginScope.addEventListener("change", onLoginScope);

  areas.tokenScope.replaceChildren(
    ...SCOPES.map((s) => {
      const o = el("option", "", s);
      o.value = s;
      return o;
    }),
  );
  areas.secretBox.hidden = true;
  loadAll();
  timer = setInterval(refreshLists, POLL_MS);
  return () => {
    running = false;
    hideSecret();
    if (timer !== null) clearInterval(timer);
    areas.run.removeEventListener("click", loadAll);
    areas.endOthers.removeEventListener("click", endOthers);
    areas.signOutAll.removeEventListener("click", signOutAll);
    areas.tokenCreate.removeEventListener("click", createToken);
    areas.secretCopy.removeEventListener("click", copySecret);
    areas.secretHide.removeEventListener("click", hideSecret);
    areas.tokenAll.removeEventListener("change", onAll);
    areas.loginScope.removeEventListener("change", onLoginScope);
  };
}
