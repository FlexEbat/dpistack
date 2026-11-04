import { test } from "node:test";
import assert from "node:assert/strict";
import { buildQuery, exportUrl, describe } from "../modules/audit.js";

test("empty filters are left out and the others are encoded", () => {
  assert.equal(buildQuery({ user: "", action: " ", result: "" }), "");
  assert.equal(buildQuery({ user: "anna", action: "settings apply", limit: 50 }), "user=anna&action=settings+apply&limit=50");
});

test("the export keeps the filters and adds the format", () => {
  assert.equal(exportUrl({ user: "anna" }, "csv"), "/api/audit/export?user=anna&format=csv");
  assert.equal(exportUrl({}, "json"), "/api/audit/export?format=json");
});

test("a value that tries to add a parameter stays inside its own", () => {
  assert.equal(buildQuery({ user: "a&result=ok" }), "user=a%26result%3Dok");
});

test("describe turns a route template into what was done", () => {
  const tpl = "POST /api/components/{id}/{action}";
  assert.equal(describe(tpl, "/api/components/ntopng/restart"), "Restart ntopng");
  assert.equal(describe(tpl, "/api/components/suricata/stop"), "Stop suricata");
  assert.equal(describe("POST /api/login", "/api/login"), "Sign in");
  assert.equal(describe("POST /api/update", "/api/update"), "Update the panel");
});

test("describe keeps the recorded action for an entry it does not know", () => {
  assert.equal(describe("POST /api/rules/update", "/api/rules/update"), "POST /api/rules/update");
  assert.equal(describe("cli self-update", "apply"), "cli self-update");
  assert.equal(describe(undefined, undefined), "");
});
