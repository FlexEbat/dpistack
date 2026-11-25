// The History screen. It shows the daily or weekly roll-up that the watchdog
// keeps (HISTORY_ENABLE) and the devices that were seen. Only a 401 signs the
// user out.

import { dateProblem, reportSummary, appRows, deviceRows, alertRows, newDeviceText, knownRows, historyOff } from "./history-model.js";

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function table(head, rows) {
  const t = el("table");
  const tr = el("tr");
  for (const h of head) tr.append(el("th", "", h));
  t.append(tr);
  for (const r of rows) {
    const row = el("tr");
    for (const c of r) row.append(el("td", "", String(c)));
    t.append(row);
  }
  return t;
}

function section(title, rows, head, empty) {
  const box = el("div");
  box.append(el("h3", "", title));
  box.append(rows.length ? table(head, rows) : el("p", "muted empty", empty));
  return box;
}

export function renderReport(res, area) {
  const parts = [el("p", "muted", reportSummary(res))];
  if ((res.days || []).length) {
    parts.push(section("Applications", appRows(res), ["Application", "Flows", "Traffic"], "No application."));
    parts.push(section("Devices", deviceRows(res), ["Address", "Flows", "Traffic", "Mostly"], "No device."));
    parts.push(section("Alerts", alertRows(res), ["Rule", "Times", "Severity", "Message"], "No alert in this period."));
    parts.push(el("p", "muted", newDeviceText(res)));
  }
  area.replaceChildren(...parts);
}

export function start(api, areas, onError) {
  let running = true;

  async function load() {
    const problem = dateProblem(areas.date.value);
    if (problem) {
      areas.message.textContent = problem;
      return;
    }
    areas.message.textContent = "Loading.";
    const q = new URLSearchParams({ kind: areas.kind.value });
    if (areas.date.value.trim()) q.set("date", areas.date.value.trim());
    try {
      const [res, devices] = await Promise.all([api("/api/history/report?" + q), api("/api/history/devices")]);
      if (!running) return;
      areas.message.textContent = "";
      renderReport(res, areas.report);
      const rows = knownRows(devices);
      const none = historyOff(res) ? "No device recorded: history is off." : "No device recorded yet. A device appears when Suricata sees its traffic.";
      areas.known.replaceChildren(section("Devices ever seen", rows, ["Address", "First seen", "Last seen"], none));
      if (historyOff(res)) {
        const go = el("button", "", "Open Settings");
        go.type = "button";
        go.addEventListener("click", () => {
          const nav = document.querySelector('[data-view="settings"]');
          if (nav) nav.click();
        });
        areas.report.append(go);
      }
    } catch (err) {
      if (!running) return;
      if (err.status === 401) return onError(err);
      areas.message.textContent = err.message;
    }
  }

  const onLoad = () => load();
  areas.load.addEventListener("click", onLoad);
  load();
  return () => {
    running = false;
    areas.load.removeEventListener("click", onLoad);
  };
}
