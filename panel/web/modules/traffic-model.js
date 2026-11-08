// The model of the Traffic Explorer (slice 39): devices, applications,
// domains and connections, made in the browser from the events that
// GET /api/eve already serves (flow, dns, tls). Pure functions, no DOM, so
// node --test can load it. Nothing here is invented: a field an event does
// not carry stays empty, and `availability` says what is missing and why.

// The server keeps at most 500 events per type (tech.md 4.8); the numbers
// below are therefore "in the newest events", never "all time".

const HEX = /^[0-9a-f:]+$/i;

// isLocal says whether an address is private, link local or loopback. The
// panel does not read HOME_NET, so "device" means a private address and the
// page offers a switch to include the rest.
export function isLocal(ip) {
  const s = String(ip || "");
  const v4 = s.match(/^(\d{1,3})\.(\d{1,3})\.\d{1,3}\.\d{1,3}$/);
  if (v4) {
    const a = Number(v4[1]);
    const b = Number(v4[2]);
    return a === 10 || a === 127 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 169 && b === 254);
  }
  if (s.includes(":") && HEX.test(s)) {
    const first = parseInt(s.split(":")[0] || "0", 16);
    return s === "::1" || (first & 0xfe00) === 0xfc00 || (first & 0xffc0) === 0xfe80;
  }
  return false;
}

function num(v) {
  return typeof v === "number" && Number.isFinite(v) && v >= 0 ? v : 0;
}

function asEvents(res) {
  return res && Array.isArray(res.events) ? res.events : [];
}

// connections turns flow events into rows, newest first as served.
export function connections(res) {
  const rows = [];
  for (const item of asEvents(res)) {
    const e = item && item.event;
    if (!e || !e.src_ip || !e.dest_ip) continue;
    const f = e.flow || {};
    rows.push({
      time: item.time || e.timestamp || "",
      src: e.src_ip,
      sport: e.src_port || 0,
      dst: e.dest_ip,
      dport: e.dest_port || 0,
      proto: e.proto || "",
      app: e.app_proto && e.app_proto !== "failed" ? e.app_proto : "",
      sent: num(f.bytes_toserver),
      received: num(f.bytes_toclient),
      packets: num(f.pkts_toserver) + num(f.pkts_toclient),
      age: num(f.age),
      state: f.state || "",
    });
  }
  return rows;
}

function bucket(map, key, make) {
  let b = map.get(key);
  if (!b) {
    b = make();
    map.set(key, b);
  }
  return b;
}

// devices sums the connections per address. In a flow event src_ip started
// the flow, so its bytes_toserver are what src sent and bytes_toclient what
// it received; the other end gets the opposite.
export function devices(conns, { external = false } = {}) {
  const map = new Map();
  const touch = (ip, sent, received, app, peer, time) => {
    if (!external && !isLocal(ip)) return;
    const d = bucket(map, ip, () => ({ ip, local: isLocal(ip), flows: 0, sent: 0, received: 0, apps: new Set(), peers: new Set(), last: "" }));
    d.flows += 1;
    d.sent += sent;
    d.received += received;
    if (app) d.apps.add(app);
    d.peers.add(peer);
    if (time > d.last) d.last = time;
  };
  for (const c of conns) {
    touch(c.src, c.sent, c.received, c.app, c.dst, c.time);
    touch(c.dst, c.received, c.sent, c.app, c.src, c.time);
  }
  return [...map.values()]
    .map((d) => ({ ip: d.ip, local: d.local, flows: d.flows, sent: d.sent, received: d.received, total: d.sent + d.received, apps: [...d.apps].sort(), peers: d.peers.size, last: d.last }))
    .sort((a, b) => b.total - a.total || b.flows - a.flows || (a.ip < b.ip ? -1 : 1));
}

// applications groups connections by the protocol Suricata named
// (app_proto). Connections with none are counted apart, not hidden.
export function applications(conns) {
  const map = new Map();
  for (const c of conns) {
    const name = c.app || "unknown";
    const a = bucket(map, name, () => ({ app: name, flows: 0, bytes: 0, hosts: new Set() }));
    a.flows += 1;
    a.bytes += c.sent + c.received;
    a.hosts.add(c.src);
  }
  return [...map.values()]
    .map((a) => ({ app: a.app, flows: a.flows, bytes: a.bytes, hosts: a.hosts.size }))
    .sort((a, b) => b.bytes - a.bytes || b.flows - a.flows || (a.app < b.app ? -1 : 1));
}

