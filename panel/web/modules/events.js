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
  return Number.isNaN(d.getTime()) ? iso : d.toLocaleString("ru-RU");
}

export function start(api, els, onError) {
  let source = null;
  let running = true;

  function stopFollow() {
    source?.close();
    source = null;
    els.follow.textContent = "Follow";
  }

  function row(ev) {
    const tr = el("tr");
    tr.append(el("td", "", when(ev.time)), el("td", "", ev.type));
    const td = el("td");
    const details = el("details");
    details.append(el("summary", "", summarize(ev.type, ev.event) || "(no description)"));
    details.append(el("pre", "log", JSON.stringify(ev.event, null, 2)));
    td.append(details);
    tr.append(td);
    return tr;
  }

  function table() {
    let t = els.list.querySelector("table");
    if (!t) {
      t = el("table");
      const head = el("tr");
      for (const h of ["Time", "Type", "Event"]) head.append(el("th", "", h));
      t.append(head);
      els.list.replaceChildren(t);
    }
    return t;
  }

  function note(text) {
    els.list.replaceChildren(el("p", "muted", text));
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
      if (res.events.length === 0) {
        note("No events match this query.");
        return true;
      }
      const t = el("table");
      const head = el("tr");
      for (const h of ["Time", "Type", "Event"]) head.append(el("th", "", h));
      t.append(head, ...res.events.map(row));
      els.list.replaceChildren(t);
      return true;
    } catch (err) {
      if (err.status === 401) onError(err);
      else els.error.textContent = err.message;
      return false;
    }
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
      // The stream filters by type only; the text filter is applied here.
      if (text && !JSON.stringify(ev.event).toLowerCase().includes(text)) return;
      const t = table();
      t.insertBefore(row(ev), t.rows[1] || null);
      while (t.rows.length > MAX_ROWS + 1) t.deleteRow(-1);
    };
    source.addEventListener("error", (event) => {
      els.error.textContent = event.data || "The event stream connection was lost";
      stopFollow();
    });
  }

  els.show.onclick = load;
  els.follow.onclick = follow;
  els.type.onchange = load;
  els.q.onkeydown = (event) => {
    if (event.key === "Enter") load();
  };

  load();
  return () => {
    running = false;
    stopFollow();
  };
}
