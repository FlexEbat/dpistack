import { fromEvent, setDraft } from "./exceptions-model.js";
import { activeFilters, exportName, filterEvents, groupBy, related, since, sidHistory, toCSV, toJSON } from "./events-model.js";

// The Events screen: the newest events of eve.json by type, a text filter,
// and a live tail (SSE) that adds only new events of the chosen type.

const MAX_ROWS = 500; // the most the screen keeps, as much as the server gives

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function option(value, text) {
  const o = document.createElement("option");
  o.value = value;
  o.textContent = text;
  return o;
}

const endpoint = (e) => (e.src_ip ? `${e.src_ip}${e.src_port ? ":" + e.src_port : ""}` : "") +
  (e.dest_ip ? ` → ${e.dest_ip}${e.dest_port ? ":" + e.dest_port : ""}` : "");

// summarize is the one line shown for an event; the whole event is one click
// away. Fields are read defensively: eve.json differs between versions.
export function summarize(type, e) {
  const where = endpoint(e);
  switch (type) {
    case "alert": {
      const a = e.alert || {};
      return [a.signature, a.severity ? `(severity ${a.severity})` : "", where, e.proto].filter(Boolean).join(" ");
    }
    case "dns": {
      const d = e.dns || {};
      return [d.type, d.rrname, d.rrtype, where].filter(Boolean).join(" ");
    }
    case "tls":
      return [e.tls?.sni, e.tls?.version, where].filter(Boolean).join(" ");
    case "http":
      return [e.http?.http_method, e.http?.hostname, e.http?.url, where].filter(Boolean).join(" ");
    case "flow":
    case "netflow":
      return [where, e.proto, e.app_proto].filter(Boolean).join(" ");
    default:
      return where || JSON.stringify(e).slice(0, 120);
  }
}

function when(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? iso : d.toLocaleString("en-GB");
}

