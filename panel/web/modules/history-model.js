// The History screen: the roll-up of a day or of a week and the devices seen,
// from /api/history/report and /api/history/devices (dpistack report, devices).

const DAY = /^[0-9]{4}-[0-9]{2}-[0-9]{2}$/;

export function dateProblem(text) {
  const t = String(text || "").trim();
  if (t === "") return "";
  if (!DAY.test(t) || Number.isNaN(Date.parse(t + "T00:00:00Z"))) return "Use a day like 2026-11-20, or leave it empty for today.";
  return "";
}

export function formatBytes(n) {
  const v = Number(n) || 0;
  if (v < 1024) return `${v} B`;
  if (v < 1048576) return `${(v / 1024).toFixed(1)} KiB`;
  if (v < 1073741824) return `${(v / 1048576).toFixed(1)} MiB`;
  return `${(v / 1073741824).toFixed(1)} GiB`;
}

export function reportSummary(res) {
  if (!res) return "";
  const days = res.days || [];
  if (days.length === 0) {
    return res.enabled === false
      ? "History is off. Turn on HISTORY_ENABLE in Settings (Watchdog), then wait for traffic: the watchdog starts a summary from the moment it is on."
      : `No history for ${res.from} to ${res.to} yet. History is on; the watchdog adds a day as soon as Suricata sees traffic.`;
  }
  return `${res.label === "weekly" ? "Week" : "Day"} ${res.from} to ${res.to}: ${res.flows} flow${res.flows === 1 ? "" : "s"}, ${formatBytes(res.bytes)}, ${days.length} day${days.length === 1 ? "" : "s"} with data.`;
}

export function appRows(res) {
  return ((res && res.apps) || []).map((a) => [a.app, String(a.flows), formatBytes(a.bytes)]);
}

export function deviceRows(res) {
  return ((res && res.devices) || []).map((d) => [d.ip, String(d.flows), formatBytes(d.bytes), d.top_app || ""]);
}

export function alertRows(res) {
  return ((res && res.alerts) || []).map((a) => [String(a.sid), String(a.count), String(a.severity), a.msg || ""]);
}

export function newDeviceText(res) {
  const n = (res && res.new_devices) || [];
  return n.length ? `New devices in this period: ${n.join(", ")}` : "No new device in this period.";
}

// historyOff says whether the History screen has to tell the owner that the
// setting is off (the report names it).
export function historyOff(res) {
  return !!res && res.enabled === false;
}

// knownRows is the list of every device ever seen, newest first.
export function knownRows(list) {
  return (Array.isArray(list) ? list : []).map((d) => [d.ip, d.first, d.last]);
}
