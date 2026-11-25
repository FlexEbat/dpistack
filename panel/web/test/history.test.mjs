import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dateProblem, formatBytes, reportSummary, appRows, deviceRows, alertRows, newDeviceText, knownRows } from "../modules/history-model.js";

const here = (f) => readFileSync(new URL("../" + f, import.meta.url), "utf8");

const RES = {
  label: "weekly", from: "2026-11-14", to: "2026-11-20", days: ["2026-11-19", "2026-11-20"], flows: 5, bytes: 12000,
  apps: [{ app: "tls", flows: 3, bytes: 10500 }],
  devices: [{ ip: "10.0.0.5", flows: 4, bytes: 11000, top_app: "tls" }, { ip: "192.168.1.20", flows: 1, bytes: 1000 }],
  alerts: [{ sid: 2000001, count: 3, severity: 2, msg: "ET P2P BitTorrent" }],
  new_devices: ["192.168.1.20"],
};

test("a day is checked before it is sent: empty means today", () => {
  assert.equal(dateProblem(""), "");
  assert.equal(dateProblem(" 2026-11-20 "), "");
  assert.match(dateProblem("yesterday"), /2026-11-20/);
  assert.match(dateProblem("2026-13-40"), /2026-11-20/);
  assert.match(dateProblem("20261120"), /2026-11-20/);
});

test("sizes are in the unit that fits", () => {
  assert.equal(formatBytes(0), "0 B");
  assert.equal(formatBytes(1536), "1.5 KiB");
  assert.equal(formatBytes(5 * 1048576), "5.0 MiB");
  assert.equal(formatBytes(3 * 1073741824), "3.0 GiB");
  assert.equal(formatBytes(undefined), "0 B");
});

test("the summary says the period, the totals and the days with data, or why there is nothing", () => {
  assert.equal(reportSummary(RES), "Week 2026-11-14 to 2026-11-20: 5 flows, 11.7 KiB, 2 days with data.");
  assert.match(reportSummary({ label: "daily", from: "2026-01-01", to: "2026-01-01", days: [] }), /No history for 2026-01-01 to 2026-01-01 yet/);
  assert.equal(reportSummary(null), "");
});

test("the tables hold the rows of the report", () => {
  assert.deepEqual(appRows(RES), [["tls", "3", "10.3 KiB"]]);
  assert.deepEqual(deviceRows(RES), [["10.0.0.5", "4", "10.7 KiB", "tls"], ["192.168.1.20", "1", "1000 B", ""]]);
  assert.deepEqual(alertRows(RES), [["2000001", "3", "2", "ET P2P BitTorrent"]]);
  assert.equal(newDeviceText(RES), "New devices in this period: 192.168.1.20");
  assert.equal(newDeviceText({ new_devices: [] }), "No new device in this period.");
  assert.deepEqual(knownRows([{ ip: "10.0.0.5", first: "2026-11-01", last: "2026-11-20" }]), [["10.0.0.5", "2026-11-01", "2026-11-20"]]);
  assert.deepEqual(knownRows(null), []);
});

test("the History view is in the menu, the view list and app.js, with its controls", () => {
  const html = here("index.html");
  assert.match(html, /data-view="history"/);
  assert.match(html, /<div id="view-history" hidden>/);
  for (const id of ["history-kind", "history-date", "history-load", "history-message", "history-report", "history-known"]) {
    assert.match(html, new RegExp(`id="${id}"`), id);
    assert.match(here("app.js"), new RegExp(`"${id}"`), id);
  }
  assert.match(here("app.js"), /"metrics", "history"/);
  assert.match(here("modules/history.js"), /"\/api\/history\/report\?"/);
  assert.match(here("modules/history.js"), /"\/api\/history\/devices"/);
});

import { historyOff } from "../modules/history-model.js";

test("when history is off the screen says so and does not claim it is waiting for traffic", () => {
  const off = { label: "daily", enabled: false, from: "2026-11-20", to: "2026-11-20", days: [] };
  assert.match(reportSummary(off), /History is off\. Turn on HISTORY_ENABLE/);
  assert.equal(historyOff(off), true);
  const on = { ...off, enabled: true };
  assert.match(reportSummary(on), /History is on/);
  assert.equal(historyOff(on), false);
  assert.equal(historyOff(null), false);
});