export function start(api, els, onError) {
  let source = null;
  let running = true;
  let loaded = []; // the events of the last load, newest first
  let timer = null;

  function stopFollow() {
    source?.close();
    source = null;
    els.follow.textContent = "Follow";
  }

  const filters = () => ({
    ip: els.ip.value,
    sid: els.sid.value,
    category: els.category.value,
    proto: els.proto.value,
    severity: els.severity.value,
    domain: els.domain.value,
  });

  function note(text) {
    els.list.replaceChildren(el("p", "muted", text));
    els.status.textContent = "";
  }

  // inline puts a small block under an event: its related events, the history
  // of its rule. It is replaced when asked again.
  function inline(details, name, lines) {
    details.querySelector(`[data-inline="${name}"]`)?.remove();
    const box = el("div", "muted");
    box.dataset.inline = name;
    for (const l of lines) box.append(el("div", "", l));
    details.append(box);
  }

  async function showRelated(ev, details) {
    const id = ev.event && ev.event.flow_id;
    if (id === undefined || id === null) {
      inline(details, "related", ["This event has no flow id, so there is no flow to follow."]);
      return;
    }
    try {
      // The server finds the lines holding the id; the events already on the
      // screen are added, because a very large id loses digits in the browser.
      const res = await api(`/api/eve?limit=500&q=${encodeURIComponent(String(id))}`);
      const seen = new Set();
      const merged = [...(res.events || []), ...loaded].filter((x) => {
        const k = `${x.time}|${x.type}|${JSON.stringify(x.event)}`;
        return seen.has(k) ? false : (seen.add(k), true);
      });
      const rel = related(merged, id);
      inline(details, "related", rel.length ? [`${rel.length} events of flow ${id}, oldest first:`, ...rel.map((x) => `${when(x.time)}  ${x.type}  ${summarize(x.type, x.event)}`)] : ["No other events of this flow in the newest events."]);
    } catch (err) {
      if (err.status === 401) onError(err);
      else els.error.textContent = err.message;
    }
  }

  async function showHistory(ev, details) {
    const sid = ev.event.alert.signature_id;
    try {
      const res = await api(`/api/eve?type=alert&limit=500&q=${encodeURIComponent(String(sid))}`);
      const h = sidHistory(res.events || [], sid);
      const list = (xs) => xs.map((x) => `${x.value} (${x.count})`).join(", ") || "none";
      inline(details, "history", [
        `Rule ${h.sid}${h.signature ? ": " + h.signature : ""}`,
        `${h.count} alerts in the newest events, first ${when(h.first)}, last ${when(h.last)}.`,
        `Most often from: ${list(h.sources)}`,
        `Most often to: ${list(h.destinations)}`,
      ]);
    } catch (err) {
      if (err.status === 401) onError(err);
      else els.error.textContent = err.message;
    }
  }

  function row(ev) {
    const tr = el("tr");
    tr.append(el("td", "", when(ev.time)), el("td", "", ev.type));
    const td = el("td");
    const details = el("details");
    details.append(el("summary", "", summarize(ev.type, ev.event) || "(no description)"));
    details.append(el("pre", "log", JSON.stringify(ev.event, null, 2)));
    const actions = el("div", "toolbar");
    const add = (label, fn) => {
      const b = el("button", "", label);
      b.type = "button";
      b.addEventListener("click", fn);
      actions.append(b);
    };
    if (ev.event && ev.event.flow_id !== undefined) add("Related events", () => showRelated(ev, details));
    if (ev.event && ev.event.alert && Number.isInteger(ev.event.alert.signature_id)) add("History of this rule", () => showHistory(ev, details));
    // An alert has a rule number, so an exception can start from it: the
    // Exceptions screen opens with the rule and the source address filled in.
    if (fromEvent(ev)) {
      add("Create exception", () => {
        setDraft(fromEvent(ev));
        location.hash = "#exceptions";
      });
    }
    details.append(actions);
    td.append(details);
    tr.append(td);
    return tr;
  }

  function renderGroups(events, by) {
    const groups = groupBy(events, by);
    if (!groups.length) {
      els.list.replaceChildren(el("p", "muted empty", "Nothing to group here: this grouping needs alerts or addresses in the loaded events."));
      return;
    }
    const t = el("table");
    const head = el("tr");
    for (const h of ["Group", "Events", "Worst severity", "Last seen"]) head.append(el("th", "", h));
    t.append(head);
    for (const g of groups.slice(0, 200)) {
      const tr = el("tr");
      tr.className = "clickable";
      tr.tabIndex = 0;
      const open = () => {
        // A click on a group filters by it and shows its events.
        els[g.field === "sid" ? "sid" : g.field === "category" ? "category" : "ip"].value = g.value;
        els.group.value = "";
        render();
      };
      tr.addEventListener("click", open);
      tr.addEventListener("keydown", (e) => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          open();
        }
      });
      tr.append(el("td", "", g.key), el("td", "", String(g.count)), el("td", "", g.severity ? String(g.severity) : ""), el("td", "", when(g.last)));
      t.append(tr);
    }
    els.list.replaceChildren(t);
  }

  function shownEvents() {
    return filterEvents(loaded, filters());
  }

  function render() {
    const shown = shownEvents();
    const n = activeFilters(filters());
    els.status.textContent = `Showing ${shown.length} of ${loaded.length} loaded events` + (n ? `, ${n} ${n === 1 ? "filter" : "filters"} on the loaded events` : "") + ".";
    if (!loaded.length) return;
    if (!shown.length) {
      els.list.replaceChildren(el("p", "muted empty", "No loaded event passes these filters. They work on the newest events that were loaded; raise Show or widen the time."));
      return;
    }
    if (els.group.value) return renderGroups(shown, els.group.value);
    const t = el("table");
    const head = el("tr");
    for (const h of ["Time", "Type", "Event"]) head.append(el("th", "", h));
    t.append(head, ...shown.slice(0, MAX_ROWS).map(row));
    els.list.replaceChildren(t);
  }

  function fillTypes(types) {
    const chosen = els.type.value;
    const names = [...new Set(["alert", ...types])].sort();
    els.type.replaceChildren(option("", "All types"), ...names.map((n) => option(n, n)));
    els.type.value = names.includes(chosen) || chosen === "" ? chosen : "alert";
  }

  async function load() {
    stopFollow();
    els.error.textContent = "";
    const query = new URLSearchParams({ limit: els.limit.value });
    if (els.type.value) query.set("type", els.type.value);
    if (els.q.value.trim()) query.set("q", els.q.value.trim());
    const from = since(els.range.value);
    if (from) query.set("since", from);
    try {
      const res = await api(`/api/eve?${query}`);
      if (!running) return false;
      if (!res.available) {
        // The viewer is switched off: say so instead of showing an empty list.
        note(res.reason || "Event view is unavailable.");
        els.show.disabled = els.follow.disabled = true;
        return false;
      }
      fillTypes(res.types);
      if (!res.file_present) {
        note("eve.json does not exist yet: Suricata has not created it.");
        return true;
      }
      loaded = res.events;
      if (res.events.length === 0) {
        note("No events match this query.");
        return true;
      }
      render();
      return true;
    } catch (err) {
      if (err.status === 401) onError(err);
      else els.error.textContent = err.message;
      return false;
    }
  }

  function download(kind, ext, mime, text) {
    const blob = new Blob([text], { type: mime });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = exportName(kind, ext);
    document.body.append(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  }

  function exportAs(ext) {
    const shown = shownEvents();
    if (!shown.length) {
      els.error.textContent = "There is nothing to export: no loaded event passes the filters.";
      return;
    }
    els.error.textContent = "";
    if (ext === "csv") download("events", "csv", "text/csv;charset=utf-8", toCSV(shown));
    else download("events", "json", "application/json", toJSON(shown));
  }

  async function follow() {
    if (source) return stopFollow();
    if (!(await load())) return;
    const text = els.q.value.trim().toLowerCase();
    const query = els.type.value ? `?type=${encodeURIComponent(els.type.value)}` : "";
    source = new EventSource(`/api/eve/stream${query}`);
    els.follow.textContent = "Stop following";
    source.onmessage = (message) => {
      let ev;
      try {
        ev = JSON.parse(message.data);
      } catch {
        return;
      }
      // The stream filters by type only; the text filter is applied here and
      // the others by render().
      if (text && !JSON.stringify(ev.event).toLowerCase().includes(text)) return;
      loaded.unshift(ev);
      if (loaded.length > MAX_ROWS) loaded.length = MAX_ROWS;
      // Many events in a burst draw once.
      if (timer === null) {
        timer = setTimeout(() => {
          timer = null;
          if (running) render();
        }, 300);
      }
    };
    source.addEventListener("error", (event) => {
      els.error.textContent = event.data || "The event stream connection was lost";
      stopFollow();
    });
  }

  const onFilter = () => render();
  const filterEls = [els.ip, els.sid, els.category, els.proto, els.severity, els.domain, els.group];
  for (const f of filterEls) f.addEventListener("input", onFilter);
  const onJSON = () => exportAs("json");
  const onCSV = () => exportAs("csv");
  els.exportJSON.addEventListener("click", onJSON);
  els.exportCSV.addEventListener("click", onCSV);
  els.show.onclick = load;
  els.follow.onclick = follow;
  els.type.onchange = load;
  els.range.onchange = load;
  els.q.onkeydown = (event) => {
    if (event.key === "Enter") load();
  };

  load();
  return () => {
    running = false;
    stopFollow();
    if (timer !== null) clearTimeout(timer);
    for (const f of filterEls) f.removeEventListener("input", onFilter);
    els.exportJSON.removeEventListener("click", onJSON);
    els.exportCSV.removeEventListener("click", onCSV);
  };
}
