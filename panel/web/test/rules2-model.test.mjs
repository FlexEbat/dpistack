import test from "node:test";
import assert from "node:assert/strict";
import { checkReport, diffSummary, findNote, findQuery, findRows, historyRows, lineDiff, statsNote, statsRows, versionRows } from "../modules/rules2-model.js";

const stats = {
  ruleset: { present: true, updated: "2026-11-09T06:43:33Z", total: 5, enabled: 3, disabled: 2 },
  local: { total: 2, enabled: 1, disabled: 1 },
  sources: [
    { name: "test/one", cached: true, total: 3, enabled: 2, disabled: 1, missing: 0, fetched: "2026-11-09T06:43:33Z" },
    { name: "test/never", cached: false, total: null, enabled: null, disabled: null, missing: null, fetched: null },
  ],
};

test("statsRows: the rules in use, custom rules and every source, in that order", () => {
  const rows = statsRows(stats);
  assert.deepEqual(rows.map((r) => r.name), ["All rules in use", "Custom rules (local.rules)", "test/one", "test/never"]);
  assert.deepEqual([rows[0].total, rows[0].enabled, rows[0].disabled], [5, 3, 2]);
  assert.deepEqual([rows[1].total, rows[1].enabled, rows[1].disabled], [2, 1, 1]);
  assert.deepEqual([rows[2].total, rows[2].enabled, rows[2].disabled, rows[2].missing], [3, 2, 1, 0]);
  assert.ok(rows[2].fetched);
});

test("statsRows: a source never downloaded has no numbers and says why, not zeros", () => {
  const never = statsRows(stats)[3];
  assert.deepEqual([never.total, never.enabled, never.disabled, never.missing], [null, null, null, null]);
  assert.match(never.note, /Not downloaded yet/);
  assert.equal(never.fetched, "");
});

test("statsRows: no rule set yet is said, with no numbers", () => {
  const rows = statsRows({ ruleset: { present: false }, local: { total: 0, enabled: 0, disabled: 0 }, sources: [] });
  assert.equal(rows[0].total, null);
  assert.match(rows[0].note, /run an update/);
  assert.deepEqual(statsRows(null), []);
});

test("statsNote explains what the numbers mean, or that no source is enabled", () => {
  assert.match(statsNote(stats), /disable\.conf counts as disabled/);
  assert.equal(statsNote({ sources: [] }), "No rule source is enabled.");
  assert.equal(statsNote(null), "No rule source is enabled.");
});

test("historyRows: a sentence per update, honest when the numbers were not reported or the update failed", () => {
  const rows = historyRows({ updates: [
    { time: "2026-11-09T06:00:00Z", result: "ok", loaded: 5, total: 5, enabled: 3, added: 4, removed: 1, modified: 2, parsed: true },
    { time: "2026-11-08T06:00:00Z", result: "ok", total: 0, parsed: false },
    { time: "2026-11-07T06:00:00Z", result: "failed", total: 0, parsed: false },
  ] });
  assert.equal(rows[0].result, "updated");
  assert.equal(rows[0].detail, "5 rules, 3 enabled, 4 added, 1 removed, 2 modified");
  assert.equal(rows[1].detail, "the tool did not report the numbers");
  assert.match(rows[2].result, /failed, the previous rules were restored/);
  assert.equal(rows[2].detail, "");
  assert.equal(historyRows({ updates: [{ result: "ok", total: 1, enabled: 1, added: 0, removed: 0, modified: 0, parsed: true }] })[0].detail.startsWith("1 rule,"), true);
  assert.deepEqual(historyRows(null), []);
});

test("findQuery: needs one filter, leaves out 'any', and builds the query the API takes", () => {
  assert.match(findQuery({}).problem, /Choose a category/);
  assert.match(findQuery({ state: "any", text: "  " }).problem, /Choose a category/);
  assert.equal(findQuery({ text: "ET SCAN" }).query, "q=ET+SCAN");
  assert.equal(findQuery({ class: "trojan-activity", source: "et/open", state: "disabled", text: "x" }).query, "class=trojan-activity&source=et%2Fopen&state=disabled&q=x");
  assert.equal(findQuery({ state: "enabled" }).query, "state=enabled");
  assert.match(findQuery({ state: "bogus" }).problem, /Choose a category/);
});

