// The model of the Events workspace (slice 40): filters by address, rule,
// category, protocol, severity and domain, grouping, the events of one flow,
// the history of one rule, and the JSON and CSV export. Pure functions, no
// DOM. The server filters by type, text and time only (GET /api/eve); every
// other filter works on the events the screen has loaded (at most 500), and
// the screen says so.

const CELL_RISKY = /^[=+\-@\t\r]/;

const lower = (v) => String(v === undefined || v === null ? "" : v).toLowerCase();

// since turns the time choice into the ?since= value of /api/eve, an empty
// string for "all loaded".
export function since(range, now = Date.now()) {
  const span = { "15m": 15 * 60, "1h": 3600, "24h": 86400, "7d": 7 * 86400 }[range];
  return span ? new Date(now - span * 1000).toISOString() : "";
}

// domainOf is the name an event is about, from DNS, TLS or HTTP.
export function domainOf(e) {
  return (e.dns && e.dns.rrname) || (e.tls && e.tls.sni) || (e.http && e.http.hostname) || "";
}

// matches says whether an event passes the filters. An empty filter passes
// everything; a filter on a field the event does not have fails it, so that
// "severity 1" shows alerts only.
export function matches(ev, f) {
  const e = (ev && ev.event) || {};
  const a = e.alert || {};
  if (f.ip) {
    const q = lower(f.ip).trim();
    if (q && !lower(e.src_ip).includes(q) && !lower(e.dest_ip).includes(q)) return false;
  }
  if (f.sid) {
    if (String(a.signature_id) !== String(f.sid).trim()) return false;
  }
  if (f.category) {
    if (!lower(a.category).includes(lower(f.category).trim())) return false;
  }
  if (f.proto) {
    const p = lower(f.proto).trim();
    if (p && lower(e.proto) !== p && lower(e.app_proto) !== p) return false;
  }
  if (f.severity) {
    if (String(a.severity) !== String(f.severity)) return false;
  }
  if (f.domain) {
    const q = lower(f.domain).trim();
    if (q && !lower(domainOf(e)).includes(q)) return false;
  }
  return true;
}

export function filterEvents(events, f) {
  return events.filter((ev) => matches(ev, f));
}

// activeFilters counts the filters that are set, for the line above the list.
export function activeFilters(f) {
  return ["ip", "sid", "category", "proto", "severity", "domain"].filter((k) => String(f[k] || "").trim() !== "").length;
}

const sevOf = (e) => (e.alert && Number.isInteger(e.alert.severity) ? e.alert.severity : 0);

// groupBy counts events by rule, source, destination or category. Each group
// carries what the screen needs to filter by it: the field and its value.
export function groupBy(events, by) {
  const keyOf = {
    signature: (e) => (e.alert ? { key: `${e.alert.signature_id} ${e.alert.signature || ""}`.trim(), field: "sid", value: String(e.alert.signature_id) } : null),
    source: (e) => (e.src_ip ? { key: e.src_ip, field: "ip", value: e.src_ip } : null),
    destination: (e) => (e.dest_ip ? { key: e.dest_ip, field: "ip", value: e.dest_ip } : null),
    category: (e) => (e.alert && e.alert.category ? { key: e.alert.category, field: "category", value: e.alert.category } : null),
  }[by];
  if (!keyOf) return [];
  const map = new Map();
  for (const ev of events) {
    const e = ev.event || {};
    const k = keyOf(e);
    if (!k) continue;
    let g = map.get(k.key);
    if (!g) {
      g = { key: k.key, field: k.field, value: k.value, count: 0, last: "", severity: 0 };
      map.set(k.key, g);
    }
    g.count += 1;
    if ((ev.time || "") > g.last) g.last = ev.time || "";
    const s = sevOf(e);
    if (s && (g.severity === 0 || s < g.severity)) g.severity = s; // 1 is the worst
  }
  return [...map.values()].sort((a, b) => b.count - a.count || (a.key < b.key ? -1 : 1));
}

// related is the events of one flow in time order. Suricata gives alerts,
// flow, dns, tls and http events of the same connection the same flow_id.
export function related(events, flowId) {
  if (flowId === undefined || flowId === null || flowId === "") return [];
  return events
    .filter((ev) => ev.event && String(ev.event.flow_id) === String(flowId))
    .sort((a, b) => (a.time || "") < (b.time || "") ? -1 : (a.time || "") > (b.time || "") ? 1 : 0);
}

const top = (counts, n) =>
  [...counts.entries()]
    .sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1))
    .slice(0, n)
    .map(([value, count]) => ({ value, count }));

// sidHistory is what the loaded alerts say about one rule: how often, when it
// first and last fired, and from and to which addresses.
export function sidHistory(events, sid) {
  const src = new Map();
  const dst = new Map();
  let count = 0;
  let first = "";
  let last = "";
  let signature = "";
  for (const ev of events) {
    const e = ev.event || {};
    if (!e.alert || String(e.alert.signature_id) !== String(sid)) continue;
    count += 1;
    signature = signature || e.alert.signature || "";
    const t = ev.time || "";
    if (!first || t < first) first = t;
    if (t > last) last = t;
    if (e.src_ip) src.set(e.src_ip, (src.get(e.src_ip) || 0) + 1);
    if (e.dest_ip) dst.set(e.dest_ip, (dst.get(e.dest_ip) || 0) + 1);
  }
  return { sid: String(sid), signature, count, first, last, sources: top(src, 5), destinations: top(dst, 5) };
}

export const CSV_COLUMNS = ["time", "type", "src_ip", "src_port", "dest_ip", "dest_port", "proto", "app_proto", "signature_id", "signature", "category", "severity", "domain", "flow_id"];

// cell quotes one CSV value. A value a spreadsheet would run as a formula
// (it starts with = + - @ or a control character) gets a leading apostrophe,
// so that opening the export cannot execute something an attacker put in a
// packet.
export function cell(v) {
  let s = v === undefined || v === null ? "" : String(v);
  if (CELL_RISKY.test(s)) s = "'" + s;
  return /[",\r\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
}

export function toCSV(events) {
  const rows = [CSV_COLUMNS.join(",")];
  for (const ev of events) {
    const e = ev.event || {};
    const a = e.alert || {};
    const values = {
      time: ev.time, type: ev.type, src_ip: e.src_ip, src_port: e.src_port, dest_ip: e.dest_ip, dest_port: e.dest_port,
      proto: e.proto, app_proto: e.app_proto, signature_id: a.signature_id, signature: a.signature, category: a.category,
      severity: a.severity, domain: domainOf(e), flow_id: e.flow_id,
    };
    rows.push(CSV_COLUMNS.map((c) => cell(values[c])).join(","));
  }
  return rows.join("\r\n") + "\r\n";
}

// toJSON is the events as the server gave them, one array, readable.
export function toJSON(events) {
  return JSON.stringify(events.map((ev) => ({ time: ev.time, type: ev.type, event: ev.event })), null, 2) + "\n";
}

export function exportName(kind, ext, now = new Date()) {
  const stamp = now.toISOString().slice(0, 19).replace(/[-:]/g, "").replace("T", "-");
  return `dpistack-${kind}-${stamp}.${ext}`;
}
