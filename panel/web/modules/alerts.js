// The Alerts screen: the changes of check status that the watchdog wrote to
// events.jsonl, newest first, with a filter by check.
import { tickets } from "./poll.js";

const POLL_MS = 10000;
const WORD = { ok: "ok", warn: "warning", crit: "critical", na: "no data" };

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function option(value, text) {
  const o = document.createElement("option");
  o.value = value;
  o.textContent = text;
  return o;
}

function when(iso) {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? iso : d.toLocaleString("ru-RU");
}

export const word = (s) => WORD[s] || s;

export function start(api, els, onError) {
  let timer = null;
  const seq = tickets();
  let running = true;

  function fillChecks(checks) {
    const chosen = els.check.value;
    els.check.replaceChildren(option("", "All checks"), ...checks.map((c) => option(c, c)));
    els.check.value = checks.includes(chosen) ? chosen : "";
  }

  function table(alerts) {
    const t = el("table");
    const head = el("tr");
    for (const h of ["Time", "Check", "Was", "Now", "Details"]) head.append(el("th", "", h));
    t.append(head);
    for (const a of alerts) {
      const tr = el("tr");
      tr.append(
        el("td", "", when(a.ts)),
        el("td", "", a.check),
        el("td", "", word(a.from)),
        el("td", `status-${a.to}`, word(a.to)),
        el("td", "", a.detail || ""),
      );
      t.append(tr);
    }
    return t;
  }

  async function load() {
    timer = null;
    const ticket = seq.next();
    if (!running || document.hidden) return;
    const query = new URLSearchParams({ limit: els.limit.value });
    if (els.check.value) query.set("check", els.check.value);
    try {
      const res = await api(`/api/alerts?${query}`);
      if (!running || !seq.current(ticket)) return;
      els.error.textContent = "";
      fillChecks(res.checks);
      if (!res.file_present) {
        els.list.replaceChildren(el("p", "muted empty", "No alert history yet: no check has changed its status."));
      } else if (res.alerts.length === 0) {
        els.list.replaceChildren(el("p", "muted empty", "No alerts for this check."));
      } else {
        els.list.replaceChildren(table(res.alerts));
      }
    } catch (err) {
      if (!running || !seq.current(ticket)) return;
      if (err.status === 401) return onError(err);
      els.error.textContent = err.message;
    }
    if (running && seq.current(ticket)) timer = setTimeout(load, POLL_MS);
  }

  function reload() {
    clearTimeout(timer);
    load();
  }

  function onVisible() {
    if (!document.hidden && running && timer === null) load();
  }

  els.check.onchange = reload;
  els.limit.onchange = reload;
  els.refresh.onclick = reload;
  document.addEventListener("visibilitychange", onVisible);
  load();
  return () => {
    running = false;
    clearTimeout(timer);
    document.removeEventListener("visibilitychange", onVisible);
  };
}
