// The Metrics screen: six area charts of the last 1, 6 or 24 hours.
// Charts are plain SVG (charts.js); a series that cannot exist is shown as a note with
// the reason, never as a flat line at zero, and a gap in the data is a gap
// in the line.
import { tickets } from "./poll.js";
import { areaChart } from "./charts.js";

const POLL_MS = 30000; // the server samples every 30 s, so asking more often shows nothing new

// What the screen shows per series, in order. Conversions keep the numbers
// readable: bytes become megabytes, the free share becomes percent.
export const SERIES = [
  { name: "pps", tone: "a", title: "Packets per second", format: (v) => `${Math.round(v).toLocaleString("en-US")} pkt/s` },
  { name: "drops", tone: "c", title: "Packet drops per second", format: (v) => `${v.toLocaleString("en-US", { maximumFractionDigits: 2 })} pkt/s` },
  { name: "cpu", tone: "b", title: "Panel CPU", format: (v) => `${v.toLocaleString("en-US", { maximumFractionDigits: 1 })} %` },
  { name: "rss", tone: "d", title: "Panel memory", format: bytes },
  { name: "eve_size", tone: "a", title: "eve.json size", format: bytes },
  { name: "disk", tone: "b", title: "Free space on the log disk", scale: 100, format: (v) => `${v.toLocaleString("en-US", { maximumFractionDigits: 1 })} %` },
];

function bytes(v) {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return `${v.toLocaleString("en-US", { maximumFractionDigits: v < 10 && i > 0 ? 1 : 0 })} ${units[i]}`;
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

// clock labels one point of a series: the grid starts at meta.start and
// every value covers meta.step seconds.
export function labelsOf(count, meta) {
  if (!meta || !meta.start || !meta.step) return [];
  const t0 = Date.parse(meta.start);
  if (Number.isNaN(t0)) return [];
  return Array.from({ length: count }, (_, i) => {
    const d = new Date(t0 + i * meta.step * 1000);
    return d.toLocaleTimeString("en-GB", { hour12: false });
  });
}

// seriesCard is one chart card; the Overview draws some of them. meta is
// the {start, step} of the answer, so the chart can name the time.
export function seriesCard(def, series, meta) {
  const c = el("div", "chart-card card");
  const head = el("div", "chart-head");
  head.append(el("h3", "", def.title));
  c.append(head);
  if (!series || !series.available) {
    // Unavailable is said in words: a zero line would claim the opposite.
    c.append(el("p", "muted empty", `No data: ${(series && series.reason) || "series unavailable"}.`));
    return c;
  }
  const scale = def.scale || 1;
  const values = series.values.map((v) => (v === null ? null : v * scale));
  const known = values.filter((v) => v !== null && v !== undefined);
  const last = [...values].reverse().find((v) => v !== null && v !== undefined);
  head.append(el("strong", "chart-last", last === undefined ? "no values" : def.format(last)));
  if (!known.length) {
    c.append(el("p", "muted empty", "No values in this period."));
    return c;
  }
  c.append(areaChart({ series: [{ name: def.title, tone: def.tone || "a", values, format: def.format }], labels: labelsOf(values.length, meta), format: def.format }));
  const stats = el("p", "chart-stats muted");
  stats.append(el("span", "", `low ${def.format(Math.min(...known))}`), el("span", "", `average ${def.format(known.reduce((n, v) => n + v, 0) / known.length)}`), el("span", "", `high ${def.format(Math.max(...known))}`));
  c.append(stats);
  return c;
}

export function start(api, els, onError) {
  let timer = null;
  const seq = tickets();
  let running = true;
  let range = "1h";

  function mark() {
    for (const b of els.ranges.querySelectorAll("button")) {
      b.setAttribute("aria-pressed", b.dataset.range === range ? "true" : "false");
    }
  }

  async function load() {
    timer = null;
    const ticket = seq.next();
    if (!running || document.hidden) return;
    try {
      const res = await api(`/api/metrics?range=${range}`);
      if (!running || !seq.current(ticket)) return;
      els.charts.replaceChildren(...SERIES.map((def) => seriesCard(def, res.series[def.name], res)));
      els.error.textContent = "";
    } catch (err) {
      if (!running || !seq.current(ticket)) return;
      if (err.status === 401) return onError(err);
      els.error.textContent = err.message;
    }
    if (running && seq.current(ticket)) timer = setTimeout(load, POLL_MS);
  }

  function onVisible() {
    if (!document.hidden && running && timer === null) load();
  }

  for (const b of els.ranges.querySelectorAll("button")) {
    b.onclick = () => {
      range = b.dataset.range;
      mark();
      clearTimeout(timer);
      load();
    };
  }
  document.addEventListener("visibilitychange", onVisible);
  mark();
  load();
  return () => {
    running = false;
    clearTimeout(timer);
    document.removeEventListener("visibilitychange", onVisible);
  };
}
