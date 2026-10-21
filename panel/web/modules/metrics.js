// The Metrics screen: six small line charts of the last 1, 6 or 24 hours.
// Charts are plain SVG; a series that cannot exist is shown as a note with
// the reason, never as a flat line at zero, and a gap in the data is a gap
// in the line.
import { tickets } from "./poll.js";

const POLL_MS = 30000; // the server samples every 30 s, so asking more often shows nothing new
const W = 300;
const H = 90;
const NS = "http://www.w3.org/2000/svg";

// What the screen shows per series, in order. Conversions keep the numbers
// readable: bytes become megabytes, the free share becomes percent.
export const SERIES = [
  { name: "pps", title: "Пакеты в секунду", format: (v) => `${Math.round(v).toLocaleString("ru-RU")} пак/с` },
  { name: "drops", title: "Потери пакетов в секунду", format: (v) => `${v.toLocaleString("ru-RU", { maximumFractionDigits: 2 })} пак/с` },
  { name: "cpu", title: "CPU панели", format: (v) => `${v.toLocaleString("ru-RU", { maximumFractionDigits: 1 })} %` },
  { name: "rss", title: "Память панели", format: bytes },
  { name: "eve_size", title: "Размер eve.json", format: bytes },
  { name: "disk", title: "Свободно на диске с логами", scale: 100, format: (v) => `${v.toLocaleString("ru-RU", { maximumFractionDigits: 1 })} %` },
];

function bytes(v) {
  const units = ["Б", "КБ", "МБ", "ГБ", "ТБ"];
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return `${v.toLocaleString("ru-RU", { maximumFractionDigits: v < 10 && i > 0 ? 1 : 0 })} ${units[i]}`;
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function svg(tag, attrs) {
  const node = document.createElementNS(NS, tag);
  for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
  return node;
}

// segments splits the values at the gaps: each run of known values is one
// polyline, so a missing stretch is not bridged by a line.
export function segments(values, max) {
  const n = values.length;
  const runs = [];
  let run = [];
  values.forEach((v, i) => {
    if (v === null || v === undefined) {
      if (run.length) runs.push(run);
      run = [];
      return;
    }
    const x = n > 1 ? (i / (n - 1)) * W : 0;
    const y = H - 4 - (max > 0 ? (v / max) * (H - 8) : 0);
    run.push(`${x.toFixed(1)},${y.toFixed(1)}`);
  });
  if (run.length) runs.push(run);
  return runs;
}

function chart(values) {
  const known = values.filter((v) => v !== null && v !== undefined);
  const max = known.length ? Math.max(...known) * 1.1 : 0;
  const box = svg("svg", { viewBox: `0 0 ${W} ${H}`, class: "chart", role: "img", preserveAspectRatio: "none" });
  box.append(svg("line", { x1: 0, y1: H - 4, x2: W, y2: H - 4, class: "chart-axis" }));
  for (const run of segments(values, max)) {
    // A single point has no line; draw it as a short stroke so it is seen.
    const points = run.length === 1 ? [run[0], run[0].replace(/^[\d.]+/, (x) => String(+x + 1))] : run;
    box.append(svg("polyline", { points: points.join(" "), class: "chart-line" }));
  }
  return box;
}

function card(def, series) {
  const c = el("div", "chart-card");
  c.append(el("h3", "", def.title));
  if (!series || !series.available) {
    // Unavailable is said in words: a zero line would claim the opposite.
    c.append(el("p", "muted", `Нет данных: ${(series && series.reason) || "ряд недоступен"}.`));
    return c;
  }
  const scale = def.scale || 1;
  const values = series.values.map((v) => (v === null ? null : v * scale));
  const last = [...values].reverse().find((v) => v !== null && v !== undefined);
  c.append(el("p", "chart-last", last === undefined ? "нет значений за период" : `сейчас ${def.format(last)}`));
  c.append(chart(values));
  const known = values.filter((v) => v !== null && v !== undefined);
  if (known.length) c.append(el("p", "muted", `за период: от ${def.format(Math.min(...known))} до ${def.format(Math.max(...known))}`));
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
      els.charts.replaceChildren(...SERIES.map((def) => card(def, res.series[def.name])));
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
