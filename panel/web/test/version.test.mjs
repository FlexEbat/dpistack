// The corner badge: quiet without an update, glowing with one, and the
// dialog texts. Pure functions, no DOM.
import { test } from "node:test";
import assert from "node:assert/strict";
import { badge, question, progress } from "../modules/version.js";

test("no answer shows nothing", () => {
  assert.equal(badge(null).visible, false);
  assert.equal(badge({}).visible, false);
});

test("the running version is shown, quietly", () => {
  const b = badge({ version: "0.25.2", update_available: false });
  assert.deepEqual([b.text, b.update, b.visible], ["v0.25.2", false, true]);
});

test("a newer release makes the badge glow and says which", () => {
  const b = badge({ version: "0.25.2", latest: "0.26.0", update_available: true });
  assert.equal(b.update, true);
  assert.match(b.title, /v0\.26\.0/);
});

test("a failed check is only a hint in the tooltip", () => {
  const b = badge({ version: "0.25.2", update_available: false, check_error: "could not reach the release server" });
  assert.equal(b.update, false);
  assert.match(b.title, /could not reach/);
});

test("the question names both versions and promises the settings stay", () => {
  const q = question({ version: "0.25.2", latest: "0.26.0" });
  assert.match(q, /v0\.25\.2/);
  assert.match(q, /v0\.26\.0/);
  assert.match(q, /settings are kept/);
});

test("progress follows the unit", () => {
  assert.equal(progress({ state: "active" }), "Updating…");
  assert.match(progress({ state: "inactive", result: "success" }), /Updated/);
  assert.match(progress({ state: "failed", result: "exit-code" }), /failed/);
  assert.equal(progress(null), "Starting…");
});
