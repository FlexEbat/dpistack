// Polling screens: the newest request wins (panel/web/modules/poll.js).
// Two loads in flight must not show the older answer over the newer one and
// must not leave two poll loops running. node's own test runner, mock
// timers, and a fake document whose nodes accept any call.
import { test, mock, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { start as startMetrics } from "../modules/metrics.js";
import { start as startOverview } from "../modules/overview.js";

function node() {
  const own = { textContent: "", className: "", dataset: {}, style: {}, value: "", children: [] };
  return new Proxy(own, {
    get(t, k) {
      if (k in t) return t[k];
      if (k === "querySelectorAll") return () => [];
      if (k === Symbol.iterator) return undefined;
      return () => node();
    },
    set(t, k, v) {
      t[k] = v;
      return true;
    },
  });
}

let stop;
let listeners;

beforeEach(() => {
  listeners = [];
  globalThis.document = {
    hidden: false,
    createElement: () => node(),
    createElementNS: () => node(),
    addEventListener: (type, fn) => listeners.push([type, fn]),
    removeEventListener: () => {},
  };
  mock.timers.enable({ apis: ["setTimeout"] });
});

afterEach(() => {
  if (stop) stop();
  stop = null;
  mock.timers.reset();
  delete globalThis.document;
});

// deferred: a request the test answers when it wants to.
function deferred() {
  let resolve, reject;
  const promise = new Promise((res, rej) => ({ resolve, reject } = { resolve: res, reject: rej }));
  return { promise, resolve, reject };
}

async function settle() {
  for (let i = 0; i < 20; i++) await Promise.resolve();
}

test("metrics: the answer for the range clicked first does not overwrite the newer one", async () => {
  const pending = [];
  const api = () => {
    const d = deferred();
    pending.push(d);
    return d.promise;
  };
  const ranges = node();
  const button = { dataset: { range: "24h" }, setAttribute() {}, onclick: null };
  ranges.querySelectorAll = () => [button];
  const els = { charts: node(), error: node(), ranges };
  stop = startMetrics(api, els, () => {});
  await settle();
  assert.equal(pending.length, 1); // the first load, range 1h
  button.onclick(); // 24h clicked while 1h is still on its way
  await settle();
  assert.equal(pending.length, 2);
  pending[1].resolve({ series: {} }); // 24h answers first
  await settle();
  assert.equal(els.error.textContent, "");
  pending[0].reject(new Error("старый ответ 1h")); // then the late 1h one
  await settle();
  assert.equal(els.error.textContent, "", "the late answer for the old range showed its error");
});

test("overview: a load in flight when the tab comes back does not start a second poll loop", async () => {
  let calls = 0;
  const pending = [];
  const api = () => {
    calls++;
    const d = deferred();
    pending.push(d);
    return d.promise;
  };
  const els = { error: node() };
  const areas = new Proxy({ error: node() }, { get: (t, k) => (k in t ? t[k] : node()) });
  stop = startOverview(api, areas, () => {});
  await settle();
  assert.equal(calls, 1);
  // the tab becomes visible while the first load is still in flight
  for (const [type, fn] of listeners) if (type === "visibilitychange") fn();
  await settle();
  assert.equal(calls, 2);
  pending[0].resolve({ overall: "ok", components: [], checks: [] });
  pending[1].resolve({ overall: "ok", components: [], checks: [] });
  await settle();
  const before = calls;
  mock.timers.tick(10000);
  await settle();
  assert.equal(calls - before, 1, "two poll loops: every poll asked twice");
  assert.ok(els);
});
