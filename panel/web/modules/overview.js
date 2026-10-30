// The Overview screen: overall health, components and watchdog checks.
import { tickets } from "./poll.js";

const POLL_MS = 10000;

const OVERALL = { ok: "All good", warn: "There are warnings", crit: "There are faults", na: "No data" };
const STATE = { active: "running", inactive: "stopped", failed: "failed", absent: "not installed" };

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function badge(status) {
  return el("span", "badge " + (status || "na"), status || "na");
}

function table(headers, rows) {
  const t = el("table");
  const head = el("tr");
  for (const h of headers) head.append(el("th", "", h));
  t.append(head);
  for (const cells of rows) {
    const tr = el("tr");
    for (const c of cells) {
      const td = el("td");
      if (c instanceof Node) td.append(c);
      else td.textContent = c;
      tr.append(td);
    }
    t.append(tr);
  }
  return t;
}

function fmtTime(ts) {
  const d = new Date(ts);
  return Number.isNaN(d.getTime()) ? ts || "" : d.toLocaleString();
}

// render fills the three overview areas from one /api/status answer.
export function render(status, areas) {
  const health = status.health;
  const overall = health ? health.overall : "na";
  areas.overall.replaceChildren(
    badge(overall),
    el("span", "overall-text", OVERALL[overall] || overall),
    el("span", "muted", health ? "checked " + fmtTime(health.ts) : "the watchdog has not written a report yet"),
  );

  const rows = status.components.map((c) => [
    c.id,
    c.runtime,
    STATE[c.state] || c.state,
    c.enabled ? "yes" : "no",
    c.version || "",
  ]);
  const comps = [table(["Component", "Start", "State", "Autostart", "Version"], rows)];
  if (status.ndpi_plugin) comps.push(el("p", "muted", "nDPI plugin: " + status.ndpi_plugin));
  areas.components.replaceChildren(...comps);

  const checks = health ? health.checks : [];
  areas.checks.replaceChildren(
    checks.length
      ? table(
          ["Check", "Status", "Details", "Since"],
          checks.map((c) => [c.id, badge(c.status), c.detail || c.value || "", fmtTime(c.since)]),
        )
      : el("p", "muted empty", "No checks yet."),
  );
}

// start polls while the tab is visible and the screen is shown, and stops
// otherwise, so a closed or hidden panel costs no work. It returns stop().
export function start(api, areas, onError) {
  let timer = null;
  let running = true;
  const seq = tickets();

  async function tick() {
    timer = null;
    const ticket = seq.next();
    if (!running || document.hidden) return;
    try {
      const status = await api("/api/status");
      if (!running || !seq.current(ticket)) return;
      render(status, areas);
      areas.error.textContent = "";
    } catch (err) {
      if (!running || !seq.current(ticket)) return;
      if (err.status === 401) return onError(err);
      areas.error.textContent = err.message;
    }
    if (running && seq.current(ticket)) timer = setTimeout(tick, POLL_MS);
  }

  function onVisible() {
    if (!document.hidden && running && timer === null) tick();
  }

  document.addEventListener("visibilitychange", onVisible);
  tick();
  return () => {
    running = false;
    clearTimeout(timer);
    document.removeEventListener("visibilitychange", onVisible);
  };
}