test("findRows and findNote say what the list is and is not", () => {
  const res = { results: [{ sid: 1000002, msg: "ONE off", class: "trojan-activity", enabled: false }, { sid: 5, msg: "", enabled: true }], truncated: false, source_known: true };
  assert.deepEqual(findRows(res), [
    { sid: "1000002", msg: "ONE off", class: "trojan-activity", state: "disabled" },
    { sid: "5", msg: "", class: "", state: "enabled" },
  ]);
  assert.equal(findNote(res), "2 rules. Disabled rules are included.");
  assert.match(findNote({ results: [], source_known: true }), /No rule matches/);
  assert.match(findNote({ results: [], source_known: false }), /no downloaded rules yet/);
  assert.match(findNote({ results: new Array(50).fill({ sid: 1 }), truncated: true, source_known: true }), /The first 50 rules/);
  assert.equal(findNote(null), "");
  assert.deepEqual(findRows(null), []);
});

test("checkReport: a sound file can be saved, anything wrong cannot", () => {
  const good = checkReport({ ok: true, rules: 2, problems: [], warnings: [], suricata: { run: true, ok: true, output: "" } });
  assert.equal(good.canSave, true);
  assert.match(good.verdict, /^Sound: 2 rules, no problems\. Suricata accepts the file\./);
  const bad = checkReport({ ok: false, rules: 3, problems: [{ line: 1, kind: "conflict", text: "sid 5 is already used by the rule set: ONE" }, { line: 4, kind: "no_sid", text: "no sid" }], warnings: [{ line: 2, text: "outside the range" }], suricata: { run: true, ok: true, output: "" } });
  assert.equal(bad.canSave, false);
  assert.equal(bad.verdict, "2 problems to fix before saving.");
  assert.deepEqual(bad.lines.map((l) => l.kind), ["problem", "problem", "warning"]);
  assert.equal(bad.lines[0].text, "Line 1: sid 5 is already used by the rule set: ONE");
});

test("checkReport: what suricata -T says is a problem, and not testing is a warning that does not block", () => {
  const rejected = checkReport({ ok: false, rules: 1, problems: [], warnings: [], suricata: { run: true, ok: false, output: "ERROR: bad rule\n" } });
  assert.equal(rejected.canSave, false);
  assert.equal(rejected.lines[0].text, "Suricata does not accept the file: ERROR: bad rule");
  const untested = checkReport({ ok: true, rules: 1, problems: [], warnings: [], suricata: { run: false, ok: true, output: "Suricata is not installed here, so the file was not tested" } });
  assert.equal(untested.canSave, true);
  assert.equal(untested.lines[0].kind, "warning");
  assert.ok(!/Suricata accepts/.test(untested.verdict));
  assert.deepEqual(checkReport(null), { verdict: "", lines: [], canSave: false });
});

test("lineDiff: same, added and removed lines in order", () => {
  const d = lineDiff("a\nb\nc\n", "a\nx\nc\nd\n");
  assert.deepEqual(d.map((x) => `${x.type}:${x.text}`), ["same:a", "del:b", "add:x", "same:c", "add:d"]);
  assert.equal(diffSummary(d), "2 lines added, 1 line removed.");
  assert.equal(diffSummary(lineDiff("a\n", "a\n")), "No difference.");
  assert.deepEqual(lineDiff("", "x").map((x) => x.type), ["del", "add"]);
});

test("lineDiff: a very long text is not compared, and says so", () => {
  const long = Array.from({ length: 2001 }, (_, i) => `l${i}`).join("\n");
  assert.equal(lineDiff(long, "a"), null);
  assert.equal(diffSummary(null), "The files are too long to compare here.");
  const ok = Array.from({ length: 2000 }, (_, i) => `l${i}`).join("\n");
  assert.equal(lineDiff(ok, ok).length, 2000);
  assert.equal(lineDiff(ok, ok + "\nextra"), null);
});

test("versionRows keeps the id, the time and the size", () => {
  const rows = versionRows({ versions: [{ id: "20261108T101010Z", time: "2026-11-08T10:10:10Z", size: 120, lines: 2 }] });
  assert.equal(rows[0].id, "20261108T101010Z");
  assert.equal(rows[0].size, 120);
  assert.equal(rows[0].lines, 2);
  assert.deepEqual(versionRows(null), []);
});
