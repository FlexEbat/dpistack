// The corner badge: quiet without an update, glowing with one, and the
// dialog texts. Pure functions, no DOM.
import { test } from "node:test";
import assert from "node:assert/strict";
import { badge, question, progress, facts, when } from "../modules/version.js";

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

test("the Build info rows: only what is known, the commit shortened and copyable", () => {
  assert.deepEqual(facts(null), []);
  assert.deepEqual(facts({ version: "0.31.1" }), [["Version", "v0.31.1"]]);
  const full = "a70ec9a1b2c3d4e5f60718293a4b5c6d7e8f9012";
  const rows = facts({
    version: "0.31.1",
    latest: "0.32.0",
    build: { commit: full, time: "2026-11-03T12:00:00Z", go: "go1.27.3", platform: "linux/amd64" },
  });
  assert.deepEqual(rows, [
    ["Version", "v0.31.1"],
    ["Build time", "2026-11-03 12:00:00 UTC"],
    ["Commit", "a70ec9a1b2c3", full],
    ["Runtime", "go1.27.3 on linux/amd64"],
    ["Latest release", "v0.32.0"],
  ]);
});

test("when keeps a time it cannot read as it came", () => {
  assert.equal(when("2026-11-03T12:00:00+03:00"), "2026-11-03T12:00:00+03:00");
  assert.equal(when(""), "");
});
