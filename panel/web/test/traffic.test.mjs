import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { applications, availability, connections, detail, devices, domains, filterConnections, filterDomains, isLocal, ntopngUrl } from "../modules/traffic-model.js";
import { view } from "../modules/traffic.js";

const flow = (src, dst, extra = {}) => ({
  id: 1,
  type: "flow",
  time: extra.time || "2026-11-08T10:00:00Z",
  event: {
    src_ip: src,
    dest_ip: dst,
    src_port: extra.sport ?? 50000,
    dest_port: extra.dport ?? 443,
    proto: extra.proto || "TCP",
    app_proto: extra.app,
    flow: { bytes_toserver: extra.up ?? 100, bytes_toclient: extra.down ?? 900, pkts_toserver: 2, pkts_toclient: 3, age: extra.age ?? 5, state: "closed" },
  },
});
const res = (events, extra = {}) => ({ available: true, file_present: true, types: ["flow", "dns", "tls"], events, ...extra });
const dnsEv = (host, name, type = "query") => ({ type: "dns", time: "2026-11-08T10:00:01Z", event: { src_ip: host, dns: { type, rrname: name } } });
const tlsEv = (host, sni) => ({ type: "tls", time: "2026-11-08T10:00:02Z", event: { src_ip: host, tls: { sni } } });

test("isLocal: private, link local and loopback addresses are local, public ones are not", () => {
  for (const ip of ["10.1.2.3", "172.16.0.1", "172.31.255.1", "192.168.1.5", "127.0.0.1", "169.254.1.1", "fd12::1", "fe80::1", "::1"]) assert.equal(isLocal(ip), true, ip);
  for (const ip of ["8.8.8.8", "172.32.0.1", "172.15.0.1", "192.169.0.1", "2001:db8::1", "", "not an ip"]) assert.equal(isLocal(ip), false, ip);
});

test("connections: rows come from flow events, a flow without both addresses is skipped, a failed app_proto is empty", () => {
  const rows = connections(res([flow("10.0.0.2", "1.1.1.1", { app: "tls" }), flow("10.0.0.3", "1.1.1.1", { app: "failed" }), { event: { src_ip: "10.0.0.4" } }, null]));
  assert.equal(rows.length, 2);
  assert.deepEqual(
    { src: rows[0].src, dst: rows[0].dst, dport: rows[0].dport, app: rows[0].app, sent: rows[0].sent, received: rows[0].received, packets: rows[0].packets },
    { src: "10.0.0.2", dst: "1.1.1.1", dport: 443, app: "tls", sent: 100, received: 900, packets: 5 },
  );
  assert.equal(rows[1].app, "");
  assert.deepEqual(connections(null), []);
});

test("connections: negative or non numeric byte counts count as zero", () => {
  const ev = flow("10.0.0.2", "1.1.1.1");
  ev.event.flow.bytes_toserver = -5;
  ev.event.flow.bytes_toclient = "9";
  const [r] = connections(res([ev]));
  assert.equal(r.sent, 0);
  assert.equal(r.received, 0);
});

test("devices: each end gets the traffic from its own side, and external addresses are left out unless asked", () => {
  const conns = connections(res([flow("10.0.0.2", "8.8.8.8", { up: 100, down: 900, app: "tls" })]));
  const local = devices(conns);
  assert.equal(local.length, 1);
  assert.equal(local[0].ip, "10.0.0.2");
  assert.equal(local[0].sent, 100);
  assert.equal(local[0].received, 900);
  const all = devices(conns, { external: true });
  const ext = all.find((d) => d.ip === "8.8.8.8");
  assert.equal(ext.sent, 900);
  assert.equal(ext.received, 100);
  assert.equal(ext.local, false);
});

test("devices: sorted by total traffic, then by connections, then by address", () => {
  const conns = connections(
    res([flow("10.0.0.5", "10.0.0.9", { up: 10, down: 10 }), flow("10.0.0.7", "10.0.0.9", { up: 500, down: 500 }), flow("10.0.0.6", "10.0.0.9", { up: 10, down: 10 })]),
  );
  assert.deepEqual(devices(conns).map((d) => d.ip), ["10.0.0.9", "10.0.0.7", "10.0.0.5", "10.0.0.6"]);
});

test("devices: applications and peers are counted without repeats", () => {
  const conns = connections(res([flow("10.0.0.2", "1.1.1.1", { app: "tls" }), flow("10.0.0.2", "1.1.1.1", { app: "tls" }), flow("10.0.0.2", "9.9.9.9", { app: "dns" })]));
  const d = devices(conns)[0];
  assert.deepEqual(d.apps, ["dns", "tls"]);
  assert.equal(d.peers, 2);
  assert.equal(d.flows, 3);
});

