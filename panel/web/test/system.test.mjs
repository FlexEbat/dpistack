import { test } from "node:test";
import assert from "node:assert/strict";
import { humanBytes, uptimeText, usedPercent, level, statCards, ifaceRows } from "../modules/system.js";

test("bytes are shown in the unit that fits", () => {
  assert.equal(humanBytes(0), "0 B");
  assert.equal(humanBytes(1536), "1.5 KiB");
  assert.equal(humanBytes(5 * 1024 ** 3), "5.0 GiB");
  assert.equal(humanBytes(-1), "");
  assert.equal(humanBytes("x"), "");
});

test("uptime reads as days and hours, hours and minutes, or seconds", () => {
  assert.equal(uptimeText(40), "40 s");
  assert.equal(uptimeText(7500), "2 h 5 min");
  assert.equal(uptimeText(3 * 86400 + 4 * 3600 + 59), "3 d 4 h");
  assert.equal(uptimeText(-5), "");
});

test("used percent and the level of worry", () => {
  assert.equal(usedPercent(1000, 250), 75);
  assert.equal(usedPercent(0, 0), null);
  assert.equal(usedPercent(100, 200), null);
  assert.equal(level(null), "na");
  assert.equal(level(74), "ok");
  assert.equal(level(75), "warn");
  assert.equal(level(90), "crit");
});

test("cards: the first CPU sample says measuring, a missing source gives no card", () => {
  const info = { cpu: { cores: 4, percent: null }, load: [0.5, 0.4, 0.3], memory: { total_kb: 8000000, available_kb: 2000000, swap_total_kb: 0, swap_free_kb: 0 }, disks: [{ path: "/", total_bytes: 100, free_bytes: 5 }], uptime_seconds: 7500 };
  const cards = statCards(info);
  assert.deepEqual(cards.map((c) => c.label), ["CPU", "Load", "Memory", "Disk /", "Uptime"]);
  assert.equal(cards[0].value, "measuring");
  assert.equal(cards[2].value, "75 %");
  assert.equal(cards[2].level, "warn");
  assert.equal(cards[3].level, "crit");
  assert.deepEqual(statCards({}), []);
  assert.deepEqual(statCards({ memory: { total_kb: 0 } }), []);
});

test("interface rows add both directions of loss and mark the capture interface", () => {
  const rows = ifaceRows({ interfaces: [
    { name: "eth0", state: "up", speed_mbps: 1000, rx_bytes: 2048, tx_bytes: 0, rx_dropped: 3, tx_dropped: 4, rx_errors: 1, tx_errors: 0, capture: true },
    { name: "lo", state: "unknown", speed_mbps: null, virtual: true },
  ] });
  assert.equal(rows[0].speed, "1000 Mbit/s");
  assert.equal(rows[0].rx, "2.0 KiB");
  assert.equal(rows[0].lost, 7);
  assert.equal(rows[0].errors, 1);
  assert.equal(rows[0].capture, "capturing");
  assert.equal(rows[1].speed, "");
  assert.equal(rows[1].capture, "");
  assert.equal(rows[1].virtual, true);
});
