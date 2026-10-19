// Tests of the mode block (panel/web/modules/mode.js): the countdown, the
// confirm() dialogs and the buttons. No browser and no packages: node's own
// test runner, mock timers and plain objects for the elements the module
// touches (it only reads and sets properties on them).
import { test, mock, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { start } from "../modules/mode.js";

let calls;
let responses;
let confirmAnswer;
let confirmTexts;
let stop;

function el() {
  return { textContent: "", disabled: false, hidden: false, dataset: {}, onclick: null };
}

function makeEls() {
  const els = { error: el(), status: el(), message: el(), ips: el(), ids: el(), confirm: el() };
  els.confirm.hidden = true;
  return els;
}

// api answers from the queue `responses` (a value, or a function), and
// remembers every call.
function api(path, opts) {
  calls.push({ path, method: opts?.method || "GET", body: opts?.body ? JSON.parse(opts.body) : null });
  const next = responses.length > 1 ? responses.shift() : responses[0];
  const r = typeof next === "function" ? next(path, opts) : next;
  if (r instanceof Error) return Promise.reject(r);
  return Promise.resolve(r);
}

// settle lets pending promise callbacks run.
async function settle() {
  for (let i = 0; i < 10; i++) await Promise.resolve();
}

beforeEach(() => {
  calls = [];
  responses = [];
  confirmAnswer = true;
  confirmTexts = [];
  globalThis.confirm = (t) => {
    confirmTexts.push(t);
    return confirmAnswer;
  };
  mock.timers.enable({ apis: ["setInterval", "setTimeout"] });
});

afterEach(() => {
  if (stop) stop();
  stop = null;
  mock.timers.reset();
});

const ids = { mode: "ids", method: "nfq", pending: false, remaining_sec: 0 };
const pending = (n) => ({ mode: "ips", method: "nfq", pending: true, remaining_sec: n });

test("idle IDS: IPS button on, IDS button off, no confirm button", async () => {
  responses = [ids];
  const els = makeEls();
  stop = start(api, els, () => {});
  await settle();
  assert.equal(els.status.textContent, "Режим: IDS");
  assert.equal(els.ips.disabled, false);
  assert.equal(els.ids.disabled, true);
  assert.equal(els.confirm.hidden, true);
});

test("pending switch: the countdown goes down once a second and shows the confirm button", async () => {
  responses = [pending(10)];
  const els = makeEls();
  stop = start(api, els, () => {});
  await settle();
  assert.equal(els.confirm.hidden, false);
  assert.match(els.message.textContent, /через 10 с/);
  mock.timers.tick(3000);
  assert.match(els.message.textContent, /через 7 с/);
});

test("at zero the countdown stops and the server is asked after 3 s what became of the switch", async () => {
  responses = [pending(2), ids];
  const els = makeEls();
  stop = start(api, els, () => {});
  await settle();
  mock.timers.tick(2000);
  assert.match(els.message.textContent, /через 0 с/);
  const before = calls.length;
  mock.timers.tick(2900);
  assert.equal(calls.length, before, "no request before the 3 s pass");
  mock.timers.tick(200);
  await settle();
  assert.equal(calls.length, before + 1);
  assert.equal(els.confirm.hidden, true, "rolled back: no confirm button");
  assert.equal(els.status.textContent, "Режим: IDS");
  assert.equal(els.message.textContent, "");
  // and the countdown does not keep running
  const n = calls.length;
  mock.timers.tick(60000);
  await settle();
  assert.equal(calls.length > n, true, "the idle poller still asks");
  assert.equal(els.message.textContent, "");
});

test("the server is late: still pending at zero, the screen keeps asking and does not go negative", async () => {
  responses = [pending(1), pending(0)];
  const els = makeEls();
  stop = start(api, els, () => {});
  await settle();
  mock.timers.tick(1000);
  mock.timers.tick(3100);
  await settle();
  assert.equal(els.confirm.hidden, false);
  assert.match(els.message.textContent, /через 0 с/);
  mock.timers.tick(1100);
  assert.match(els.message.textContent, /через 0 с/);
});

test("IPS button: a refused confirm() sends nothing", async () => {
  responses = [ids];
  const els = makeEls();
  stop = start(api, els, () => {});
  await settle();
  confirmAnswer = false;
  els.ips.onclick();
  await settle();
  assert.equal(confirmTexts.length, 1);
  assert.match(confirmTexts[0], /Включить IPS/);
  assert.equal(calls.filter((c) => c.method === "POST").length, 0);
});

test("IPS button: an accepted confirm() posts acknowledged:true and starts the countdown from the answer", async () => {
  responses = [ids, { ok: true, output: "режим ips включён", mode: pending(120) }];
  const els = makeEls();
  stop = start(api, els, () => {});
  await settle();
  els.ips.onclick();
  await settle();
  const post = calls.find((c) => c.method === "POST");
  assert.equal(post.path, "/api/mode");
  assert.deepEqual(post.body, { mode: "ips", acknowledged: true });
  assert.equal(els.confirm.hidden, false);
  mock.timers.tick(5000);
  assert.match(els.confirm.hidden ? "" : els.message.textContent, /через 115 с/);
});

test("while a switch is applied the buttons are disabled, afterwards they are back", async () => {
  let release;
  responses = [
    ids,
    () =>
      new Promise((res) => {
        release = () => res({ ok: true, output: "", mode: pending(60) });
      }),
  ];
  const els = makeEls();
  stop = start(api, els, () => {});
  await settle();
  els.ips.onclick();
  await settle();
  assert.equal(els.ips.disabled, true);
  assert.equal(els.confirm.disabled, true);
  release();
  await settle();
  assert.equal(els.confirm.disabled, false);
});

test("Confirm IPS posts to /api/mode/confirm and the countdown ends", async () => {
  const confirmed = { mode: "ips", method: "nfq", pending: false, remaining_sec: 0 };
  let done = false;
  responses = [
    (path) => {
      if (path === "/api/mode/confirm") {
        done = true;
        return { ok: true, output: "режим ips подтверждён", mode: confirmed };
      }
      return done ? confirmed : pending(30);
    },
  ];
  const els = makeEls();
  stop = start(api, els, () => {});
  await settle();
  els.confirm.onclick();
  await settle();
  assert.equal(calls.at(-1).path, "/api/mode/confirm");
  assert.equal(els.confirm.hidden, true);
  mock.timers.tick(30000); // no countdown any more, only the 5 s poller asks
  await settle();
  assert.equal(els.status.textContent, "Режим: IPS (метод nfq)");
  assert.equal(els.confirm.hidden, true);
  assert.doesNotMatch(els.message.textContent, /через/);
});

test("IDS button asks for confirmation too and posts ids without acknowledged", async () => {
  responses = [{ mode: "ips", method: "nfq", pending: false, remaining_sec: 0 }, { ok: true, output: "", mode: ids }];
  const els = makeEls();
  stop = start(api, els, () => {});
  await settle();
  assert.equal(els.ids.disabled, false);
  els.ids.onclick();
  await settle();
  assert.match(confirmTexts[0], /Вернуть режим IDS/);
  assert.deepEqual(calls.find((c) => c.method === "POST").body, { mode: "ids" });
});

test("an error of the server is shown, the real mode is read again and the error stays", async () => {
  const boom = Object.assign(new Error("режим уже переключается"), { status: 409 });
  responses = [(_path, opts) => (opts?.method === "POST" ? boom : ids)];
  const els = makeEls();
  stop = start(api, els, () => {});
  await settle();
  els.ips.onclick();
  await settle();
  assert.equal(calls.at(-1).path, "/api/mode", "the mode was read again");
  assert.equal(calls.at(-1).method, "GET");
  assert.equal(els.error.textContent, "режим уже переключается");
});

test("401 goes to the login handler, not to the screen", async () => {
  const unauth = Object.assign(new Error("нужен вход"), { status: 401 });
  responses = [unauth];
  let got = null;
  const els = makeEls();
  stop = start(api, els, (e) => {
    got = e;
  });
  await settle();
  assert.equal(got, unauth);
  assert.equal(els.error.textContent, "");
});

test("stopping the screen stops the countdown and the poller", async () => {
  responses = [pending(50)];
  const els = makeEls();
  stop = start(api, els, () => {});
  await settle();
  stop();
  stop = null;
  const n = calls.length;
  mock.timers.tick(120000);
  await settle();
  assert.equal(calls.length, n);
});
