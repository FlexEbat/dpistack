// The Settings screen: every key of dpistack.conf, from the schema the server
// reports, in three columns: the categories and a search, the keys, and the
// details of the key in focus with the staged change and the profiles. A key
// that does not apply with the values as they are is dimmed, with the reason.
// A change is checked before it is applied, and Apply opens only after a
// check of exactly these values has passed; a busy port shows its holder and
// offers a free one; a heavy change (a reinstall of a component) says so and
// runs as a job that the screen follows.

import {
  GROUPS,
  HINTS,
  changedValues,
  localProblem,
  needsAccessConfirm,
  searchKeys,
  categories,
  applies,
  dependencyText,
  shown,
  diffRows,
  stageSummary,
  stageText,
  stageSig,
  profileAll,
  loadProfile,
  PROFILE_NAME_RE,
} from "./settings-model.js";

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
  let category = GROUPS[0][0];
  let query = "";
  let selected = "";
  let checkedSig = null; // the staged values that the last check passed
  let profiles = [];
  let jobTimer = null;
  const fields = new Map(); // key -> {input, note, row, dep}
  const byKey = () => new Map(keys.map((k) => [k.key, k]));
  const valueOf = (key) => (key in edits ? edits[key] : (byKey().get(key) || { value: "" }).value);

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
      checkedSig = null;
      refreshAll();
    });
    input.addEventListener("focus", () => select(k.key));
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

  function makeRow(k) {
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
      const sr = secretRow(k);
      input = sr.input;
      input.addEventListener("focus", () => select(k.key));
      body.append(sr.row);
    } else {
      input = makeInput(k);
      body.append(input);
    }
    if (HINTS[k.key]) body.append(el("p", "hint", HINTS[k.key]));
    const dep = el("p", "field-note dep");
    body.append(dep);
    const note = el("p", "field-note");
    body.append(note);
    fields.set(k.key, { input, note, row, dep });
    row.append(label, body);
    row.addEventListener("click", () => select(k.key));
    return row;
  }

  // The keys the middle column shows: the search results, or one category.
  function visibleKeys() {
    if (query.trim()) return searchKeys(keys, query, showAdvanced);
    return { items: keys.filter((k) => k.group === category && (showAdvanced || k.level === "basic")), hiddenAdvanced: 0 };
  }

  function renderMain() {
    fields.clear();
    const { items, hiddenAdvanced } = visibleKeys();
    const card = el("section", "card settings-group");
    const searching = query.trim() !== "";
    card.append(el("h2", "", searching ? "Search results" : (GROUPS.find((g) => g[0] === category) || ["", ""])[1]));
    if (!items.length) {
      card.append(el("p", "muted empty", searching ? "No setting matches." : "Nothing in this category at this level."));
    }
    for (const k of items) card.append(makeRow(k));
    if (hiddenAdvanced > 0) {
      card.append(el("p", "muted", hiddenAdvanced + " more " + (hiddenAdvanced === 1 ? "match" : "matches") + " among the advanced settings. Turn on Show advanced settings to see " + (hiddenAdvanced === 1 ? "it" : "them") + "."));
    }
    els.groups.replaceChildren(card);
  }

  function renderCats() {
    const list = el("div", "cat-list");
    for (const c of categories(keys, showAdvanced, edits)) {
      const b = el("button", "cat-btn", c.title);
      b.type = "button";
      const on = !query.trim() && c.id === category;
      b.setAttribute("aria-pressed", on ? "true" : "false");
      b.append(" ", el("span", "muted", String(c.count)));
      if (c.changed) b.append(" ", el("span", "badge warn", String(c.changed)));
      b.addEventListener("click", () => {
        category = c.id;
        query = "";
        els.search.value = "";
        render();
      });
      list.append(b);
    }
    els.cats.replaceChildren(list);
  }

  // Dim the keys that mean nothing with the values as they are, and say why.
  function renderDeps() {
    const kmap = byKey();
    for (const [key, f] of fields) {
      const k = kmap.get(key);
      const ok = applies(k, valueOf);
      f.row.classList.toggle("inactive", !ok);
      f.dep.textContent = ok ? "" : "Not used now. " + dependencyText(k) + ".";
    }
  }

  function select(key) {
    if (selected === key) return;
    selected = key;
    renderDetails();
  }

  function renderDetails() {
    const k = byKey().get(selected);
    if (!k) {
      els.details.replaceChildren(el("p", "muted", "Select a setting to see its default, the allowed values, what it depends on and what a change touches."));
      return;
    }
    const dl = el("dl", "details");
    const add = (name, text) => {
      dl.append(el("dt", "", name), el("dd", "", text));
    };
    add("Setting", k.key);
    if (HINTS[k.key]) add("What it does", HINTS[k.key]);
    if (k.type === "enum") add("Allowed", k.options.join(", "));
    else if (k.type === "int") add("Allowed", "a whole number" + (k.min !== null && k.max !== null ? " from " + k.min + " to " + k.max : ""));
    else add("Allowed", "text, checked when you press Check");
    add("Default", shown(k.default));
    add("Saved value", k.secret ? (k.set ? "set" : "not set") : shown(k.value));
    const dep = dependencyText(k);
    add("Depends on", dep ? dep : "nothing: it always applies");
    if (dep) add("Applies now", applies(k, valueOf) ? "yes" : "no");
    add("A change is", k.weight === "heavy" ? "heavy: it starts a reinstall or a rebuild" : "light: files are written again and components restart");
    add("It touches", (k.touches || []).length ? k.touches.join(", ") : "nothing");
    els.details.replaceChildren(dl);
  }

  function renderDiff() {
    const rows = diffRows(keys, edits);
    const sum = stageSummary(rows);
    const parts = [];
    if (rows.length) {
      const t = el("table", "diff");
      const head = el("tr");
      for (const h of ["Setting", "Was", "Will be", ""]) head.append(el("th", "", h));
      t.append(head);
      for (const r of rows) {
        const tr = el("tr");
        const w = el("td");
        if (r.weight === "heavy") w.append(el("span", "badge warn", "reinstall"));
        tr.append(el("td", "", r.key), el("td", "", shown(r.from)), el("td", "", shown(r.to)), w);
        t.append(tr);
      }
      parts.push(t);
    }
    parts.push(el("p", rows.length ? "" : "muted", stageText(sum)));
    els.diff.replaceChildren(...parts);
  }

  function renderProfiles() {
    const list = el("div", "profile-list");
    if (!profiles.length) list.append(el("p", "muted empty", "No profiles yet."));
    for (const p of profiles) {
      const row = el("div", "profile");
      row.append(el("span", "profile-name", p.name), el("span", "muted", p.count + " keys, by " + p.by));
      const load = el("button", "small", "Load");
      load.type = "button";
      load.addEventListener("click", () => loadProfileByName(p.name));
      const del = el("button", "small", "Delete");
      del.type = "button";
      del.addEventListener("click", () => deleteProfile(p.name));
      row.append(load, del);
      list.append(row);
    }
    els.profiles.replaceChildren(list);
  }

  function refreshAll() {
    renderCats();
    renderDeps();
    renderDiff();
    renderDetails();
    refreshDirty();
  }

  function render() {
    renderCats();
    renderMain();
    renderDeps();
    renderDiff();
    renderDetails();
    renderProfiles();
    refreshDirty();
  }

  function pending() {
    return changedValues(keys, edits);
  }

  function refreshDirty() {
    const values = pending();
    const n = Object.keys(values).length;
    els.check.disabled = n === 0;
    els.revert.disabled = n === 0;
    els.apply.disabled = n === 0 || checkedSig !== stageSig(values);
    els.count.textContent = n ? "Changed: " + n : "No changes";
  }

  async function load() {
    try {
      const res = await api("/api/settings");
      if (!running) return;
      keys = res.keys;
      edits = {};
      checkedSig = null;
      els.error.textContent = "";
      render();
      loadProfiles();
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
          checkedSig = null;
          refreshAll();
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
      checkedSig = res.ok && !(res.warnings || []).length ? stageSig(values) : null;
      refreshDirty();
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

  async function loadProfiles() {
    try {
      const res = await api("/api/settings/profiles");
      if (!running) return;
      profiles = res.profiles || [];
      renderProfiles();
    } catch (err) {
      fail(err);
    }
  }

  async function loadProfileByName(name) {
    if (Object.keys(pending()).length && !window.confirm("Replace the staged changes with the profile " + name + "?")) return;
    els.error.textContent = "";
    try {
      const res = await api("/api/settings/profiles/" + encodeURIComponent(name));
      if (!running) return;
      const out = loadProfile(keys, res.keys);
      edits = out.edits;
      checkedSig = null;
      els.result.replaceChildren();
      render();
      const n = Object.keys(out.edits).length;
      say(
        'Profile "' + name + '" loaded: ' + n + " change" + (n === 1 ? "" : "s") + " staged, check them before applying." +
          (out.skipped.length ? " Left out, not known here: " + out.skipped.join(", ") + "." : ""),
      );
    } catch (err) {
      fail(err);
    }
  }

  async function saveProfile(values) {
    const name = els.profileName.value.trim();
    if (!PROFILE_NAME_RE.test(name)) {
      els.error.textContent = "A profile name is 1 to 32 characters: lowercase letters, digits, - and _.";
      return;
    }
    if (!Object.keys(values).length) {
      els.error.textContent = "There is nothing to save.";
      return;
    }
    if (profiles.some((p) => p.name === name) && !window.confirm("Replace the profile " + name + "?")) return;
    els.error.textContent = "";
    setBusy(true);
    try {
      await api("/api/settings/profiles/" + encodeURIComponent(name), {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ values }),
      });
      say('Profile "' + name + '" saved.');
      els.profileName.value = "";
      await loadProfiles();
    } catch (err) {
      fail(err);
    } finally {
      if (running) setBusy(false);
      if (running) refreshDirty();
    }
  }

  async function deleteProfile(name) {
    if (!window.confirm("Delete the profile " + name + "?")) return;
    els.error.textContent = "";
    try {
      await api("/api/settings/profiles/" + encodeURIComponent(name), { method: "DELETE" });
      say('Profile "' + name + '" deleted.');
      await loadProfiles();
    } catch (err) {
      fail(err);
    }
  }

  els.advanced.addEventListener("change", () => {
    showAdvanced = els.advanced.checked;
    render();
  });
  els.search.addEventListener("input", () => {
    query = els.search.value;
    renderCats();
    renderMain();
    renderDeps();
  });
  els.profileSave.addEventListener("click", () => saveProfile(pending()));
  els.profileSaveAll.addEventListener("click", () => saveProfile(profileAll(keys, edits)));
  els.check.addEventListener("click", async () => {
    setBusy(true);
    await check();
    if (running) setBusy(false);
    if (running) refreshDirty();
  });
  els.apply.addEventListener("click", apply);
  els.revert.addEventListener("click", () => {
    edits = {};
    checkedSig = null;
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
