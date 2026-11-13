// The Overview screen: overall health, the state cards, host gauges, traffic
// charts, alerts, components and watchdog checks.
import { tickets } from "./poll.js";
import { statCards, ifaceRows } from "./system.js";
import { SERIES, seriesCard } from "./metrics.js";
import { donut, radar, ringGauge } from "./charts.js";
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

function fmtTime(ts) {
  const d = new Date(ts);
  return Number.isNaN(d.getTime()) ? ts || "" : d.toLocaleString();
}

// A row of a list: a coloured dot, a main line, a small line, a badge.
function row(tone, title, note, trailing) {
  const li = el("li", "row " + tone);
  li.append(el("i", "dot tone-" + tone));
  const body = el("span", "row-body");
  body.append(el("strong", "", title));
  if (note) body.append(el("span", "muted", note));
  li.append(body);
  if (trailing) li.append(trailing);
  return li;
}

const COMPONENT_TONE = { active: "ok", inactive: "warn", failed: "crit", absent: "na" };

// render fills the three overview areas from one /api/status answer.
export function render(status, areas) {
  const health = status.health;
  const overall = health ? health.overall : "na";
  areas.overall.className = "hero " + overall;
  areas.overall.replaceChildren(
    el("i", "pulse tone-" + overall),
    (() => {
      const box = el("div", "hero-text");
      box.append(el("strong", "overall-text", OVERALL[overall] || overall), el("span", "muted", health ? "Checked " + fmtTime(health.ts) : "The watchdog has not written a report yet"));
      return box;
    })(),
    badge(overall),
  );

  const grid = el("ul", "inventory");
  for (const c of status.components) {
    const tone = COMPONENT_TONE[c.state] || "na";
    const meta = [c.runtime, c.version, c.state !== "absent" && c.enabled ? "starts on boot" : ""].filter(Boolean).join(" · ");
    grid.append(row(tone, c.id, meta, el("span", "badge " + tone, STATE[c.state] || c.state)));
  }
  const comps = [grid];
  if (status.ndpi_plugin) comps.push(el("p", "muted", "nDPI plugin: " + status.ndpi_plugin));
  areas.components.replaceChildren(...comps);

  const live = status.components.filter((c) => c.state !== "absent");
  if (areas.mix) {
    const count = (state) => live.filter((c) => c.state === state).length;
    areas.mix.replaceChildren(
      live.length
        ? donut({
            caption: "Components by state",
            center: count("active") + "/" + live.length,
            parts: [
              { label: "Running", value: count("active"), tone: "ok" },
              { label: "Stopped", value: count("inactive"), tone: "warn" },
              { label: "Failed", value: count("failed"), tone: "crit" },
            ],
          })
        : el("p", "muted empty", "Nothing is installed yet."),
    );
  }

  const checks = health ? health.checks : [];
  const list = el("ul", "inventory checks-list");
  for (const c of checks) list.append(row(c.status || "na", c.id, (c.detail || c.value || "") + (c.since ? " · since " + fmtTime(c.since) : ""), badge(c.status)));
  areas.checks.replaceChildren(checks.length ? list : el("p", "muted empty", "No checks yet."));
}

// renderSystem fills the host gauges and the interface chips. A host that
// gave nothing leaves the section empty and hidden.
export function renderSystem(info, areas) {
  const cards = statCards(info);
  const gauges = [];
  const facts = [];
  for (const c of cards) {
    const percent = /^\d+ %$/.test(c.value) ? parseInt(c.value, 10) : null;
    const gauge = percent !== null && (c.label === "CPU" || c.label === "Memory" || c.label.startsWith("Disk "));
    if (gauge) {
      const box = el("div", "gauge card");
      const disk = c.label.startsWith("Disk ");
      box.append(ringGauge({ value: percent, label: disk ? "Disk" : c.label, text: c.value, tone: c.level === "na" ? "ok" : c.level }));
      const note = [disk ? c.label.slice(5) : "", c.note].filter(Boolean).join(" · ");
      if (note) box.append(el("span", "muted", note));
      gauges.push(box);
    } else {
      const box = el("div", "card stat");
      box.append(el("span", "muted", c.label), el("strong", "stat-value", c.value));
      if (c.note) box.append(el("span", "muted", c.note));
      facts.push(box);
    }
  }
  areas.host.replaceChildren(...gauges, ...facts);
  const rows = ifaceRows(info);
  const chips = el("ul", "iface-chips");
  for (const r of rows) {
    const up = r.state === "up";
    const li = el("li", "iface" + (r.capture ? " capturing" : ""));
    li.append(el("i", "dot tone-" + (up ? "ok" : "na")), el("strong", "", r.name));
    li.append(el("span", "muted", [r.state, r.speed].filter(Boolean).join(" · ")));
    li.append(el("span", "iface-flow", "↓ " + r.rx + "  ↑ " + r.tx));
    if (r.lost || r.errors) li.append(el("span", "badge warn", r.lost + " dropped, " + r.errors + " errors"));
    if (r.capture) li.append(el("span", "badge ok", r.capture));
    chips.append(li);
  }
  areas.ifaces.replaceChildren(rows.length ? chips : el("p", "muted empty", "No interfaces."));
  areas.hostBox.hidden = !cards.length && !rows.length;
}

