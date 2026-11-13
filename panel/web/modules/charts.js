// The chart kit of the panel (tech.md 9.1, v0.47.0): inline SVG only, drawn
// by our own functions, no library, no inline styles (the CSP policy). Every
// colour comes from a class of the stylesheet, so one drawing serves every
// card. The first half of the file is pure
// geometry that node --test can check; the second half builds the DOM.
const NS = "http://www.w3.org/2000/svg";

// ---- pure geometry -------------------------------------------------------

// niceMax rounds a top value up to 1, 2, 2.5, 5 or 10 times a power of ten,
// so the grid lines land on readable numbers.
export function niceMax(value) {
  if (!(value > 0)) return 1;
  const exp = Math.floor(Math.log10(value));
  const base = 10 ** exp;
  const f = value / base;
  const step = f <= 1 ? 1 : f <= 2 ? 2 : f <= 2.5 ? 2.5 : f <= 5 ? 5 : 10;
  return step * base;
}

// gridTicks gives n + 1 values from 0 to max.
export function gridTicks(max, n = 4) {
  return Array.from({ length: n + 1 }, (_, i) => (max / n) * i);
}

// runs splits values at the gaps (null or undefined): each run of known
// values is drawn alone, so a missing stretch is never bridged.
export function runs(values) {
  const out = [];
  let run = [];
  values.forEach((v, i) => {
    if (v === null || v === undefined || Number.isNaN(v)) {
      if (run.length) out.push(run);
      run = [];
      return;
    }
    run.push([i, v]);
  });
  if (run.length) out.push(run);
  return out;
}

// smooth turns points into a path with soft curves (monotone cubic style:
// the control points keep the x of the neighbours, so a curve never
// overshoots the data).
export function smooth(points) {
  if (!points.length) return "";
  if (points.length === 1) return `M${points[0][0].toFixed(1)},${points[0][1].toFixed(1)}h0.01`;
  let d = `M${points[0][0].toFixed(1)},${points[0][1].toFixed(1)}`;
  for (let i = 1; i < points.length; i++) {
    const [x0, y0] = points[i - 1];
    const [x1, y1] = points[i];
    const mx = (x0 + x1) / 2;
    d += `C${mx.toFixed(1)},${y0.toFixed(1)} ${mx.toFixed(1)},${y1.toFixed(1)} ${x1.toFixed(1)},${y1.toFixed(1)}`;
  }
  return d;
}

// areaGeometry lays values out in a box: the lines, the closed areas below
// them, and the scale that was used.
export function areaGeometry(values, { w, h, pad = { t: 8, r: 8, b: 8, l: 8 }, max } = {}) {
  const known = values.filter((v) => v !== null && v !== undefined && !Number.isNaN(v));
  const top = max !== undefined ? max : niceMax(known.length ? Math.max(...known) : 0);
  const iw = w - pad.l - pad.r;
  const ih = h - pad.t - pad.b;
  const n = values.length;
  const x = (i) => pad.l + (n > 1 ? (i / (n - 1)) * iw : iw / 2);
  const y = (v) => pad.t + ih - (top > 0 ? Math.min(v / top, 1) * ih : 0);
  const lines = [];
  const areas = [];
  for (const run of runs(values)) {
    const pts = run.map(([i, v]) => [x(i), y(v)]);
    lines.push(smooth(pts));
    const first = pts[0];
    const last = pts[pts.length - 1];
    areas.push(`${smooth(pts)}L${last[0].toFixed(1)},${(pad.t + ih).toFixed(1)}L${first[0].toFixed(1)},${(pad.t + ih).toFixed(1)}Z`);
  }
  return { lines, areas, top, x, y, inner: { x: pad.l, y: pad.t, w: iw, h: ih } };
}

// indexAt maps an x in the drawing to the nearest value index.
export function indexAt(px, { left, width }, n) {
  if (n <= 1 || width <= 0) return 0;
  const t = Math.min(Math.max((px - left) / width, 0), 1);
  return Math.round(t * (n - 1));
}

// polar converts an angle in degrees (0 at the top, clockwise) to x, y.
export function polar(cx, cy, r, deg) {
  const a = ((deg - 90) * Math.PI) / 180;
  return [cx + r * Math.cos(a), cy + r * Math.sin(a)];
}