test("applications: a connection with no app_proto is counted as unknown, not hidden", () => {
  const apps = applications(connections(res([flow("10.0.0.2", "1.1.1.1", { app: "tls", up: 1, down: 1 }), flow("10.0.0.3", "1.1.1.1", { up: 50, down: 50 }), flow("10.0.0.4", "1.1.1.1", { up: 50, down: 50 })])));
  assert.deepEqual(apps.map((a) => [a.app, a.flows, a.bytes, a.hosts]), [["unknown", 2, 200, 2], ["tls", 1, 2, 1]]);
});

test("domains: DNS queries count, answers do not; the TLS name joins the same domain; case and a trailing dot are ignored", () => {
  const rows = domains(
    res([dnsEv("10.0.0.2", "Example.com."), dnsEv("10.0.0.2", "example.com", "answer"), dnsEv("10.0.0.3", "other.org"), dnsEv("10.0.0.3", "")]),
    res([tlsEv("10.0.0.2", "example.com"), tlsEv("10.0.0.2", undefined)]),
  );
  assert.deepEqual(rows.map((d) => [d.domain, d.count, d.via.join("+"), d.hosts.join(",")]), [["example.com", 2, "dns+tls", "10.0.0.2"], ["other.org", 1, "dns", "10.0.0.3"]]);
});

test("filterConnections: text matches an endpoint, port, protocol or application; a device matches either end", () => {
  const conns = connections(res([flow("10.0.0.2", "1.1.1.1", { app: "tls" }), flow("10.0.0.3", "10.0.0.2", { app: "dns", dport: 53, proto: "UDP" }), flow("10.0.0.4", "1.1.1.1", { app: "http", dport: 80 })]));
  assert.equal(filterConnections(conns, { text: "UDP" }).length, 1);
  assert.equal(filterConnections(conns, { text: "80" }).length, 1);
  assert.equal(filterConnections(conns, { text: "tls" }).length, 1);
  assert.equal(filterConnections(conns, { device: "10.0.0.2" }).length, 2);
  assert.equal(filterConnections(conns, { device: "10.0.0.2", text: "dns" }).length, 1);
  assert.equal(filterConnections(conns, {}).length, 3);
});

test("filterDomains: by text and by the host that asked", () => {
  const rows = domains(res([dnsEv("10.0.0.2", "a.example.com"), dnsEv("10.0.0.3", "b.example.com")]), res([]));
  assert.deepEqual(filterDomains(rows, { text: "a.ex" }).map((d) => d.domain), ["a.example.com"]);
  assert.deepEqual(filterDomains(rows, { device: "10.0.0.3" }).map((d) => d.domain), ["b.example.com"]);
});

test("detail: one device with its own totals, applications, domains and connections", () => {
  const f = res([flow("10.0.0.2", "1.1.1.1", { app: "tls" }), flow("10.0.0.3", "1.1.1.1", { app: "dns" })]);
  const d = detail("10.0.0.2", connections(f), res([dnsEv("10.0.0.2", "mine.example"), dnsEv("10.0.0.3", "theirs.example")]), res([]));
  assert.equal(d.device.flows, 1);
  assert.deepEqual(d.apps.map((a) => a.app), ["tls"]);
  assert.deepEqual(d.domains.map((x) => x.domain), ["mine.example"]);
  assert.equal(d.connections.length, 1);
  assert.equal(detail("10.9.9.9", connections(f), res([]), res([])).device, null);
});

test("availability: the page says exactly what is missing", () => {
  const conns = connections(res([flow("10.0.0.2", "1.1.1.1", { app: "tls" })]));
  assert.match(availability({ flow: { available: false, reason: "event view is off (EVE_FILE=no)" } }, []).notes[0], /EVE_FILE=no/);
  assert.match(availability({ flow: null }, []).notes[0], /could not read/);
  assert.match(availability({ flow: res([], { file_present: false }) }, []).notes[0], /does not exist yet/);
  assert.match(availability({ flow: res([], { types: ["alert"] }) }, []).notes[0], /EVE_TYPES/);
  assert.match(availability({ flow: res([], { types: ["flow"] }) }, []).notes[0], /No flow events yet/);
  const ready = availability({ flow: res([flow("10.0.0.2", "1.1.1.1")]), dns: res([]), tls: res([]) }, connections(res([flow("10.0.0.2", "1.1.1.1")])));
  assert.equal(ready.ready, true);
  assert.ok(ready.notes.some((n) => /app_proto/.test(n)));
  assert.ok(ready.notes.some((n) => /No DNS events/.test(n)));
  assert.ok(ready.notes.some((n) => /No TLS events/.test(n)));
  assert.ok(ready.notes.some((n) => /MAC addresses/.test(n)));
  const full = availability({ flow: res([]), dns: res([dnsEv("10.0.0.2", "a.b")]), tls: res([tlsEv("10.0.0.2", "a.b")]) }, conns);
  assert.equal(full.notes.length, 1);
  assert.match(full.notes[0], /MAC addresses/);
});

