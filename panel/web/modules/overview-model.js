// What the Overview says at a glance (slice 38): four state cards, the
// warnings, alerts by severity and the latest alerts. Pure functions over the
// answers of /api/status, /api/system, /api/mode and /api/eve, so node --test
// can check them. A piece whose source did not answer is left out, never
// shown as zero.
import { summarize } from "./events.js";

const DAY_MS = 24 * 3600 * 1000;

// alertsOf takes the events of /api/eve?type=alert and returns the alerts
// with their severity as a number (1 high, 2 medium, 3 low, 0 unknown).
export function alertsOf(res) {
  if (!res || res.available === false || !Array.isArray(res.events)) return null;
  return res.events.map((e) => {
    const sev = Number(e.event && e.event.alert && e.event.alert.severity);
    return { id: e.id, time: e.time || "", severity: sev >= 1 && sev <= 3 ? sev : 0, text: summarize("alert", e.event || {}) };
  });
}

// since keeps the alerts newer than ms before now; an alert without a time
// cannot be placed and is left out.
export function since(alerts, ms, now) {
  return alerts.filter((a) => {
    const t = Date.parse(a.time);
    return !Number.isNaN(t) && now - t <= ms;
  });
}

export function severityCounts(alerts) {
  const c = { high: 0, medium: 0, low: 0, unknown: 0 };
  for (const a of alerts) {
    if (a.severity === 1) c.high++;
    else if (a.severity === 2) c.medium++;
    else if (a.severity === 3) c.low++;
    else c.unknown++;
  }
  return c;
}

// installed: a component the host has; "absent" is not installed.
function installed(status) {
  return (status.components || []).filter((c) => c.state !== "absent");
}

// captureLoss adds the drops of the interfaces that capture. null when
// the host did not say which interface captures.
export function captureLoss(system) {
  const ifaces = (system && system.interfaces) || [];
  const capturing = ifaces.filter((i) => i.capture === true);
  if (!ifaces.some((i) => i.capture !== undefined)) return null;
  return { interfaces: capturing.length, dropped: capturing.reduce((n, i) => n + (i.rx_dropped || 0) + (i.tx_dropped || 0), 0) };
}

export function stateCards({ status, system, mode, alerts, now }) {
  const cards = [];
  if (mode && (mode.mode === "ids" || mode.mode === "ips")) {
    const ips = mode.mode === "ips";
    cards.push({ label: "Protection", value: ips ? "IPS" : "IDS", note: ips ? (mode.pending ? "waiting for confirmation" : "blocking") : "watching only", level: ips && mode.pending ? "warn" : "na" });
  }
  if (status && Array.isArray(status.components)) {
    const have = installed(status);
    const running = have.filter((c) => c.state === "active").length;
    const failed = have.some((c) => c.state === "failed");
    const stopped = have.some((c) => c.state === "inactive" && c.enabled);
    cards.push({ label: "Components", value: running + " of " + have.length, note: "running", level: failed ? "crit" : stopped ? "warn" : "ok" });
  }
  if (alerts) {
    const day = since(alerts, DAY_MS, now);
    const c = severityCounts(day);
    cards.push({ label: "Alerts, 24 h", value: String(day.length), note: c.high ? c.high + " high severity" : "none of high severity", level: c.high ? "warn" : "na" });
  }
  const loss = captureLoss(system);
  if (loss) {
    cards.push(
      loss.interfaces
        ? { label: "Packets lost", value: String(loss.dropped), note: "on " + loss.interfaces + " capture interface" + (loss.interfaces > 1 ? "s" : ""), level: loss.dropped ? "warn" : "ok" }
        : { label: "Capture", value: "none", note: "no interface is captured", level: "warn" },
    );
  }
  return cards;
}

// The watchdog checks that the Overview repeats as a warning. The component
// and disk checks are left out: the screen says those from its own data.
const WATCH_CHECKS = ["rules.age", "suricata.eve_fresh"];

// watchWarnings turns a warn or crit check of the watchdog into a sentence
// from its own detail line.
function watchWarnings(health) {
  const out = [];
  for (const c of (health && health.checks) || []) {
    if (!WATCH_CHECKS.includes(c.id) || (c.status !== "warn" && c.status !== "crit") || !c.detail) continue;
    out.push(c.detail.charAt(0).toUpperCase() + c.detail.slice(1) + ".");
  }
  return out;
}

// warnings: sentences for what needs a look. Each one is a fact the screen
// has; the order is the order of importance.
export function warnings({ status, system, health }) {
  const out = [];
  for (const c of installed(status || {})) {
    if (c.state === "failed") out.push(c.id + " has failed.");
    else if (c.state === "inactive" && c.enabled) out.push(c.id + " is stopped but set to start on boot.");
  }
  const loss = captureLoss(system);
  const suricata = ((status && status.components) || []).find((c) => c.id === "suricata");
  if (loss && !loss.interfaces && suricata && suricata.state === "active") out.push("Suricata is running but no interface is set to be captured.");
  if (loss && loss.dropped > 0) out.push(loss.dropped + " packets were dropped on the capture interfaces since boot.");
  for (const d of (system && system.disks) || []) {
    if (d.total_bytes > 0 && (d.total_bytes - d.free_bytes) / d.total_bytes >= 0.9) out.push("The disk " + d.path + " is more than 90 % full.");
  }
  out.push(...watchWarnings(health));
  return out;
}
