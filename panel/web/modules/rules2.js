// The Rules v2 part of the Rules screen (slice 41): the rule sets with their
// counts, the history of updates, a rule search by category, source, state
// and text, and an editor for local.rules with a check and a history of
// changes. Every number is the answer of a `dpistack` verb behind
// /api/rules/*; the words and the checks are in rules2-model.js. Saving goes
// through the same /api/config/local.rules as the Configs screen.

import { checkReport, diffSummary, findNote, findQuery, findRows, historyRows, lineDiff, statsNote, statsRows, versionRows } from "./rules2-model.js";
import { humanBytes } from "./system.js";

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function table(heads, rows) {
  const t = el("table");
  const head = el("tr");
  for (const h of heads) head.append(el("th", "", h));
  t.append(head);
  for (const cells of rows) {
    const tr = el("tr");
    for (const c of cells) tr.append(c instanceof Node ? c : el("td", "", c === null || c === undefined ? "" : String(c)));
    t.append(tr);
  }
  return t;
}

const num = (n) => (n === null || n === undefined ? "n/a" : String(n));

export function start(api, els, onError) {
  let running = true;
  let saved = ""; // local.rules as the server has it
  let checked = null; // { text, canSave } of the last check
  let canEdit = true;

  const say = (text, bad) => {
    els.message.textContent = bad ? "" : text;
    els.error.textContent = bad ? text : "";
  };
  const fail = (err) => {
    if (err.status === 401) return onError(err);
    say(err.message, true);
  };

  function renderStats(stats) {
    els.stats.replaceChildren(
      table(
        ["Rules", "Total", "Enabled", "Disabled", "Not loaded", "Downloaded"],
        statsRows(stats).map((r) => [r.note ? `${r.name}. ${r.note}` : r.name, num(r.total), num(r.enabled), num(r.disabled), num(r.missing), r.fetched]),
      ),
      el("p", "muted", statsNote(stats)),
    );
  }

  function renderHistory(h) {
    const rows = historyRows(h).slice(0, 10);
    els.history.replaceChildren(rows.length ? table(["Time", "Result", "Rules"], rows.map((r) => [r.time, r.result, r.detail])) : el("p", "muted", "No update has been recorded yet. The history starts with the next update."));
  }

  function fillSelect(select, first, values) {
    const keep = select.value;
    select.replaceChildren(...[["", first], ...values.map((v) => [v, v])].map(([v, t]) => {
      const o = el("option", "", t);
      o.value = v;
      return o;
    }));
    select.value = values.includes(keep) ? keep : "";
  }

  async function loadFacets() {
    try {
      const f = await api("/api/rules/facets");
      if (!running) return;
      fillSelect(els.class, "any category", (f.classes || []).map((c) => c.name));
      fillSelect(els.source, "any source", f.sources || []);
    } catch (err) {
      if (err.status === 401) onError(err);
    }
  }

  async function loadOverview() {
    const [stats, history] = await Promise.allSettled([api("/api/rules/stats"), api("/api/rules/history")]);
    if (!running) return;
    for (const r of [stats, history]) if (r.status === "rejected" && r.reason && r.reason.status === 401) return onError(r.reason);
    if (stats.status === "fulfilled") renderStats(stats.value);
    else els.stats.replaceChildren(el("p", "muted empty", "The counts could not be read."));
    if (history.status === "fulfilled") renderHistory(history.value);
    else els.history.replaceChildren(el("p", "muted empty", "The history could not be read."));
  }

  async function find() {
    const q = findQuery({ class: els.class.value, source: els.source.value, state: els.state.value, text: els.text.value });
    if (q.problem) {
      els.findNote.textContent = q.problem;
      els.findResults.replaceChildren();
      return;
    }
    els.error.textContent = "";
    try {
      const res = await api(`/api/rules/find?${q.query}`);
      if (!running) return;
      els.findNote.textContent = findNote(res);
      const rows = findRows(res);
      els.findResults.replaceChildren(rows.length ? table(["Rule", "Description", "Category", "State"], rows.map((r) => [r.sid, r.msg, r.class, r.state])) : "");
    } catch (err) {
      fail(err);
    }
  }

  // The editor: local.rules, with the check and the history of changes.
  function setReport(report) {
    els.report.replaceChildren();
    if (!report.verdict) return;
    els.report.append(el("p", report.canSave ? "muted" : "error", report.verdict));
    if (report.lines.length) {
      const list = el("ul");
      for (const l of report.lines) list.append(el("li", l.kind === "problem" ? "error" : "muted", l.text));
      els.report.append(list);
    }
  }

  function syncButtons() {
    const dirty = els.editor.value !== saved;
    const ok = checked && checked.text === els.editor.value && checked.canSave;
    els.check.disabled = !canEdit;
    els.save.disabled = !canEdit || !ok || !dirty;
    els.apply.disabled = !canEdit || !ok || !dirty;
  }

  async function loadLocal() {
    try {
      const res = await api("/api/config/local.rules");
      saved = res.content;
    } catch (err) {
      if (err.status === 403) {
        canEdit = false;
        els.editor.readOnly = true;
        els.report.replaceChildren(el("p", "muted", "Editing custom rules needs the permission to edit configuration files."));
        syncButtons();
        return;
      }
      if (/file missing/.test(String(err && err.message))) saved = "";
      else return fail(err);
    }
    if (!running) return;
    els.editor.value = saved;
    checked = null;
    syncButtons();
    await loadVersions();
  }

  async function loadVersions() {
    try {
      const h = await api("/api/config/local.rules/history");
      if (!running) return;
      const rows = versionRows(h);
      els.versions.replaceChildren();
      els.diff.replaceChildren();
      if (!rows.length) {
        els.versions.append(el("p", "muted", "No earlier version yet: a version is kept each time the file is saved."));
        return;
      }
      els.versions.append(
        table(["Saved", "Size", "Lines", ""], rows.slice(0, 20).map((v) => {
          const td = el("td");
          const b = el("button", "", "Compare with the editor");
          b.type = "button";
          b.addEventListener("click", () => showDiff(v));
          td.append(b);
          return [v.time, humanBytes(v.size), v.lines, td];
        })),
      );
    } catch (err) {
      if (err.status === 401) onError(err);
    }
  }

  async function showDiff(v) {
    try {
      const res = await api(`/api/config/local.rules/history/${encodeURIComponent(v.id)}`);
      if (!running) return;
      const diff = lineDiff(res.content, els.editor.value);
      const box = el("div");
      box.append(el("p", "muted", `${v.time} against the editor: ${diffSummary(diff)}`));
      if (diff) {
        const pre = el("pre", "log");
        for (const d of diff.filter((x) => x.type !== "same").slice(0, 300)) pre.append(el("div", d.type === "add" ? "" : "muted", (d.type === "add" ? "+ " : "- ") + d.text));
        box.append(pre);
        const restore = el("button", "", "Put this version in the editor");
        restore.type = "button";
        restore.addEventListener("click", () => {
          els.editor.value = res.content;
          checked = null;
          els.report.replaceChildren();
          syncButtons();
        });
        box.append(restore);
      }
      els.diff.replaceChildren(box);
    } catch (err) {
      fail(err);
    }
  }

  async function check() {
    say("Checking the file with Suricata...");
    els.check.disabled = true;
    const text = els.editor.value;
    try {
      const res = await api("/api/rules/local/check", { method: "POST", headers: { "Content-Type": "text/plain" }, body: text });
      if (!running) return;
      const report = checkReport(res);
      checked = { text, canSave: report.canSave };
      setReport(report);
      say(report.canSave ? "The file is sound." : "The file has problems, see below.", !report.canSave);
    } catch (err) {
      fail(err);
    } finally {
      syncButtons();
    }
  }

  async function save(apply) {
    if (apply && !confirm("Save local.rules and apply? The rules will be reloaded.")) return;
    els.save.disabled = els.apply.disabled = true;
    try {
      await api(`/api/config/local.rules?apply=${apply ? 1 : 0}`, { method: "PUT", headers: { "Content-Type": "text/plain" }, body: els.editor.value });
      if (!running) return;
      saved = els.editor.value;
      say(apply ? "Saved and applied." : "Saved.");
      await Promise.all([loadVersions(), loadOverview(), loadFacets()]);
    } catch (err) {
      fail(err);
    } finally {
      syncButtons();
    }
  }

  const onEdit = () => syncButtons();
  const onFind = () => find();
  const onCheck = () => check();
  const onSave = () => save(false);
  const onApply = () => save(true);
  const onReload = () => loadLocal();
  const onKey = (e) => {
    if (e.key === "Enter") find();
  };
  els.editor.addEventListener("input", onEdit);
  els.find.addEventListener("click", onFind);
  els.text.addEventListener("keydown", onKey);
  els.check.addEventListener("click", onCheck);
  els.save.addEventListener("click", onSave);
  els.apply.addEventListener("click", onApply);
  els.reload.addEventListener("click", onReload);

  loadOverview();
  loadFacets();
  loadLocal();
  return () => {
    running = false;
    els.editor.removeEventListener("input", onEdit);
    els.find.removeEventListener("click", onFind);
    els.text.removeEventListener("keydown", onKey);
    els.check.removeEventListener("click", onCheck);
    els.save.removeEventListener("click", onSave);
    els.apply.removeEventListener("click", onApply);
    els.reload.removeEventListener("click", onReload);
  };
}
