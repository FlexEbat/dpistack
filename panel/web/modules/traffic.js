// The Traffic Explorer screen (slice 39): devices, applications, domains and
// connections from the newest flow, dns and tls events. It only reads. Every
// source is extra; one that fails is left out and only a 401 signs the user
// out. The model is in traffic-model.js.

import { applications, availability, connections, detail, devices, domains, filterConnections, filterDomains, ntopngUrl } from "./traffic-model.js";
import { humanBytes } from "./system.js";

const POLL_MS = 10000;
const SHOWN = 100; // rows drawn per table; the filter narrows the rest

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function when(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? iso : d.toLocaleString("en-GB");
}

function table(heads, rows, onRow) {
  const t = el("table");
  const head = el("tr");
  for (const h of heads) head.append(el("th", "", h));
  t.append(head);
  for (const cells of rows) {
    const tr = el("tr");
    cells.values.forEach((v) => tr.append(el("td", "", String(v))));
    if (onRow && cells.key) {
      tr.className = "clickable";
      tr.tabIndex = 0;
      tr.addEventListener("click", () => onRow(cells.key));
      tr.addEventListener("keydown", (ev) => {
        if (ev.key === "Enter" || ev.key === " ") {
          ev.preventDefault();
          onRow(cells.key);
        }
      });
    }
    t.append(tr);
  }
  return t;
}

const endpoint = (ip, port) => (port ? ip + ":" + port : ip);

// view builds what every tab draws from one set of answers and the filter.
export function view(data, state) {
  const conns = connections(data.flow);
  const avail = availability(data, conns);
  if (!avail.ready) return { avail, conns };
  const all = devices(conns, { external: state.external });
  const text = state.text.trim().toLowerCase();
  return {
    avail,
    conns,
    devices: all.filter((d) => !text || d.ip.toLowerCase().includes(text) || d.apps.some((a) => a.includes(text))),
    apps: applications(filterConnections(conns, { text: state.text, device: state.device })),
    domains: filterDomains(domains(data.dns, data.tls), { text: state.text, device: state.device }),
    connections: filterConnections(conns, { text: state.text, device: state.device }),
  };
}

function renderNotes(v, area, ntopng) {
  area.replaceChildren();
  for (const n of v.avail.notes) area.append(el("p", v.avail.ready ? "muted" : "muted empty", n));
  if (ntopng) {
    const p = el("p", "muted");
    const a = el("a", "", "Open ntopng");
    a.href = ntopng;
    a.target = "_blank";
    a.rel = "noopener noreferrer";
    p.append("Per host history and live flows: ", a, ".");
    area.append(p);
  }
}

function renderDetail(state, data, area, pick) {
  if (!state.device) {
    area.hidden = true;
    area.replaceChildren();
    return;
  }
  const d = detail(state.device, connections(data.flow), data.dns, data.tls);
  area.hidden = false;
  const head = el("div", "toolbar");
  head.append(el("strong", "", state.device));
  const clear = el("button", "", "Clear device");
  clear.type = "button";
  clear.addEventListener("click", () => pick(""));
  head.append(clear);
  area.replaceChildren(head);
  if (!d.device) {
    area.append(el("p", "muted empty", "This address is not in the newest flow events."));
    return;
  }
  area.append(
    el("p", "muted", `${d.device.flows} connections, ${humanBytes(d.device.sent)} sent, ${humanBytes(d.device.received)} received, ${d.device.peers} other addresses, last seen ${when(d.device.last)}.`),
  );
  if (d.apps.length) area.append(table(["Application", "Connections", "Traffic"], d.apps.map((a) => ({ values: [a.app, a.flows, humanBytes(a.bytes)] }))));
  if (d.domains.length) area.append(table(["Domain", "Seen via", "Times"], d.domains.map((x) => ({ values: [x.domain, x.via.join(", "), x.count] }))));
}

