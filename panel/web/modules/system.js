// The host part of the Overview (slice 38): what /api/system says, as the
// numbers a person reads. The functions are pure so node --test can run them.

export function humanBytes(n) {
  const v = Number(n);
  if (!Number.isFinite(v) || v < 0) return "";
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let x = v;
  let i = 0;
  while (x >= 1024 && i < units.length - 1) {
    x /= 1024;
    i++;
  }
  return (i === 0 ? String(Math.round(x)) : x.toFixed(1)) + " " + units[i];
}

// uptimeText turns seconds into "3 d 4 h" / "2 h 5 min" / "40 s".
export function uptimeText(seconds) {
  const s = Math.floor(Number(seconds));
  if (!Number.isFinite(s) || s < 0) return "";
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (d > 0) return d + " d " + h + " h";
  if (h > 0) return h + " h " + m + " min";
  if (m > 0) return m + " min";
  return s + " s";
}

// usedPercent is the used share of a total, rounded, or null without data.
export function usedPercent(total, free) {
  if (!(total > 0) || free < 0 || free > total) return null;
  return Math.round(((total - free) / total) * 100);
}

// level says how worried to be about a percentage: it picks the badge.
export function level(percent) {
  if (percent === null) return "na";
  if (percent >= 90) return "crit";
  if (percent >= 75) return "warn";
  return "ok";
}

// statCards turns the answer into the cards of the Overview. A card for
// data the host did not give is left out, not shown as zero.
export function statCards(info) {
  const cards = [];
  if (info.cpu && info.cpu.percent !== null && info.cpu.percent !== undefined) {
    const p = Math.round(info.cpu.percent);
    cards.push({ label: "CPU", value: p + " %", note: info.cpu.cores + " cores", level: level(p) });
  } else if (info.cpu && info.cpu.cores) {
    cards.push({ label: "CPU", value: "measuring", note: info.cpu.cores + " cores", level: "na" });
  }
  if (info.load && info.load.length === 3) {
    cards.push({ label: "Load", value: info.load[0].toFixed(2), note: info.load[1].toFixed(2) + " / " + info.load[2].toFixed(2) + " (5 / 15 min)", level: "na" });
  }
  const m = info.memory;
  if (m && m.total_kb > 0) {
    const p = usedPercent(m.total_kb, m.available_kb);
    cards.push({ label: "Memory", value: p + " %", note: humanBytes((m.total_kb - m.available_kb) * 1024) + " of " + humanBytes(m.total_kb * 1024), level: level(p) });
  }
  for (const d of info.disks || []) {
    const p = usedPercent(d.total_bytes, d.free_bytes);
    if (p === null) continue;
    cards.push({ label: "Disk " + d.path, value: p + " %", note: humanBytes(d.free_bytes) + " free of " + humanBytes(d.total_bytes), level: level(p) });
  }
  if (info.uptime_seconds > 0) cards.push({ label: "Uptime", value: uptimeText(info.uptime_seconds), note: "", level: "na" });
  return cards;
}

// ifaceRows: the table of interfaces. Drops and errors are the sums of both
// directions, because a person looks for "is anything lost", not for the side.
export function ifaceRows(info) {
  return (info.interfaces || []).map((i) => ({
    name: i.name,
    state: i.state || "",
    speed: i.speed_mbps ? i.speed_mbps + " Mbit/s" : "",
    rx: humanBytes(i.rx_bytes),
    tx: humanBytes(i.tx_bytes),
    lost: (i.rx_dropped || 0) + (i.tx_dropped || 0),
    errors: (i.rx_errors || 0) + (i.tx_errors || 0),
    capture: i.capture === undefined ? "" : i.capture ? "capturing" : "",
    virtual: !!i.virtual,
  }));
}
