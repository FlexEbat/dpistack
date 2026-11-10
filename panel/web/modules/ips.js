// The IPS screen (slice 42): readiness, counters, drop rules and the latest
// blocked events, read from /api/ips, and a rule test that replays a sample
// capture offline. It never switches the mode: that is confirmed and counted
// down on Components. Only a 401 signs the user out.

import { headline, checkRows, counterRows, NO_COUNTERS, ruleLines, parseSids, requestedText, testSummary } from "./ips-model.js";

const POLL_MS = 5000;

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function badge(level, text) {
  return el("span", "badge " + (level || "na"), text || level || "na");
}

function table(head, rows) {
  const t = el("table");
  const tr = el("tr");
  for (const h of head) tr.append(el("th", "", h));
  t.append(tr);
  for (const r of rows) {
    const row = el("tr");
    for (const c of r) row.append(c !== null && typeof c === "object" ? c : el("td", "", String(c)));
    t.append(row);
  }
  return t;
}

export function render(st, areas) {
  const h = headline(st);
  const top = el("p", "ips-headline");
  top.append(badge(h.level, h.level === "crit" ? "fail" : h.level), el("span", "", " " + h.text));
  areas.summary.replaceChildren(top);

  const checks = checkRows(st);
  areas.checks.replaceChildren(
    checks.length
      ? table(["Check", "State", "Detail"], checks.map((c) => [c.title, wrap(badge(c.level, c.state)), c.text]))
      : el("p", "muted empty", "No checks reported."),
  );

  const counters = counterRows(st);
  areas.counters.replaceChildren(counters.length ? table(["Counter", "Packets"], counters.map((c) => [c.title, c.value])) : el("p", "muted empty", NO_COUNTERS));

  areas.rules.replaceChildren(...ruleLines(st).map((l) => el("p", "", l)));

  const blocked = (st && st.blocked) || [];
  areas.blocked.replaceChildren(
    blocked.length
      ? table(["Time", "From", "To", "Proto", "Rule"], blocked.map((b) => [b.time, b.src || "", b.dest || "", b.proto || "", `${b.sid} ${b.msg}`]))
      : el("p", "muted empty", "No blocked events in the recent log."),
  );
}

function wrap(node) {
  const td = el("td");
  td.append(node);
  return td;
}

export function renderTest(res, area) {
  const parts = [el("p", "", testSummary(res))];
  if (res && res.ran) {
    if ((res.requested || []).length) {
      parts.push(table(["Rule", "Result"], res.requested.map((r) => [String(r.sid), requestedText(r)])));
    }
    if ((res.matched || []).length) {
      parts.push(table(["Rule", "Result", "Message"], res.matched.map((m) => [String(m.sid), m.would_drop ? "would drop" : "alert only", m.msg || ""])));
    }
  }
  area.replaceChildren(...parts);
}

export function start(api, areas, onError) {
  let running = true;
  let timer = null;
  let busy = false;
  let testing = false;

  function fail(err) {
    if (err.status === 401) return onError(err);
    areas.error.textContent = err.message;
  }

  async function once() {
    if (busy) return;
    busy = true;
    try {
      const st = await api("/api/ips");
      if (!running) return;
      areas.error.textContent = "";
      render(st, areas);
    } catch (err) {
      if (running) fail(err);
    } finally {
      busy = false;
    }
  }

  async function run() {
    if (testing) return;
    const parsed = parseSids(areas.sids.value);
    if (parsed.error) {
      areas.note.textContent = parsed.error;
      return;
    }
    testing = true;
    areas.run.disabled = true;
    areas.note.textContent = "Running the test: the rule set is loaded once, this can take a minute.";
    try {
      const body = { pcap: "bittorrent" };
      if (parsed.sids.length) body.sids = parsed.sids;
      const res = await api("/api/ips/test", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) });
      if (!running) return;
      areas.note.textContent = "";
      renderTest(res, areas.result);
    } catch (err) {
      if (running) {
        areas.note.textContent = "";
        fail(err);
      }
    } finally {
      testing = false;
      areas.run.disabled = false;
    }
  }

  areas.run.addEventListener("click", run);
  once();
  timer = setInterval(once, POLL_MS);
  return () => {
    running = false;
    areas.run.removeEventListener("click", run);
    if (timer !== null) clearInterval(timer);
  };
}