// arcPath is the outline of a ring segment between two angles.
export function arcPath(cx, cy, r, from, to) {
  const sweep = Math.min(Math.max(to - from, 0), 359.99);
  const [x0, y0] = polar(cx, cy, r, from);
  const [x1, y1] = polar(cx, cy, r, from + sweep);
  return `M${x0.toFixed(2)},${y0.toFixed(2)}A${r},${r} 0 ${sweep > 180 ? 1 : 0} 1 ${x1.toFixed(2)},${y1.toFixed(2)}`;
}

// donutSegments turns parts [{value}] into angles. A gap in degrees keeps
// the segments apart; parts of zero are skipped.
export function donutSegments(parts, gap = 4) {
  const total = parts.reduce((n, p) => n + Math.max(p.value, 0), 0);
  if (!(total > 0)) return [];
  const live = parts.filter((p) => p.value > 0);
  const room = 360 - (live.length > 1 ? gap * live.length : 0);
  let at = live.length > 1 ? gap / 2 : 0;
  return live.map((p) => {
    const span = (p.value / total) * room;
    const seg = { ...p, from: at, to: at + span, share: p.value / total };
    at += span + (live.length > 1 ? gap : 0);
    return seg;
  });
}

// radarPoints places one value per axis (0 to 1 of the radius).
export function radarPoints(values, cx, cy, r) {
  const n = values.length;
  return values.map((v, i) => polar(cx, cy, r * Math.min(Math.max(v, 0), 1), (360 / n) * i));
}

// shortNumber writes a grid value in few characters (1.5K, 2M), so the
// labels of the axis fit beside a narrow chart. The unit is in the card.
export function shortNumber(v) {
  const a = Math.abs(v);
  const trim = (n) => String(Number(n.toFixed(Math.abs(n) < 1 && n !== 0 ? 2 : 1)));
  if (a >= 1e9) return trim(v / 1e9) + "G";
  if (a >= 1e6) return trim(v / 1e6) + "M";
  if (a >= 1e3) return trim(v / 1e3) + "K";
  return trim(v);
}

// ---- DOM -----------------------------------------------------------------

function svg(tag, attrs = {}, text) {
  const node = document.createElementNS(NS, tag);
  for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, String(v));
  if (text !== undefined) node.textContent = text;
  return node;
}

