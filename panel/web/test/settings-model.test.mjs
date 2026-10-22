import test from "node:test";
import assert from "node:assert/strict";
import { GROUPS, HINTS, groupSettings, changedValues, localProblem, needsAccessConfirm } from "../modules/settings-model.js";

const K = (o) => ({ type: "free", options: [], min: null, max: null, default: "", level: "basic", group: "capture", weight: "light", secret: false, set: false, value: "", ...o });

test("basic keys come first and advanced ones only on request; empty groups vanish", () => {
  const keys = [K({ key: "A", level: "basic" }), K({ key: "B", level: "advanced" }), K({ key: "C", group: "rules", level: "advanced" })];
  assert.deepEqual(groupSettings(keys, false).map((g) => [g.id, g.items.map((i) => i.key)]), [["capture", ["A"]]]);
  assert.deepEqual(groupSettings(keys, true).map((g) => g.id), ["capture", "rules"]);
});

test("changedValues keeps only edits that differ and never a secret", () => {
  const keys = [K({ key: "A", value: "1" }), K({ key: "B", value: "x" }), K({ key: "S", secret: true })];
  assert.deepEqual(changedValues(keys, { A: "2", B: "x", S: "token" }), { A: "2" });
});

test("localProblem checks ranges, enums and newlines", () => {
  const n = K({ key: "N", type: "int", min: 5, max: 300, default: "30" });
  assert.equal(localProblem(n, "45"), "");
  assert.match(localProblem(n, "4"), /не меньше 5/);
  assert.match(localProblem(n, "301"), /не больше 300/);
  assert.match(localProblem(n, "x"), /целое/);
  const e = K({ key: "E", type: "enum", options: ["a", "b"] });
  assert.equal(localProblem(e, "a"), "");
  assert.match(localProblem(e, "c"), /вне списка/);
  assert.match(localProblem(K({ key: "F" }), "a\nb"), /перевод/);
});

test("widening access asks for confirmation, narrowing does not", () => {
  const keys = [K({ key: "ACCESS_MODE" })];
  assert.equal(needsAccessConfirm({ ACCESS_MODE: "lan" }, keys), true);
  assert.equal(needsAccessConfirm({ ACCESS_MODE: "localhost" }, keys), false);
  assert.equal(needsAccessConfirm({ PANEL_PORT: "1" }, keys), false);
});

test("every schema group has a title and the hint table has no empty line", () => {
  assert.equal(GROUPS.length, 8);
  for (const [k, v] of Object.entries(HINTS)) assert.ok(v.length > 5, k);
});
