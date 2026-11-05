// The Overview screen: overall health, components and watchdog checks.
import { tickets } from "./poll.js";
import { statCards, ifaceRows } from "./system.js";
import { alertsOf, since, severityCounts, stateCards, warnings } from "./overview-model.js";

const ALERT_LIMIT = 200;
const DAY_MS = 24 * 3600 * 1000;

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

// renderSystem fills the host cards and the interface table. A host that
// gave nothing leaves the section empty and hidden.
export function renderSystem(info, areas) {
  const cards = statCards(info);
  areas.host.replaceChildren(
    ...cards.map((c) => {
      const card = el("div", "card stat");
      card.append(el("span", "muted", c.label), el("strong", "stat-value", c.value));
      if (c.level !== "na") card.append(badge(c.level));
      if (c.note) card.append(el("span", "muted", c.note));
      return card;
    }),
  );
  const rows = ifaceRows(info);
  areas.ifaces.replaceChildren(
    rows.length
      ? table(
          ["Interface", "State", "Speed", "Received", "Sent", "Dropped", "Errors", ""],
          rows.map((r) => [r.name, r.state, r.speed, r.rx, r.tx, String(r.lost), String(r.errors), r.capture]),
        )
      : el("p", "muted empty", "No interfaces."),
  );
  areas.hostBox.hidden = !cards.length && !rows.length;
}

// renderGlance fills the cards, the warnings, the alerts by severity and
// the latest alerts. A source that did not answer is null and its part is
// left out; the whole block hides when nothing is left.
export function renderGlance({ status, system, mode, eve }, areas, now = Date.now()) {
  const alerts = alertsOf(eve);
  const cards = stateCards({ status, system, mode, alerts, now });
  areas.cards.replaceChildren(
    ...cards.map((c) => {
      const card = el("div", "card stat");
      card.append(el("span", "muted", c.label), el("strong", "stat-value", c.value));
      if (c.level !== "na") card.append(badge(c.level));
      if (c.note) card.append(el("span", "muted", c.note));
      return card;
    }),
  );
  const warn = status ? warnings({ status, system }) : [];
  areas.warnings.replaceChildren(...warn.map((w) => el("p", "warning", w)));
  areas.warnings.hidden = !warn.length;

  const day = alerts ? since(alerts, DAY_MS, now) : [];
  if (alerts) {
    const c = severityCounts(day);
    const capped = alerts.length >= ALERT_LIMIT ? " (of the latest " + ALERT_LIMIT + " alerts)" : "";
    areas.severity.replaceChildren(
      el("p", "muted", "Alerts in the last 24 hours" + capped),
      table(["High", "Medium", "Low", "Unknown"], [[String(c.high), String(c.medium), String(c.low), String(c.unknown)]]),
    );
    const latest = alerts.slice(0, 5);
    areas.recent.replaceChildren(
      latest.length
        ? table(["Time", "Alert"], latest.map((a) => [a.time ? fmtTime(a.time) : "", a.text]))
        : el("p", "muted empty", "No alerts yet."),
    );
  }
  areas.alertsBox.hidden = !alerts;
  areas.glanceBox.hidden = !cards.length && !warn.length && !alerts;
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
      // The other parts are extra: when one fails the rest of the screen
      // stays, and only a 401 signs the user out.
      const extra = await Promise.allSettled([api("/api/system"), api("/api/mode"), api("/api/eve?type=alert&limit=" + ALERT_LIMIT)]);
      if (!running || !seq.current(ticket)) return;
      const unauth = extra.find((r) => r.status === "rejected" && r.reason && r.reason.status === 401);
      if (unauth) return onError(unauth.reason);
      const [system, mode, eve] = extra.map((r) => (r.status === "fulfilled" ? r.value : null));
      if (system) renderSystem(system, areas);
      else areas.hostBox.hidden = true;
      renderGlance({ status, system, mode, eve }, areas);
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
