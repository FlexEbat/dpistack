// The Settings screen: every key of dpistack.conf, from the schema the server
// reports, grouped, with hints. A change is checked before it is applied; a
// busy port shows its holder and offers a free one; a heavy change (a
// reinstall of a component) says so and runs as a job that the screen follows.

import { groupSettings, changedValues, localProblem, needsAccessConfirm, HINTS } from "./settings-model.js";

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

export function start(api, els, onError) {
  let running = true;
  let keys = [];
  let edits = {};
  let showAdvanced = false;
  let jobTimer = null;
  const fields = new Map(); // key -> {input, note}

  function fail(err) {
    if (err.status === 401) return onError(err);
    els.error.textContent = err.message;
  }

  function setBusy(on) {
    for (const b of els.root.querySelectorAll("button")) b.disabled = on;
  }

  function say(text, cls) {
    els.message.textContent = text;
    els.message.className = cls || "muted";
  }

  function makeInput(k) {
    let input;
    if (k.type === "enum") {
      input = el("select");
      for (const o of k.options) {
        const opt = el("option", "", o);
        opt.value = o;
        input.append(opt);
      }
    } else {
      input = el("input");
      input.type = k.type === "int" ? "number" : "text";
      if (k.type === "int") {
        if (k.min !== null) input.min = String(k.min);
        if (k.max !== null) input.max = String(k.max);
      }
      input.autocomplete = "off";
      input.spellcheck = false;
    }
    input.value = k.key in edits ? edits[k.key] : k.value;
    input.id = "set-" + k.key;
    input.addEventListener("input", () => {
      edits[k.key] = input.value;
      const note = fields.get(k.key).note;
      note.textContent = localProblem(k, input.value);
      note.className = "field-note bad";
      refreshDirty();
    });
    return input;
  }

  function secretRow(k) {
    const row = el("div", "secret-row");
    const input = el("input");
    input.type = "password";
    input.autocomplete = "new-password";
    input.placeholder = k.set ? "set; enter a new value to replace it" : "not set";
    input.id = "set-" + k.key;
    const save = el("button", "", "Save");
    save.type = "button";
    save.addEventListener("click", async () => {
      if (!input.value) return;
      await secret(k, input.value);
      input.value = "";
    });
    row.append(input, save);
    if (k.set) {
      const del = el("button", "", "Remove");
      del.type = "button";
      del.addEventListener("click", async () => {
        if (window.confirm("Remove the value of " + k.key + "?")) await secret(k, "");
      });
      row.append(del);
    }
    return { row, input };
  }

  async function secret(k, value) {
    els.error.textContent = "";
    setBusy(true);
    say("Applying…");
    try {
      await api("/api/settings/secret/" + encodeURIComponent(k.key), {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ value }),
      });
      say(value ? "Secret saved." : "Secret removed.");
      await load();
    } catch (err) {
      fail(err);
      say("");
    } finally {
      if (running) setBusy(false);
    }
  }

  function render() {
    fields.clear();
    const root = document.createDocumentFragment();
    for (const g of groupSettings(keys, showAdvanced)) {
      const card = el("section", "card settings-group");
      card.append(el("h2", "", g.title));
      for (const k of g.items) {
        const row = el("div", "setting");
        const label = el("label", "setting-name");
        label.htmlFor = "set-" + k.key;
        label.append(el("span", "", k.key));
        if (k.weight === "heavy") {
          const b = el("span", "badge warn", "reinstall");
          b.title = "This change starts an install or rebuild of the component";
          label.append(" ", b);
        }
        const body = el("div", "setting-body");
        let input;
        if (k.secret) {
          const s = secretRow(k);
          input = s.input;
          body.append(s.row);
        } else {
          input = makeInput(k);
          body.append(input);
        }
        if (HINTS[k.key]) body.append(el("p", "hint", HINTS[k.key]));
        const note = el("p", "field-note");
        body.append(note);
        fields.set(k.key, { input, note });
        row.append(label, body);
        card.append(row);
      }
      root.append(card);
    }
    els.groups.replaceChildren(root);
    refreshDirty();
  }

  function pending() {
    return changedValues(keys, edits);
  }

  function refreshDirty() {
    const n = Object.keys(pending()).length;
    els.apply.disabled = n === 0;
    els.check.disabled = n === 0;
    els.revert.disabled = n === 0;
    els.count.textContent = n ? "Changed: " + n : "No changes";
  }

  async function load() {
    try {
      const res = await api("/api/settings");
      if (!running) return;
      keys = res.keys;
      edits = {};
      els.error.textContent = "";
      render();
    } catch (err) {
      fail(err);
    }
  }

  function showCheck(res) {
    els.result.replaceChildren();
    for (const [key, f] of fields) {
      if (f.note.className.includes("bad") && !localProblem(keys.find((x) => x.key === key), f.input.value)) {
        f.note.textContent = "";
      }
    }
    for (const msg of res.errors || []) els.result.append(el("p", "error", msg));
    for (const w of res.warnings || []) {
      const p = el("p", "warn-line");
      p.append(
        el("span", "", "Port " + w.port + " (" + w.key + ") is busy: " + w.holder + ". "),
      );
      if (w.suggestion) {
        const use = el("button", "", "Use " + w.suggestion);
        use.type = "button";
        use.addEventListener("click", () => {
          edits[w.key] = String(w.suggestion);
          const f = fields.get(w.key);
          if (f) f.input.value = String(w.suggestion);
          refreshDirty();
          p.remove();
        });
        p.append(use);
      } else {
        p.append(el("span", "muted", "No free port nearby, enter another one."));
      }
      els.result.append(p);
    }
    if (res.ok && !(res.warnings || []).length) {
      els.result.append(
        el("p", "ok-line", res.weight === "heavy" ? "Check passed. This is a heavy change: it starts a reinstall." : "Check passed."),
      );
    }
  }

  async function check() {
    const values = pending();
    if (!Object.keys(values).length) return null;
    els.error.textContent = "";
    try {
      const res = await api("/api/settings/check", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ values }),
      });
      showCheck(res);
      return res;
    } catch (err) {
      fail(err);
      return null;
    }
  }

  async function apply() {
    const values = pending();
    if (!Object.keys(values).length) return;
    setBusy(true);
    say("Checking…");
    try {
      const res = await check();
      if (!res || !res.ok || (res.warnings || []).length) {
        say(res && (res.warnings || []).length ? "Choose another port." : "Fix what is marked.", "error");
        return;
      }
      const confirmAccess = needsAccessConfirm(values, keys);
      if (confirmAccess && !window.confirm("The panels will be reachable from more than this machine (" + values.ACCESS_MODE + "). Continue?")) {
        say("");
        return;
      }
      if (res.weight === "heavy" && !window.confirm("This change starts a reinstall or rebuild of components. It can take minutes. Continue?")) {
        say("");
        return;
      }
      say(res.weight === "heavy" ? "Starting to apply…" : "Applying…");
      const out = await api("/api/settings/apply", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ values, confirm_access: confirmAccess }),
      });
      if (res.weight === "heavy" && out.output !== "no changes") {
        followJob();
      } else {
        say("Applied.");
        els.result.replaceChildren();
        await load();
      }
    } catch (err) {
      fail(err);
      if (err.body && err.body.errors) showCheck({ ok: false, errors: err.body.errors });
      say("");
    } finally {
      if (running) setBusy(false);
      if (running) refreshDirty();
    }
  }

  // The heavy apply is a unit on the server; the screen asks how it is doing
  // until it stops.
  function followJob() {
    clearTimeout(jobTimer);
    els.jobBox.hidden = false;
    const tick = async () => {
      try {
        const j = await api("/api/settings/job");
        if (!running) return;
        els.job.textContent = (j.log || []).join("\n");
        els.job.scrollTop = els.job.scrollHeight;
        if (j.state === "active" || j.state === "activating") {
          say("Applying…");
          jobTimer = setTimeout(tick, 2000);
          return;
        }
        if (j.result === "success" || j.state === "inactive") {
          say("Applied.");
          await load();
        } else {
          say("Applying failed, details below.", "error");
        }
      } catch (err) {
        fail(err);
      }
    };
    tick();
  }

  els.advanced.addEventListener("change", () => {
    showAdvanced = els.advanced.checked;
    render();
  });
  els.check.addEventListener("click", async () => {
    setBusy(true);
    await check();
    if (running) setBusy(false);
    if (running) refreshDirty();
  });
  els.apply.addEventListener("click", apply);
  els.revert.addEventListener("click", () => {
    edits = {};
    els.result.replaceChildren();
    render();
  });

  load();
  api("/api/settings/job")
    .then((j) => {
      if (running && (j.state === "active" || j.state === "activating")) followJob();
    })
    .catch(() => {});

  return () => {
    running = false;
    clearTimeout(jobTimer);
  };
}
