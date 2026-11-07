import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { topology, others, levelOf } from "../modules/network-model.js";
import { start } from "../modules/network.js";

const here = (f) => readFileSync(new URL("../" + f, import.meta.url), "utf8");

const comp = (id, state, enabled = true) => ({ id, runtime: "host", state, enabled, version: "" });
const full = {
  status: {
    components: [comp("suricata", "active"), comp("evebox", "active"), comp("ntopng", "inactive"), comp("redis", "active"), comp("grafana", "absent")],
    health: { overall: "ok", checks: [{ id: "suricata.eve_fresh", status: "ok", detail: "eve.json written 3 s ago" }] },
  },
  system: { hostname: "ids-gw-01", interfaces: [{ name: "eth1", state: "up", capture: true }, { name: "eth0", state: "up", capture: false }] },
  mode: { mode: "ids" },
};

test("the chain is host, capture, Suricata, eve.json, EveBox in that order", () => {
  assert.deepEqual(topology(full).map((s) => s.id), ["host", "capture", "suricata", "eve", "evebox"]);
});

test("the capture stage lists only the interfaces that capture", () => {
  const capture = topology(full).find((s) => s.id === "capture");
  assert.deepEqual(capture.items, [{ name: "eth1", state: "up" }]);
  assert.equal(capture.level, "ok");
});

test("no capture interface is a warning that says so", () => {
  const sys = { hostname: "h", interfaces: [{ name: "eth0", state: "up", capture: false }] };
  const capture = topology({ ...full, system: sys }).find((s) => s.id === "capture");
  assert.equal(capture.level, "warn");
  assert.deepEqual(capture.lines, ["no interface is captured"]);
});

test("a host that did not say which interface captures draws no capture stage", () => {
  const sys = { hostname: "h", interfaces: [{ name: "eth0", state: "up" }] };
  assert.equal(topology({ ...full, system: sys }).some((s) => s.id === "capture"), false);
});

test("IPS is named as able to drop traffic and IDS as watching only", () => {
  const lines = (mode) => topology({ ...full, mode }).find((s) => s.id === "suricata").lines.join(" ");
  assert.match(lines({ mode: "ips" }), /can drop traffic/);
  assert.match(lines({ mode: "ids" }), /watching only/);
  assert.doesNotMatch(lines(null), /IDS|IPS/);
});

test("eve.json takes its level from the watchdog check and is left out without it", () => {
  const crit = { ...full, status: { ...full.status, health: { checks: [{ id: "suricata.eve_fresh", status: "crit", detail: "stale" }] } } };
  assert.equal(topology(crit).find((s) => s.id === "eve").level, "crit");
  const none = { ...full, status: { ...full.status, health: { checks: [] } } };
  assert.equal(topology(none).some((s) => s.id === "eve"), false);
});

test("a component that is not installed is not drawn", () => {
  const status = { components: [comp("suricata", "active"), comp("evebox", "absent")] };
  const ids = topology({ status, system: null, mode: null }).map((s) => s.id);
  assert.deepEqual(ids, ["suricata"]);
});

test("a missing source is left out, never shown as healthy", () => {
  assert.deepEqual(topology({ status: null, system: null, mode: null }), []);
});

test("levels: running is ok, failed is crit, stopped is a warning only when it starts on boot", () => {
  assert.equal(levelOf(comp("x", "active")), "ok");
  assert.equal(levelOf(comp("x", "failed")), "crit");
  assert.equal(levelOf(comp("x", "inactive", true)), "warn");
  assert.equal(levelOf(comp("x", "inactive", false)), "na");
  assert.equal(levelOf(undefined), "na");
});

test("the other parts are the installed ones outside the chain, with no link claimed", () => {
  assert.deepEqual(others(full.status).map((p) => [p.id, p.level]), [["ntopng", "warn"], ["redis", "ok"]]);
});

function areas() {
  const node = () => ({ textContent: "", hidden: false, replaceChildren() {} });
  return { error: node(), topology: node(), others: node(), ifaces: node() };
}

test("a failing source does not sign out and the others still draw", async () => {
  globalThis.document = { createElement: () => ({ className: "", dataset: {}, append() {}, setAttribute() {}, textContent: "" }) };
  const a = areas();
  const stop = start(
    async (path) => {
      if (path === "/api/mode") throw Object.assign(new Error("x"), { status: 503 });
      return path === "/api/status" ? full.status : full.system;
    },
    a,
    () => assert.fail("a 503 is not a sign out"),
  );
  await new Promise((r) => setTimeout(r, 10));
  stop();
  assert.equal(a.error.textContent, "");
});

test("a 401 is passed on", async () => {
  const a = areas();
  let out = 0;
  const stop = start(async () => { throw Object.assign(new Error("no"), { status: 401 }); }, a, () => out++);
  await new Promise((r) => setTimeout(r, 10));
  stop();
  assert.equal(out, 1);
});

test("both sources failing says the host state could not be read", async () => {
  globalThis.document = { createElement: () => ({ className: "", dataset: {}, append() {}, setAttribute() {}, textContent: "" }) };
  const a = areas();
  const stop = start(async () => { throw Object.assign(new Error("x"), { status: 500 }); }, a, () => {});
  await new Promise((r) => setTimeout(r, 10));
  stop();
  assert.match(a.error.textContent, /could not read/);
});

test("the page has the screen, its menu entry in Monitoring and the route", () => {
  const html = here("index.html");
  for (const id of ["view-network", "network-error", "network-topology", "network-others", "network-ifaces"]) assert.match(html, new RegExp(`id="${id}"`), id);
  const monitoring = html.match(/aria-label="Monitoring">[\s\S]*?<\/div>/)[0];
  assert.match(monitoring, /data-view="network"/);
  assert.match(here("app.js"), /"overview", "network"/);
});
