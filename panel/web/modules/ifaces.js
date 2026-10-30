// The interfaces block of the Components screen: the interfaces Suricata
// listens on, with add and remove. Each change runs reconfigure on the
// server, which restarts Suricata, so it is confirmed first.

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

export function start(api, els, onError, onChanged) {
  let running = true;

  function fail(err) {
    if (err.status === 401) return onError(err);
    els.error.textContent = err.message;
  }

  // A request in flight blocks every button; when it ends, only the button
  // of the last interface stays blocked (data-last), because that one may
  // never be pressed.
  function setBusy(on) {
    for (const b of els.root.querySelectorAll("button")) b.disabled = on || b.dataset.last === "1";
  }

  function render(names) {
    if (names.length === 0) {
      els.list.replaceChildren(el("p", "muted empty", "No interfaces."));
      return;
    }
    const t = el("table");
    for (const name of names) {
      const tr = el("tr");
      tr.append(el("td", "", name));
      const td = el("td", "actions");
      const b = el("button", "", "Remove");
      b.type = "button";
      // The last interface cannot be removed; the server says so too.
      b.disabled = names.length === 1;
      if (names.length === 1) b.dataset.last = "1";
      b.title = names.length === 1 ? "The last interface cannot be removed" : "";
      b.addEventListener("click", () => change("remove", name));
      td.append(b);
      tr.append(td);
      t.append(tr);
    }
    els.list.replaceChildren(t);
  }

  // load reads the list. After a failed change the error stays on screen:
  // the reread is only there to show the list as the server has it.
  async function load(keepError) {
    try {
      const res = await api("/api/iface");
      if (!running) return;
      if (!keepError) els.error.textContent = "";
      render(res.ifaces);
    } catch (err) {
      fail(err);
    }
  }

  async function change(verb, name) {
    const what = verb === "add" ? `Add interface "${name}"` : `Remove interface "${name}"`;
    if (!confirm(`${what}? Suricata will be restarted.`)) return;
    els.error.textContent = "";
    els.message.textContent = "Applying, this may take a minute…";
    setBusy(true);
    try {
      const res = await api(`/api/iface/${verb}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name }),
      });
      els.message.textContent = res.output || "Done";
      if (res.ifaces) render(res.ifaces);
      else await load();
      if (verb === "add") els.name.value = "";
      if (onChanged) onChanged();
    } catch (err) {
      els.message.textContent = "";
      fail(err);
      await load(true); // the list as the server has it, which is the old one after a failure
    } finally {
      setBusy(false);
    }
  }

  els.add.onclick = () => {
    const name = els.name.value.trim();
    if (name === "") return;
    change("add", name);
  };
  load();
  return () => {
    running = false;
  };
}