// domains lists what DNS queries asked for and what TLS handshakes named
// (the SNI). Answers and empty names are skipped.
export function domains(dnsRes, tlsRes) {
  const map = new Map();
  const add = (name, via, host, time) => {
    const n = String(name || "").toLowerCase().replace(/\.$/, "");
    if (!n) return;
    const d = bucket(map, n, () => ({ domain: n, via: new Set(), hosts: new Set(), count: 0, last: "" }));
    d.via.add(via);
    if (host) d.hosts.add(host);
    d.count += 1;
    if (time > d.last) d.last = time;
  };
  for (const item of asEvents(dnsRes)) {
    const e = item && item.event;
    const q = e && e.dns;
    if (!q || (q.type && q.type !== "query")) continue;
    add(q.rrname, "dns", e.src_ip, item.time || "");
  }
  for (const item of asEvents(tlsRes)) {
    const e = item && item.event;
    if (!e || !e.tls) continue;
    add(e.tls.sni, "tls", e.src_ip, item.time || "");
  }
  return [...map.values()]
    .map((d) => ({ domain: d.domain, via: [...d.via].sort(), hosts: [...d.hosts].sort(), count: d.count, last: d.last }))
    .sort((a, b) => b.count - a.count || (a.domain < b.domain ? -1 : 1));
}

// filterConnections narrows the rows: a text found in any endpoint, the
// application or the protocol, plus an exact device (either end).
export function filterConnections(conns, { text = "", device = "" } = {}) {
  const q = String(text).trim().toLowerCase();
  return conns.filter((c) => {
    if (device && c.src !== device && c.dst !== device) return false;
    if (!q) return true;
    return [c.src, c.dst, String(c.sport), String(c.dport), c.proto, c.app].some((v) => String(v).toLowerCase().includes(q));
  });
}

export function filterDomains(rows, { text = "", device = "" } = {}) {
  const q = String(text).trim().toLowerCase();
  return rows.filter((d) => (!device || d.hosts.includes(device)) && (!q || d.domain.includes(q)));
}

// detail is what one device shows: its own totals, the applications and
// domains seen for it, and its newest connections.
export function detail(ip, conns, dnsRes, tlsRes, limit = 20) {
  const mine = filterConnections(conns, { device: ip });
  const me = devices(mine, { external: true }).find((d) => d.ip === ip) || null;
  return {
    device: me,
    apps: applications(mine),
    domains: filterDomains(domains(dnsRes, tlsRes), { device: ip }).slice(0, limit),
    connections: mine.slice(0, limit),
  };
}

// availability says what the page cannot show and why, in words for the
// screen. `res` is the answer of /api/eve for each type (null when the
// request failed); `conns` are the parsed flow rows.
export function availability({ flow, dns, tls }, conns) {
  const notes = [];
  const off = [flow, dns, tls].find((r) => r && r.available === false);
  if (off) return { ready: false, notes: [off.reason || "The event view is off."] };
  if (!flow) return { ready: false, notes: ["The panel could not read the flow events."] };
  if (!flow.file_present) return { ready: false, notes: ["eve.json does not exist yet: Suricata has not written it."] };
  if (!conns.length) {
    const types = Array.isArray(flow.types) ? flow.types : [];
    const reason = types.includes("flow")
      ? "No flow events yet: a flow is written when it ends, so a quiet link shows nothing for a while."
      : "Suricata writes no flow events. Add flow to EVE_TYPES in Settings, then apply it.";
    return { ready: false, notes: [reason] };
  }
  if (!conns.some((c) => c.app)) notes.push("No application names in the flows yet: app_proto is empty for every connection.");
  if (!dns || !asEvents(dns).length) notes.push("No DNS events: domains from DNS queries are empty.");
  if (!tls || !asEvents(tls).length) notes.push("No TLS events: domains from the TLS server name are empty.");
  // Suricata writes MAC addresses only with the ethernet option of eve-log,
  // which the installer does not set; say so once instead of showing blanks.
  notes.push("MAC addresses are not in the events, so devices are told apart by IP address only.");
  return { ready: true, notes };
}

// ntopngUrl builds the link to ntopng from the page's own host name and
// NTOPNG_PORT of /api/settings (its `keys` list). NTOPNG_PORT is the port the
// user opens in every access mode: with nginx it is the public port and
// ntopng itself sits ten thousand higher behind it.
export function ntopngUrl(settings, loc) {
  const list = settings && Array.isArray(settings.keys) ? settings.keys : [];
  const get = (k) => (list.find((s) => s.key === k) || {}).value;
  // No NTOPNG_PORT in the answer means the settings could not be read: a
  // link to a guessed port would be worse than no link.
  if (get("NTOPNG_PORT") === undefined || String(get("NTOPNG_ENABLE")).toLowerCase() === "no") return "";
  const port = Number(get("NTOPNG_PORT"));
  if (!Number.isInteger(port) || port < 1 || port > 65535 || !loc || !loc.hostname) return "";
  const proto = loc.protocol === "https:" ? "https:" : "http:";
  const host = loc.hostname.includes(":") ? "[" + loc.hostname + "]" : loc.hostname;
  return proto + "//" + host + ":" + port + "/";
}
