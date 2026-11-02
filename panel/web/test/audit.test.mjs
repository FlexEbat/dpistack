import { test } from "node:test";
import assert from "node:assert/strict";
import { buildQuery, exportUrl } from "../modules/audit.js";

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
