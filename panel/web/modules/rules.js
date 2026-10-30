// The Rules screen: sources, groups, single rules by sid, search, and the
// "update now" button with the result and time of the last update.

const WAIT_MS = 3000;
const WAIT_TRIES = 140; // a little over the 7 minutes the panel gives an update
const PENDING = "Changes take effect after the rules are updated: press \"Update now\".";

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function button(text, onclick) {
  const b = el("button", "", text);
  b.type = "button";
  b.addEventListener("click", onclick);
  return b;
}

const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// parseConf reads what the rules commands keep in enable.conf and
// disable.conf: "group:<name>" lines and plain sids. Comments and anything
// else the person wrote by hand are ignored here and left alone on disk.
export function parseConf(text) {
  const groups = [];
  const sids = [];
  for (const raw of String(text || "").split("\n")) {
    const line = raw.trim();
    if (line === "" || line.startsWith("#")) continue;
    if (line.startsWith("group:")) groups.push(line.slice("group:".length));
    else if (/^[0-9]+$/.test(line)) sids.push(line);
  }
  return { groups, sids };
}

function when(iso) {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? iso : d.toLocaleString("ru-RU");
}

export function start(api, els, onError) {
  let running = true;
  let disabled = new Set();
  let lastQuery = "";

  const post = (path, body) =>
    api(path, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  const conf = (name) => api(`/api/config/${name}`).then((r) => parseConf(r.content));

  function setBusy(on) {
    for (const b of els.root.querySelectorAll("button")) b.disabled = on;
  }

  function fail(err) {
    if (err.status === 401) return onError(err);
    els.error.textContent = err.message;
  }

  function note(text) {
    els.error.textContent = "";
    els.message.textContent = text || "";
  }

  function renderLast(last, updating) {
    if (updating) {
      els.last.textContent = "Updating rules…";
    } else if (!last) {
      els.last.textContent = "No update has been started from here since the panel started.";
    } else {
      els.last.textContent = `Last update: ${when(last.time)}, ${last.ok ? "succeeded" : "failed"}.`;
    }
    els.updateOutput.className = last && !last.ok ? "result error" : "result";
    els.updateOutput.textContent = last ? [last.error, last.output].filter(Boolean).join("\n") : "";
  }

  function renderSources(list) {
    const t = el("table");
    const head = el("tr");
    for (const h of ["Source", "Description", "State", "Actions"]) head.append(el("th", "", h));
    t.append(head);
    for (const s of list) {
      const tr = el("tr");
      const name = el("td", "", s.name);
      const about = s.custom ? "custom source (added by address)" : [s.vendor, s.summary].filter(Boolean).join(": ");
      tr.append(name, el("td", "", about), el("td", "", s.enabled ? "enabled" : "disabled"));
      const actions = el("td", "actions");
      const act = (action, text, ask) =>
        actions.append(
          button(text, async () => {
            if (ask && !confirm(ask)) return;
            await change(() => post("/api/rules/sources", { action, name: s.name }), `${text}: ${s.name}`);
          }),
        );
      act(s.enabled ? "disable" : "enable", s.enabled ? "Disable" : "Enable");
      if (s.custom) act("remove", "Remove", `Remove source "${s.name}"?`);
      tr.append(actions);
      t.append(tr);
    }
    els.sources.replaceChildren(t);
  }

  function renderGroups(groups) {
    if (groups.length === 0) {
      els.groups.replaceChildren(el("p", "muted empty", "No groups enabled by hand."));
      return;
    }
    const t = el("table");
    for (const g of groups) {
      const tr = el("tr");
      tr.append(el("td", "", g));
      const actions = el("td", "actions");
      actions.append(
        button("Disable", () =>
          change(() => post(`/api/rules/groups/${encodeURIComponent(g)}/disable`), `Group disabled: ${g}`),
        ),
      );
      tr.append(actions);
      t.append(tr);
    }
    els.groups.replaceChildren(t);
  }

  function renderDisabled(sids) {
    if (sids.length === 0) {
      els.disabled.replaceChildren(el("p", "muted empty", "No disabled rules."));
      return;
    }
    const t = el("table");
    for (const sid of sids) {
      const tr = el("tr");
      tr.append(el("td", "", sid));
      const actions = el("td", "actions");
      actions.append(button("Enable", () => toggleSID(sid, "enable")));
      tr.append(actions);
      t.append(tr);
    }
    els.disabled.replaceChildren(t);
  }

  function renderResults(res) {
    if (res.results.length === 0) {
      els.results.replaceChildren(el("p", "muted", "Nothing found."));
      return;
    }
    const t = el("table");
    const head = el("tr");
    for (const h of ["sid", "Rule", "Actions"]) head.append(el("th", "", h));
    t.append(head);
    for (const r of res.results) {
      const tr = el("tr");
      const off = disabled.has(r.sid);
      tr.append(el("td", "", r.sid), el("td", "", off ? `${r.msg} (disabled)` : r.msg));
      const actions = el("td", "actions");
      actions.append(button(off ? "Enable" : "Disable", () => toggleSID(r.sid, off ? "enable" : "disable")));
      tr.append(actions);
      t.append(tr);
    }
    const parts = [t];
    if (res.truncated) parts.push(el("p", "muted", "The first 50 rules are shown: narrow the query."));
    els.results.replaceChildren(...parts);
  }

  // refresh reads the three things the screen shows. The sources come from
  // suricata-update; groups and disabled sids are read from the two files
  // the rules commands edit, through the config API.
  async function refresh() {
    try {
      const [src, enable, disable] = await Promise.all([
        api("/api/rules/sources"),
        conf("enable.conf"),
        conf("disable.conf"),
      ]);
      if (!running) return;
      disabled = new Set(disable.sids);
      renderSources(src.sources);
      renderGroups(enable.groups);
      renderDisabled(disable.sids);
      renderLast(src.last_update, src.updating);
      if (src.updating) await waitIdle();
    } catch (err) {
      fail(err);
    }
  }

  // change runs one edit, says what happened, and rereads the lists. Every
  // edit takes effect with the next update, so the screen says so. It
  // returns whether the edit went through.
  async function change(request, okText) {
    setBusy(true);
    try {
      await request();
      note(`${okText}. ${PENDING}`);
      await refresh();
      if (lastQuery) await find(lastQuery);
      return true;
    } catch (err) {
      fail(err);
      return false;
    } finally {
      setBusy(false);
    }
  }

  function toggleSID(sid, verb) {
    return change(
      () => post(`/api/rules/sid/${sid}/${verb}`),
      verb === "disable" ? `Rule ${sid} disabled` : `Rule ${sid} enabled again`,
    );
  }

  async function find(q) {
    try {
      renderResults(await api(`/api/rules/search?q=${encodeURIComponent(q)}`));
      lastQuery = q; // only a query that worked is repeated after an edit
    } catch (err) {
      lastQuery = "";
      els.results.replaceChildren();
      fail(err);
    }
  }

  // waitIdle follows an update that outlived the browser's request: a proxy
  // may cut a long answer, but the panel finishes the update and keeps the
  // result.
  async function waitIdle() {
    for (let i = 0; i < WAIT_TRIES && running; i++) {
      await pause(WAIT_MS);
      if (!running) return;
      let src;
      try {
        src = await api("/api/rules/sources");
      } catch (err) {
        if (err.status === 401) return onError(err);
        continue;
      }
      renderLast(src.last_update, src.updating);
      if (!src.updating) return;
    }
  }

  async function update() {
    if (!confirm("Update the rules now? Downloading and checking can take a few minutes.")) return;
    note("");
    setBusy(true);
    els.last.textContent = "Updating rules…";
    els.updateOutput.className = "result";
    els.updateOutput.textContent = "";
    try {
      const res = await post("/api/rules/update");
      renderLast(res.last_update, false);
      note("Rules updated.");
    } catch (err) {
      if (err.status === 401) return onError(err);
      if (err.body && "output" in err.body) {
        // The update ran and failed; ctl put the previous ruleset back.
        els.error.textContent = "";
        note("");
        await refresh();
      } else if (err.status === 409 || err.status === 502 || err.status === 504 || err instanceof TypeError) {
        // Already running, or the answer was cut: the panel still holds the result.
        await waitIdle();
      } else {
        fail(err);
        await refresh();
      }
    } finally {
      setBusy(false);
    }
  }

  els.update.onclick = update;

  els.urlAdd.onclick = async () => {
    const url = els.url.value.trim();
    if (url === "") return;
    if (await change(() => post("/api/rules/sources", { action: "add-url", url }), "Source added")) els.url.value = "";
  };

  els.groupAdd.onclick = async () => {
    const group = els.group.value.trim();
    if (group === "") return;
    if (await change(() => post(`/api/rules/groups/${encodeURIComponent(group)}/enable`), `Group enabled: ${group}`)) {
      els.group.value = "";
    }
  };

  const doSearch = () => {
    const q = els.q.value.trim();
    note("");
    if (q === "") {
      lastQuery = "";
      els.results.replaceChildren();
      return;
    }
    find(q);
  };
  els.search.onclick = doSearch;
  els.q.onkeydown = (event) => {
    if (event.key === "Enter") doSearch();
  };

  note("");
  refresh();
  return () => {
    running = false;
  };
}
