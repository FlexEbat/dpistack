// The Alert Center (slice 43): the alerts of the watchdog and of Suricata with
// the state a person gave them, and what people decided. Everything is read
// from /api/alert-center; a decision is one POST, after which the list is read
// again. Without the permission events.ack there are no buttons. Only a 401
// signs the user out.

import { stateWord, severityWord, severityLevel, stateLevel, actionsFor, query, summaryLine, stateDetail, sourceWord, seenText, decisions, actionWord, bodyFor, SNOOZE_CHOICES } from "./alertcenter-model.js";

const POLL_MS = 10000;

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function badge(level, text) {
  return el("span", "badge " + (level || "na"), text);
}

function cell(...nodes) {
  const td = el("td");
  td.append(...nodes);
  return td;
}

export function start(api, areas, onError, canAck) {
  let running = true;
  let timer = null;
  let busy = false;
  let acting = false;

  function fail(err) {
    if (err.status === 401) return onError(err);
    areas.error.textContent = err.message;
  }

  function filters() {
    return { state: areas.state.value, source: areas.source.value, severity: areas.severity.value };
  }

  function row(alert) {
    const tr = el("tr");
    const state = el("div");
    state.append(badge(stateLevel(alert.state), stateWord(alert.state)));
    const detail = stateDetail(alert);
    if (detail) state.append(el("div", "muted", detail));
    const what = el("div");
    what.append(el("div", "", alert.title), el("div", "muted", `${sourceWord(alert)} ${alert.key}${alert.detail ? ": " + alert.detail : ""}`));
    tr.append(cell(badge(severityLevel(alert.severity), severityWord(alert.severity))), cell(what), cell(el("span", "", seenText(alert))), cell(state));
    const td = el("td");
    if (canAck) {
      for (const a of actionsFor(alert)) {
        if (a.action === "snooze") {
          const sel = el("select");
          sel.setAttribute("aria-label", "Snooze for");
          for (const d of SNOOZE_CHOICES) {
            const o = el("option", "", d);
            o.value = d;
            sel.append(o);
          }
          const b = el("button", "small", a.label);
          b.type = "button";
          b.addEventListener("click", () => act("snooze", alert.key, sel.value));
          td.append(sel, b);
        } else {
          const b = el("button", "small", a.label);
          b.type = "button";
          b.addEventListener("click", () => act(a.action, alert.key, ""));
          td.append(b);
        }
      }
    }
    tr.append(td);
    return tr;
  }

  function render(res) {
    areas.summary.textContent = summaryLine(res.counts);
    const alerts = res.alerts || [];
    if (!alerts.length) {
      areas.list.replaceChildren(el("p", "muted empty", "No alerts match."));
      return;
    }
    const t = el("table");
    const head = el("tr");
    for (const h of ["Level", "Alert", "Seen", "State", canAck ? "Do" : ""]) head.append(el("th", "", h));
    t.append(head);
    for (const a of alerts) t.append(row(a));
    areas.list.replaceChildren(t);
  }

  function renderHistory(res) {
    const rows = decisions(res);
    if (!rows.length) {
      areas.history.replaceChildren(el("p", "muted empty", "Nobody has changed an alert yet."));
      return;
    }
    const t = el("table");
    const head = el("tr");
    for (const h of ["Time", "Who", "Did", "Alert"]) head.append(el("th", "", h));
    t.append(head);
    for (const r of rows) {
      const tr = el("tr");
      tr.append(el("td", "", new Date(r.ts).toLocaleString("en-GB")), el("td", "", r.by || ""), el("td", "", actionWord(r.action) + (r.note ? ": " + r.note : "")), el("td", "", `${r.key} ${r.title || ""}`));
      t.append(tr);
    }
    areas.history.replaceChildren(t);
  }

  async function once() {
    if (busy) return;
    busy = true;
    try {
      const [list, hist] = await Promise.all([api("/api/alert-center" + query(filters())), api("/api/alert-center/history")]);
      if (!running) return;
      areas.error.textContent = "";
      render(list);
      renderHistory(hist);
    } catch (err) {
      if (running) fail(err);
    } finally {
      busy = false;
    }
  }

  async function act(action, key, dur) {
    if (acting) return;
    const built = bodyFor(action, key, dur, areas.note.value.trim());
    if (built.error) {
      areas.error.textContent = built.error;
      return;
    }
    acting = true;
    let refused = "";
    try {
      await api("/api/alert-center", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(built.body) });
      if (!running) return;
      areas.note.value = "";
      areas.error.textContent = "";
    } catch (err) {
      if (running) {
        fail(err);
        refused = areas.error.textContent;
      }
    } finally {
      acting = false;
    }
    if (running) await once();
    // Reading the list again must not wipe the words of a refused change.
    if (running && refused) areas.error.textContent = refused;
  }

  const onChange = () => once();
  for (const k of ["state", "source", "severity"]) areas[k].addEventListener("change", onChange);
  areas.refresh.addEventListener("click", onChange);
  once();
  timer = setInterval(once, POLL_MS);
  return () => {
    running = false;
    if (timer !== null) clearInterval(timer);
    for (const k of ["state", "source", "severity"]) areas[k].removeEventListener("change", onChange);
    areas.refresh.removeEventListener("click", onChange);
  };
}
