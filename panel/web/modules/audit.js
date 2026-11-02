// The Audit screen (slice 35): who did what and when, with filters and an
// export. The panel decides who may read it (audit.view); the screen only
// shows what comes back.

// buildQuery turns the filters of the form into the query string of the API.
// Empty fields are left out, so the panel's own defaults apply.
export function buildQuery(f) {
  const q = new URLSearchParams();
  for (const k of ["user", "action", "result", "since", "until", "limit"]) {
    const v = String(f[k] ?? "").trim();
    if (v) q.set(k, v);
  }
  return q.toString();
}

export function exportUrl(f, format) {
  const q = new URLSearchParams(buildQuery(f));
  q.set("format", format);
  return "/api/audit/export?" + q.toString();
}

function cell(text, className) {
  const td = document.createElement("td");
  if (className) td.className = className;
  td.textContent = text ?? "";
  return td;
}

export function start(api, els, onError) {
  let running = true;

  const filters = () => ({
    user: els.user.value,
    action: els.action.value,
    result: els.result.value,
    since: els.since.value,
    limit: els.limit.value,
  });

  function links() {
    els.csv.href = exportUrl(filters(), "csv");
    els.json.href = exportUrl(filters(), "json");
  }

  async function load() {
    links();
    els.error.textContent = "";
    let res;
    try {
      res = await api("/api/audit?" + buildQuery(filters()));
    } catch (err) {
      if (err.status === 401) return onError(err);
      els.error.textContent = err.message;
      return;
    }
    if (!running) return;
    if (!res.enabled) {
      els.list.textContent = "The audit log is switched off (the panel runs without -audit-file).";
      return;
    }
    if (!res.entries.length) {
      els.list.textContent = "No entries match.";
      return;
    }
    const t = document.createElement("table");
    const head = document.createElement("tr");
    for (const h of ["Time", "User", "Address", "Action", "Target", "Result", "Detail"]) {
      const th = document.createElement("th");
      th.textContent = h;
      head.append(th);
    }
    t.append(head);
    for (const e of res.entries) {
      const tr = document.createElement("tr");
      tr.append(
        cell(e.ts.replace("T", " ").replace("Z", "")),
        cell(e.user),
        cell(e.ip),
        cell(e.action),
        cell(e.target),
        cell(e.result, "result-" + e.result),
        cell(e.detail),
      );
      t.append(tr);
    }
    els.list.replaceChildren(t);
  }

  els.form.onsubmit = (event) => {
    event.preventDefault();
    load();
  };
  load();
  return () => (running = false);
}