function html(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

let serial = 0;
const nextId = (p) => `${p}-${++serial}`;

// gradient adds a vertical fade; the colours are classes of the stylesheet
// (stop-color cannot take a CSS variable in an attribute everywhere).
function gradient(defs, tone) {
  const id = nextId("g");
  const g = svg("linearGradient", { id, x1: 0, y1: 0, x2: 0, y2: 1 });
  g.append(svg("stop", { offset: "0%", class: `stop-top tone-${tone}` }), svg("stop", { offset: "100%", class: `stop-bottom tone-${tone}` }));
  defs.append(g);
  return id;
}

const W = 420;
const H = 170;
const PAD = { t: 12, r: 12, b: 24, l: 44 };

// areaChart draws one or two series (the second is optional) as soft lines
// over a faded area, with grid lines, a hover crosshair that reads the
// values, a drag to zoom into a stretch and a double click to reset.
// series: [{ name, tone, values, format }], labels: one text per index.
export function areaChart({ series, labels = [], format = (v) => String(v) }) {
  const wrap = html("div", "chart-wrap");
  const n = Math.max(...series.map((s) => s.values.length), 0);
  let lo = 0;
  let hi = n; // the visible slice [lo, hi)
  const box = svg("svg", { viewBox: `0 0 ${W} ${H}`, class: "chart", role: "img", preserveAspectRatio: "none" });
  const tip = html("div", "chart-tip");
  tip.hidden = true;
  const hint = html("p", "chart-hint muted", "Drag to zoom. Double click to reset.");
  hint.hidden = n < 6;
  wrap.append(box, tip, hint);

  function draw() {
    box.replaceChildren();
    const slice = series.map((s) => s.values.slice(lo, hi));
    const all = slice.flat().filter((v) => v !== null && v !== undefined && !Number.isNaN(v));
    const top = niceMax(all.length ? Math.max(...all) : 0);
    const defs = svg("defs");
    box.append(defs);
    for (const t of gridTicks(top, 4)) {
      const g = areaGeometry([0, 0], { w: W, h: H, pad: PAD, max: top });
      const y = g.y(t);
      box.append(svg("line", { x1: PAD.l, x2: W - PAD.r, y1: y, y2: y, class: "chart-grid" }));
      box.append(svg("text", { x: PAD.l - 8, y: y + 4, class: "chart-tick", "text-anchor": "end" }, shortNumber(t)));
    }
    const count = hi - lo;
    const marks = count < 5 ? count : 5;
    for (let k = 0; k < marks; k++) {
      const i = marks > 1 ? Math.round((k / (marks - 1)) * (count - 1)) : 0;
      const g = areaGeometry(new Array(count).fill(0), { w: W, h: H, pad: PAD, max: top });
      const text = labels[lo + i];
      if (text) box.append(svg("text", { x: g.x(i), y: H - 6, class: "chart-tick", "text-anchor": k === 0 ? "start" : k === marks - 1 ? "end" : "middle" }, text));
    }
    series.forEach((s, k) => {
      const geo = areaGeometry(slice[k], { w: W, h: H, pad: PAD, max: top });
      const id = gradient(defs, s.tone || "a");
      for (const d of geo.areas) box.append(svg("path", { d, fill: `url(#${id})`, class: "chart-area" }));
      for (const d of geo.lines) box.append(svg("path", { d, class: `chart-line tone-${s.tone || "a"}`, fill: "none" }));
    });
    const geo0 = areaGeometry(new Array(Math.max(count, 1)).fill(0), { w: W, h: H, pad: PAD, max: top });
    wrap.geometry = { geo: geo0, top, slice };
  }

  function localX(ev) {
    const r = box.getBoundingClientRect();
    return { px: ev.clientX - r.left, rect: r };
  }

  function show(ev) {
    const { px, rect } = localX(ev);
    const count = hi - lo;
    const inner = wrap.geometry.geo.inner;
    const left = (inner.x / W) * rect.width;
    const width = (inner.w / W) * rect.width;
    const i = indexAt(px, { left, width }, count);
    const cx = ((wrap.geometry.geo.x(i)) / W) * rect.width;
    box.querySelector(".chart-cursor")?.remove();
    box.append(svg("line", { x1: wrap.geometry.geo.x(i), x2: wrap.geometry.geo.x(i), y1: PAD.t, y2: H - PAD.b, class: "chart-cursor" }));
    tip.replaceChildren(html("strong", "", labels[lo + i] || ""));
    series.forEach((s, k) => {
      const v = wrap.geometry.slice[k][i];
      const line = html("span", "chart-tip-row");
      line.append(html("i", `dot tone-${s.tone || "a"}`), html("span", "", `${s.name}: ${v === null || v === undefined ? "no data" : (s.format || format)(v)}`));
      tip.append(line);
    });
    tip.hidden = false;
    tip.classList.toggle("flip", cx > rect.width * 0.6);
    tip.style.left = `${cx}px`;
  }

  let dragFrom = null;
  let band = null;
  box.addEventListener("pointermove", (ev) => {
    if (!wrap.geometry) return;
    show(ev);
    if (dragFrom !== null && band) {
      const { px, rect } = localX(ev);
      const a = Math.min(dragFrom, px);
      const b = Math.max(dragFrom, px);
      band.setAttribute("x", String((a / rect.width) * W));
      band.setAttribute("width", String(((b - a) / rect.width) * W));
    }
  });
  box.addEventListener("pointerleave", () => {
    tip.hidden = true;
    box.querySelector(".chart-cursor")?.remove();
  });
  box.addEventListener("pointerdown", (ev) => {
    const { px } = localX(ev);
    dragFrom = px;
    band = svg("rect", { x: 0, y: PAD.t, width: 0, height: H - PAD.t - PAD.b, class: "chart-band" });
    box.append(band);
  });
  const endDrag = (ev) => {
    if (dragFrom === null) return;
    const { px, rect } = localX(ev);
    const inner = wrap.geometry.geo.inner;
    const left = (inner.x / W) * rect.width;
    const width = (inner.w / W) * rect.width;
    const count = hi - lo;
    const a = indexAt(Math.min(dragFrom, px), { left, width }, count);
    const b = indexAt(Math.max(dragFrom, px), { left, width }, count);
    dragFrom = null;
    band?.remove();
    band = null;
    if (b - a >= 2) {
      hi = lo + b + 1;
      lo = lo + a;
      draw();
    }
  };
  box.addEventListener("pointerup", endDrag);
  box.addEventListener("dblclick", () => {
    lo = 0;
    hi = n;
    draw();
  });
  draw();
  return wrap;
}

// ringGauge is a circle that fills to a percentage, with the number inside.
// tone is ok, warn or crit and sets the colour through a class.
export function ringGauge({ value, max = 100, label, text, tone = "ok", size = 120 }) {
  const wrap = html("div", `ring ${tone}`);
  const r = 46;
  const c = 2 * Math.PI * r;
  const share = max > 0 ? Math.min(Math.max(value / max, 0), 1) : 0;
  const box = svg("svg", { viewBox: "0 0 120 120", class: "ring-svg", role: "img", width: size, height: size, "aria-label": `${label}: ${text}` });
  box.append(svg("circle", { cx: 60, cy: 60, r, class: "ring-track", fill: "none" }));
  box.append(
    svg("circle", {
      cx: 60,
      cy: 60,
      r,
      class: "ring-fill",
      fill: "none",
      "stroke-dasharray": `${(c * share).toFixed(1)} ${c.toFixed(1)}`,
      transform: "rotate(-90 60 60)",
    }),
  );
  box.append(svg("text", { x: 60, y: 62, class: "ring-value", "text-anchor": "middle" }, text));
  box.append(svg("text", { x: 60, y: 80, class: "ring-label", "text-anchor": "middle" }, label));
  wrap.append(box);
  return wrap;
}

// donut shows the shares of parts [{label, value, tone}] with a legend.
export function donut({ parts, center, caption }) {
  const wrap = html("div", "donut");
  const box = svg("svg", { viewBox: "0 0 120 120", class: "donut-svg", role: "img", "aria-label": caption || "Shares" });
  const segs = donutSegments(parts);
  box.append(svg("circle", { cx: 60, cy: 60, r: 44, class: "ring-track", fill: "none" }));
  for (const s of segs) box.append(svg("path", { d: arcPath(60, 60, 44, s.from, s.to), class: `donut-seg tone-${s.tone || "a"}`, fill: "none" }));
  box.append(svg("text", { x: 60, y: 66, class: "ring-value", "text-anchor": "middle" }, center === undefined ? "" : String(center)));
  const legend = html("ul", "legend");
  for (const p of parts) {
    const li = html("li");
    li.append(html("i", `dot tone-${p.tone || "a"}`), html("span", "", p.label), html("strong", "", String(p.value)));
    legend.append(li);
  }
  wrap.append(box, legend);
  return wrap;
}

// radar draws one polygon over rings; axes [{label, value 0..1, text}].
export function radar({ axes, caption }) {
  const wrap = html("div", "radar");
  const box = svg("svg", { viewBox: "0 0 220 200", class: "radar-svg", role: "img", "aria-label": caption || "Radar" });
  const cx = 110;
  const cy = 100;
  const r = 62;
  for (const k of [0.33, 0.66, 1]) {
    box.append(svg("polygon", { points: radarPoints(axes.map(() => k), cx, cy, r).map((p) => p.map((v) => v.toFixed(1)).join(",")).join(" "), class: "radar-ring", fill: "none" }));
  }
  axes.forEach((a, i) => {
    const [x, y] = polar(cx, cy, r, (360 / axes.length) * i);
    box.append(svg("line", { x1: cx, y1: cy, x2: x.toFixed(1), y2: y.toFixed(1), class: "radar-axis" }));
    const [lx, ly] = polar(cx, cy, r + 18, (360 / axes.length) * i);
    box.append(svg("text", { x: lx.toFixed(1), y: (ly + 4).toFixed(1), class: "chart-tick", "text-anchor": "middle" }, `${a.label} ${a.text}`));
  });
  box.append(svg("polygon", { points: radarPoints(axes.map((a) => a.value), cx, cy, r).map((p) => p.map((v) => v.toFixed(1)).join(",")).join(" "), class: "radar-shape" }));
  wrap.append(box);
  return wrap;
}
