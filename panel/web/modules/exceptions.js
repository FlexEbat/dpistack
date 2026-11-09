// The Exceptions screen (slice 40): what Suricata stays silent about or
// reports less often. Every action is one `dpistack exceptions` verb behind
// /api/exceptions, so the CLI and this screen are the same thing. The words
// and the checks are in exceptions-model.js.

import { defaultText, expiryText, formToBody, ordered, scopeText, summary, takeDraft } from "./exceptions-model.js";

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

export function start(api, els, onError) {
  let running = true;
  let list = null;

  const post = (path, body) =>
    api(path, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });

  function fail(err) {
    if (err.status === 401) return onError(err);
    // A refusal of the checker carries its words in body.output.
    const out = err.body && err.body.output ? "\n" + err.body.output : "";
    els.error.textContent = err.message + out;
    els.message.textContent = "";
  }

  // The form shows only the fields the chosen kind uses.
  function syncForm() {
    const limit = els.kind.value === "limit";
    const everyone = !limit && els.scope.value === "everyone";
    els.scopeBox.hidden = limit;
    els.sideBox.hidden = everyone;
    els.ipBox.hidden = limit || everyone;
    els.countBox.hidden = !limit;
    els.secondsBox.hidden = !limit;
    els.daysBox.hidden = els.expiry.value !== "days";
  }

  function readForm() {
    return {
      kind: els.kind.value,
      sid: els.sid.value,
      scope: els.scope.value,
      side: els.side.value,
      ip: els.ip.value,
      count: els.count.value,
      seconds: els.seconds.value,
      expiry: els.expiry.value,
      days: els.days.value,
      note: els.note.value,
    };
  }

  function fillForm(d) {
    els.kind.value = d.kind;
    els.sid.value = d.sid;
    els.scope.value = d.scope;
    els.side.value = d.side;
    els.ip.value = d.ip;
    els.expiry.value = d.expiry;
    els.note.value = d.note || "";
    els.message.textContent = d.signature ? `Rule ${d.sid}: ${d.signature}. Scope starts as the source address of the alert; change it if needed.` : "";
    syncForm();
  }

  async function add() {
    els.error.textContent = "";
    const checked = formToBody(readForm());
    if (checked.problem) {
      els.error.textContent = checked.problem;
      return;
    }
    if (checked.warnings.length && !confirm(checked.warnings.join("\n") + "\n\nAdd it?")) return;
    els.add.disabled = true;
    els.message.textContent = "Checking the file with Suricata and reloading...";
    try {
      const res = await post("/api/exceptions", checked.body);
      if (!running) return;
      els.message.textContent = `Added ${res.id}. Suricata reloaded.`;
      els.sid.value = "";
      els.note.value = "";
      await load();
    } catch (err) {
      fail(err);
    } finally {
      els.add.disabled = false;
    }
  }

  async function remove(entry) {
    if (!confirm(`Remove this exception?\n\nRule ${entry.sid}: ${scopeText(entry)}`)) return;
    els.error.textContent = "";
    try {
      await post("/api/exceptions/remove", { id: entry.id });
      if (!running) return;
      els.message.textContent = `Removed ${entry.id}.`;
      await load();
    } catch (err) {
      fail(err);
    }
  }

  function render() {
    els.summary.textContent = summary(list);
    els.hint.textContent = defaultText(list);
    const entries = ordered(list.entries);
    if (!entries.length) {
      els.list.replaceChildren();
      return;
    }
    const t = el("table");
    const head = el("tr");
    for (const h of ["Rule", "Applies to", "Expiry", "Added by", "Note", ""]) head.append(el("th", "", h));
    t.append(head);
    for (const e of entries) {
      const tr = el("tr");
      if (e.kind === "other") {
        tr.append(el("td", "", "not managed"), el("td", "", e.note), el("td", "", "never expires"), el("td", "", ""), el("td", "", "A line written by hand; edit it in Configs."), el("td"));
      } else {
        tr.append(
          el("td", "", `${e.sid} (${e.kind === "limit" ? "limit" : "silent"})`),
          el("td", "", scopeText(e)),
          el("td", "", expiryText(e)),
          el("td", "", e.by || ""),
          el("td", "", e.note || ""),
        );
        const td = el("td");
        const b = el("button", "", "Remove");
        b.type = "button";
        b.addEventListener("click", () => remove(e));
        td.append(b);
        tr.append(td);
      }
      t.append(tr);
    }
    els.list.replaceChildren(t);
  }

  async function load() {
    try {
      list = await api("/api/exceptions");
      if (!running) return;
      render();
    } catch (err) {
      fail(err);
    }
  }

  const onChange = () => syncForm();
  const onAdd = () => add();
  for (const k of ["kind", "scope", "expiry"]) els[k].addEventListener("change", onChange);
  els.add.addEventListener("click", onAdd);

  const d = takeDraft();
  if (d) fillForm(d);
  else {
    els.kind.value = "suppress";
    els.scope.value = "one";
    els.expiry.value = "default";
    syncForm();
  }
  load();
  return () => {
    running = false;
    for (const k of ["kind", "scope", "expiry"]) els[k].removeEventListener("change", onChange);
    els.add.removeEventListener("click", onAdd);
  };
}