// renderTraffic draws the packet rate and the drop rate of the last hour,
// the same cards as the Metrics screen. Without metrics the block hides.
export function renderTraffic(res, areas) {
  const defs = SERIES.filter((d) => d.name === "pps" || d.name === "drops");
  const ok = res && res.series && defs.every((d) => res.series[d.name]);
  areas.trafficBox.hidden = !ok;
  if (ok) areas.traffic.replaceChildren(...defs.map((d) => seriesCard(d, res.series[d.name], res)));
}

const SEVERITY_TONE = { 1: "crit", 2: "warn", 3: "a", 0: "na" };

// renderGlance fills the cards, the warnings, the alerts by severity and
// the latest alerts. A source that did not answer is null and its part is
// left out; the whole block hides when nothing is left.
export function renderGlance({ status, system, mode, eve }, areas, now = Date.now()) {
  const alerts = alertsOf(eve);
  const cards = stateCards({ status, system, mode, alerts, now });
  areas.cards.replaceChildren(
    ...cards.map((c) => {
      const card = el("div", "card kpi " + c.level);
      card.append(el("span", "muted kpi-label", c.label), el("strong", "kpi-value", c.value));
      const foot = el("span", "kpi-foot");
      if (c.level !== "na") foot.append(badge(c.level));
      if (c.note) foot.append(el("span", "muted", c.note));
      card.append(foot);
      return card;
    }),
  );
  const warn = status ? warnings({ status, system, health: status.health }) : [];
  areas.warnings.replaceChildren(...warn.map((w) => el("p", "warning", w)));
  areas.warnings.hidden = !warn.length;

  const day = alerts ? since(alerts, DAY_MS, now) : [];
  if (alerts) {
    const c = severityCounts(day);
    const top = Math.max(c.high, c.medium, c.low, c.unknown, 1);
    const capped = alerts.length >= ALERT_LIMIT ? " (of the latest " + ALERT_LIMIT + " alerts)" : "";
    areas.severity.replaceChildren(
      el("p", "muted", "Alerts in the last 24 hours" + capped),
      radar({
        caption: "Alerts by severity",
        axes: [
          { label: "High", value: c.high / top, text: String(c.high) },
          { label: "Medium", value: c.medium / top, text: String(c.medium) },
          { label: "Low", value: c.low / top, text: String(c.low) },
          { label: "Unknown", value: c.unknown / top, text: String(c.unknown) },
        ],
      }),
    );
    const latest = alerts.slice(0, 6);
    const list = el("ul", "inventory");
    for (const a of latest) list.append(row(SEVERITY_TONE[a.severity], a.text, a.time ? fmtTime(a.time) : ""));
    areas.recent.replaceChildren(latest.length ? list : el("p", "muted empty", "No alerts yet."));
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
      const extra = await Promise.allSettled([api("/api/system"), api("/api/mode"), api("/api/eve?type=alert&limit=" + ALERT_LIMIT), api("/api/metrics?range=1h")]);
      if (!running || !seq.current(ticket)) return;
      const unauth = extra.find((r) => r.status === "rejected" && r.reason && r.reason.status === 401);
      if (unauth) return onError(unauth.reason);
      const [system, mode, eve, traffic] = extra.map((r) => (r.status === "fulfilled" ? r.value : null));
      if (system) renderSystem(system, areas);
      else areas.hostBox.hidden = true;
      renderGlance({ status, system, mode, eve }, areas);
      renderTraffic(traffic, areas);
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
