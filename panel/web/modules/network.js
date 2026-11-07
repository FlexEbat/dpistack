// The Network screen (slice 38): the topology of the capture chain and the
// table of the interfaces. It only reads: adding or removing a capture
// interface stays on Components, where it is confirmed and applied. Every
// source is extra; one that fails is left out and only a 401 signs the user out.

import { topology, others } from "./network-model.js";
import { ifaceRows } from "./system.js";

const POLL_MS = 10000;

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function badge(level, text) {
  return el("span", "badge " + (level || "na"), text || level || "na");
}

function renderTopology(stages, area) {
  if (!stages.length) {
    area.replaceChildren(el("p", "muted empty", "Nothing to draw yet: the host did not report its parts."));
    return;
  }
  const flow = el("ol", "flow");
  stages.forEach((s, i) => {
    const li = el("li", "stage card");
    li.dataset.stage = s.id;
    li.append(el("strong", "", s.title));
    if (s.level !== "na") li.append(badge(s.level));
    for (const line of s.lines || []) li.append(el("span", "muted", line));
    for (const item of s.items || []) li.append(el("span", "", item.name + " (" + item.state + ")"));
    flow.append(li);
    if (i < stages.length - 1) {
      const arrow = el("li", "arrow", "→");
      arrow.setAttribute("aria-hidden", "true");
      flow.append(arrow);
    }
  });
  area.replaceChildren(flow);
}

function renderOthers(parts, area) {
  area.hidden = !parts.length;
  if (!parts.length) return;
  area.replaceChildren(
    el("h2", "", "Other parts"),
    el("p", "muted", "Not part of the event chain above; their own state."),
    ...parts.map((p) => {
      const row = el("p", "other");
      row.append(el("span", "", p.id + " "), badge(p.level, p.state));
      return row;
    }),
  );
}

function renderIfaces(system, area) {
  const rows = system ? ifaceRows(system) : [];
  if (!rows.length) {
    area.replaceChildren(el("p", "muted empty", "No interfaces reported."));
    return;
  }
  const t = el("table");
  const head = el("tr");
  for (const h of ["Interface", "State", "Speed", "Received", "Sent", "Dropped", "Errors", ""]) head.append(el("th", "", h));
  t.append(head);
  for (const r of rows) {
    const tr = el("tr");
    for (const c of [r.name + (r.virtual ? " (virtual)" : ""), r.state, r.speed, r.rx, r.tx, String(r.lost), String(r.errors), r.capture]) tr.append(el("td", "", c));
    t.append(tr);
  }
  area.replaceChildren(t);
}

export function render({ status, system, mode }, areas) {
  renderTopology(topology({ status, system, mode }), areas.topology);
  renderOthers(others(status), areas.others);
  renderIfaces(system, areas.ifaces);
}

export function start(api, areas, onError) {
  let running = true;
  let timer = null;
  let busy = false;

  async function once() {
    if (busy) return;
    busy = true;
    const [status, system, mode] = await Promise.allSettled([api("/api/status"), api("/api/system"), api("/api/mode")]);
    busy = false;
    if (!running) return;
    for (const r of [status, system, mode]) {
      if (r.status === "rejected" && r.reason && r.reason.status === 401) return onError(r.reason);
    }
    const ok = (r) => (r.status === "fulfilled" ? r.value : null);
    areas.error.textContent = status.status === "rejected" && system.status === "rejected" ? "The panel could not read the host state." : "";
    render({ status: ok(status), system: ok(system), mode: ok(mode) }, areas);
  }

  once();
  timer = setInterval(once, POLL_MS);
  return () => {
    running = false;
    if (timer !== null) clearInterval(timer);
  };
}