test("ntopngUrl: host of the page, port from the settings, nothing when ntopng is off or the port is bad", () => {
  const keys = (o) => ({ keys: Object.entries(o).map(([key, value]) => ({ key, value })) });
  assert.equal(ntopngUrl(keys({ NTOPNG_ENABLE: "yes", NTOPNG_PORT: "3010" }), { hostname: "ids.lan", protocol: "http:" }), "http://ids.lan:3010/");
  assert.equal(ntopngUrl(keys({ NTOPNG_PORT: "3000" }), { hostname: "ids.lan", protocol: "https:" }), "https://ids.lan:3000/");
  assert.equal(ntopngUrl(keys({}), { hostname: "ids.lan", protocol: "http:" }), "");
  assert.equal(ntopngUrl(keys({ NTOPNG_PORT: "3000" }), { hostname: "fd00::5", protocol: "http:" }), "http://[fd00::5]:3000/");
  assert.equal(ntopngUrl(keys({ NTOPNG_ENABLE: "no" }), { hostname: "ids.lan", protocol: "http:" }), "");
  assert.equal(ntopngUrl(keys({ NTOPNG_PORT: "70000" }), { hostname: "ids.lan", protocol: "http:" }), "");
  assert.equal(ntopngUrl(null, { hostname: "ids.lan", protocol: "http:" }), "");
  assert.equal(ntopngUrl(keys({ NTOPNG_PORT: "3000" }), {}), "");
});

test("view: not ready gives no tables; ready applies the text, the device and the external switch", () => {
  const state = { tab: "devices", text: "", device: "", external: false };
  assert.equal(view({ flow: res([], { types: ["alert"] }), dns: null, tls: null }, state).devices, undefined);
  const data = { flow: res([flow("10.0.0.2", "8.8.8.8", { app: "tls" }), flow("10.0.0.3", "10.0.0.2", { app: "dns", dport: 53 })]), dns: res([dnsEv("10.0.0.2", "a.example")]), tls: res([]) };
  assert.deepEqual(view(data, state).devices.map((d) => d.ip).sort(), ["10.0.0.2", "10.0.0.3"]);
  assert.equal(view(data, { ...state, external: true }).devices.length, 3);
  assert.deepEqual(view(data, { ...state, text: "dns" }).devices.map((d) => d.ip).sort(), ["10.0.0.2", "10.0.0.3"]);
  assert.deepEqual(view(data, { ...state, text: "10.0.0.3" }).devices.map((d) => d.ip), ["10.0.0.3"]);
  assert.equal(view(data, { ...state, device: "10.0.0.3" }).connections.length, 1);
  assert.deepEqual(view(data, { ...state, device: "10.0.0.3" }).domains, []);
});

test("the page has the Traffic screen: view, menu entry in Monitoring, route and start function", () => {
  const html = readFileSync(new URL("../index.html", import.meta.url), "utf8");
  const app = readFileSync(new URL("../app.js", import.meta.url), "utf8");
  assert.match(html, /id="view-traffic"/);
  const monitoring = html.match(/aria-label="Monitoring">[\s\S]*?<\/div>/)[0];
  assert.match(monitoring, /data-view="traffic"/);
  for (const id of ["traffic-error", "traffic-notes", "traffic-tabs", "traffic-q", "traffic-external", "traffic-detail", "traffic-body"]) assert.match(html, new RegExp('id="' + id + '"'), id);
  assert.match(app, /"network", "traffic", "components"/);
  assert.match(app, /traffic: \(\) =>/);
  for (const id of ["traffic-error", "traffic-notes", "traffic-tabs", "traffic-q", "traffic-external", "traffic-detail", "traffic-body"]) assert.ok(app.includes('$("' + id + '")'), id);
});
