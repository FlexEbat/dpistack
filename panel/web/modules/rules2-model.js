// The model of the Rules v2 part of the Rules screen (slice 41): the counts
// per rule source, the history of updates, the filters of the rule search,
// the report of the check of local.rules and the difference between two
// versions of a file. Pure functions, no DOM. The numbers come from
// `dpistack rules-stats`, `rules-history`, `rules-find` and `rules-local
// check` through the panel's API and are shown as they are; nothing here
// computes a count of its own.

const when = (iso) => {
  if (!iso) return "";
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? String(iso) : d.toLocaleString("en-GB");
};
const plural = (n, one, many) => `${n} ${n === 1 ? one : many}`;

// statsRows is the table of rule sets: the merged set, local.rules and every
// enabled source. A source that was never downloaded has no numbers and says
// why; it is not shown as zero.
export function statsRows(stats) {
  if (!stats) return [];
  const rows = [];
  const set = stats.ruleset || {};
  rows.push({
    name: "All rules in use",
    note: set.present ? "" : "No rule set yet: run an update.",
    total: set.present ? set.total : null,
    enabled: set.present ? set.enabled : null,
    disabled: set.present ? set.disabled : null,
    missing: null,
    fetched: set.present ? when(set.updated) : "",
  });
  const local = stats.local || {};
  rows.push({ name: "Custom rules (local.rules)", note: "", total: local.total, enabled: local.enabled, disabled: local.disabled, missing: null, fetched: "" });
  for (const s of stats.sources || []) {
    rows.push({
      name: s.name,
      note: s.cached ? "" : "Not downloaded yet: run an update.",
      total: s.cached ? s.total : null,
      enabled: s.cached ? s.enabled : null,
      disabled: s.cached ? s.disabled : null,
      missing: s.cached ? s.missing : null,
      fetched: s.cached ? when(s.fetched) : "",
    });
  }
  return rows;
}

// statsNote explains the one thing that is easy to misread: a source counts
// the rules it ships, and the state of each is the state in the rules in use.
export function statsNote(stats) {
  if (!stats || !(stats.sources || []).length) return "No rule source is enabled.";
  return "Each source counts the rules it ships. Enabled and disabled are their state in the rules in use, so a rule turned off in disable.conf counts as disabled. Not loaded are rules the set does not hold.";
}

// historyRows is the list of updates, newest first, one sentence each.
export function historyRows(h) {
  const list = (h && h.updates) || [];
  return list.map((u) => ({
    time: when(u.time),
    result: u.result === "ok" ? "updated" : "failed, the previous rules were restored",
    detail: u.result === "ok" && u.parsed
      ? `${plural(u.total, "rule", "rules")}, ${u.enabled} enabled, ${u.added} added, ${u.removed} removed, ${u.modified} modified`
      : u.result === "ok"
        ? "the tool did not report the numbers"
        : "",
  }));
}

export const STATES = ["any", "enabled", "disabled"];

// findQuery builds the query string of GET /api/rules/find from the form, or
// says what is missing. At least one filter is needed.
export function findQuery(f) {
  const q = new URLSearchParams();
  const text = String(f.text || "").trim();
  if (f.class) q.set("class", f.class);
  if (f.source) q.set("source", f.source);
  if (f.state && f.state !== "any" && STATES.includes(f.state)) q.set("state", f.state);
  if (text) q.set("q", text);
  if (![...q.keys()].length) return { problem: "Choose a category, a source or a state, or enter some text." };
  return { query: q.toString() };
}

// findRows is the result table.
export function findRows(res) {
  return ((res && res.results) || []).map((r) => ({ sid: String(r.sid), msg: r.msg || "", class: r.class || "", state: r.enabled ? "enabled" : "disabled" }));
}

// findNote says what the result list cannot show by itself.
export function findNote(res) {
  if (!res) return "";
  if (res.source_known === false) return "That source has no downloaded rules yet, so nothing can be found in it. Run an update.";
  const n = (res.results || []).length;
  if (n === 0) return "No rule matches. Disabled rules are searched too.";
  return res.truncated ? `The first ${n} rules are shown; narrow the filters to see the rest.` : `${plural(n, "rule", "rules")}. Disabled rules are included.`;
}

// checkReport turns the answer of `rules-local check` into what the screen
// shows: a verdict, the problems and warnings with their line numbers, and
// what suricata -T said. `canSave` is false while anything is wrong.
export function checkReport(res) {
  if (!res) return { verdict: "", lines: [], canSave: false };
  const problems = (res.problems || []).map((p) => `Line ${p.line}: ${p.text}`);
  const warnings = (res.warnings || []).map((w) => `Line ${w.line}: ${w.text}`);
  const s = res.suricata || {};
  const lines = [...problems.map((t) => ({ kind: "problem", text: t })), ...warnings.map((t) => ({ kind: "warning", text: t }))];
  if (s.run && !s.ok) lines.push({ kind: "problem", text: `Suricata does not accept the file: ${String(s.output || "").trim()}` });
  if (s.run === false) lines.push({ kind: "warning", text: String(s.output || "Suricata was not run, so the file was not tested.") });
  const bad = lines.filter((l) => l.kind === "problem").length;
  const verdict = bad === 0
    ? `Sound: ${plural(res.rules || 0, "rule", "rules")}, no problems.${s.run ? " Suricata accepts the file." : ""}`
    : `${plural(bad, "problem", "problems")} to fix before saving.`;
  return { verdict, lines, canSave: bad === 0 && res.ok === true };
}

// lineDiff compares two texts line by line (the longest common run, so a
// moved block shows as removed and added). A text of more than `max` lines is
// not compared, and `null` says so.
export function lineDiff(before, after, max = 2000) {
  const a = String(before).replace(/\n$/, "").split("\n");
  const b = String(after).replace(/\n$/, "").split("\n");
  if (a.length > max || b.length > max) return null;
  const n = a.length;
  const m = b.length;
  const lcs = Array.from({ length: n + 1 }, () => new Uint32Array(m + 1));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) lcs[i][j] = a[i] === b[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
  }
  const out = [];
  let i = 0;
  let j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) {
      out.push({ type: "same", text: a[i] });
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      out.push({ type: "del", text: a[i++] });
    } else {
      out.push({ type: "add", text: b[j++] });
    }
  }
  while (i < n) out.push({ type: "del", text: a[i++] });
  while (j < m) out.push({ type: "add", text: b[j++] });
  return out;
}

// diffSummary is the one line above a diff.
export function diffSummary(diff) {
  if (diff === null) return "The files are too long to compare here.";
  const add = diff.filter((d) => d.type === "add").length;
  const del = diff.filter((d) => d.type === "del").length;
  return add + del === 0 ? "No difference." : `${plural(add, "line", "lines")} added, ${plural(del, "line", "lines")} removed.`;
}

// versionRows is the list of saved versions of a file for the screen.
export function versionRows(h) {
  return ((h && h.versions) || []).map((v) => ({ id: v.id, time: when(v.time), size: v.size, lines: v.lines }));
}