function renderTab(tab, v, area, pick) {
  const rows = (list) => list.slice(0, SHOWN);
  const more = (list) => (list.length > SHOWN ? el("p", "muted", `Showing ${SHOWN} of ${list.length}; use the filter to narrow the list.`) : null);
  let list;
  let node;
  switch (tab) {
    case "devices":
      list = v.devices;
      node = list.length
        ? table(
            ["Address", "Connections", "Sent", "Received", "Applications", "Other addresses", "Last seen"],
            rows(list).map((d) => ({ key: d.ip, values: [d.ip, d.flows, humanBytes(d.sent), humanBytes(d.received), d.apps.join(", "), d.peers, when(d.last)] })),
            pick,
          )
        : el("p", "muted empty", "No device matches. Private addresses only; switch on external addresses to see the rest.");
      break;
    case "applications":
      list = v.apps;
      node = list.length
        ? table(["Application", "Connections", "Traffic", "Source hosts"], rows(list).map((a) => ({ values: [a.app, a.flows, humanBytes(a.bytes), a.hosts] })))
        : el("p", "muted empty", "No application matches.");
      break;
    case "domains":
      list = v.domains;
      node = list.length
        ? table(["Domain", "Seen via", "Times", "Hosts", "Last seen"], rows(list).map((d) => ({ values: [d.domain, d.via.join(", "), d.count, d.hosts.length, when(d.last)] })))
        : el("p", "muted empty", "No domain matches.");
      break;
    default:
      list = v.connections;
      node = list.length
        ? table(
            ["Time", "From", "To", "Protocol", "Application", "Sent", "Received", "Duration"],
            rows(list).map((c) => ({ values: [when(c.time), endpoint(c.src, c.sport), endpoint(c.dst, c.dport), c.proto, c.app, humanBytes(c.sent), humanBytes(c.received), c.age + " s"] })),
          )
        : el("p", "muted empty", "No connection matches.");
  }
  area.replaceChildren(node);
  const extra = more(list);
  if (extra) area.append(extra);
}

export function start(api, els, onError) {
  let running = true;
  let timer = null;
  let busy = false;
  let data = { flow: null, dns: null, tls: null };
  let ntopng = "";
  const state = { tab: "devices", text: "", device: "", external: false };

  function draw() {
    const v = view(data, state);
    renderNotes(v, els.notes, v.avail.ready ? ntopng : "");
    els.body.hidden = !v.avail.ready;
    els.detail.hidden = !v.avail.ready;
    if (!v.avail.ready) {
      els.detail.replaceChildren();
      return;
    }
    for (const b of els.tabs.querySelectorAll("button[data-tab]")) b.setAttribute("aria-pressed", String(b.dataset.tab === state.tab));
    renderDetail(state, data, els.detail, pick);
    renderTab(state.tab, v, els.body, pick);
  }

  function pick(ip) {
    state.device = ip;
    if (ip) state.tab = "connections";
    draw();
  }

  async function once() {
    if (busy) return;
    busy = true;
    const get = (type) => api("/api/eve?limit=500&type=" + type);
    const [flow, dns, tls, settings] = await Promise.allSettled([get("flow"), get("dns"), get("tls"), api("/api/settings")]);
    busy = false;
    if (!running) return;
    for (const r of [flow, dns, tls, settings]) {
      if (r.status === "rejected" && r.reason && r.reason.status === 401) return onError(r.reason);
    }
    const ok = (r) => (r.status === "fulfilled" ? r.value : null);
    data = { flow: ok(flow), dns: ok(dns), tls: ok(tls) };
    if (settings.status === "fulfilled") ntopng = ntopngUrl(settings.value, window.location);
    els.error.textContent = flow.status === "rejected" ? "The panel could not read the events." : "";
    draw();
  }

  const onTab = (ev) => {
    const b = ev.target.closest("button[data-tab]");
    if (!b) return;
    state.tab = b.dataset.tab;
    draw();
  };
  const onText = () => {
    state.text = els.text.value;
    draw();
  };
  const onExternal = () => {
    state.external = els.external.checked;
    draw();
  };
  els.text.value = "";
  els.external.checked = false;
  els.tabs.addEventListener("click", onTab);
  els.text.addEventListener("input", onText);
  els.external.addEventListener("change", onExternal);

  once();
  timer = setInterval(once, POLL_MS);
  return () => {
    running = false;
    if (timer !== null) clearInterval(timer);
    els.tabs.removeEventListener("click", onTab);
    els.text.removeEventListener("input", onText);
    els.external.removeEventListener("change", onExternal);
  };
}
