import test from "node:test";
import assert from "node:assert/strict";
import { nextIndex, remembered } from "../modules/tabs.js";

test("the arrow keys go round the tabs, Home and End go to the ends, other keys do nothing", () => {
  assert.equal(nextIndex(4, 0, "ArrowRight"), 1);
  assert.equal(nextIndex(4, 3, "ArrowRight"), 0);
  assert.equal(nextIndex(4, 0, "ArrowLeft"), 3);
  assert.equal(nextIndex(4, 2, "Home"), 0);
  assert.equal(nextIndex(4, 0, "End"), 3);
  assert.equal(nextIndex(4, 1, "a"), -1);
  assert.equal(nextIndex(0, 0, "ArrowRight"), -1);
});

test("a remembered tab is used only when it still exists", () => {
  const names = ["overview", "find", "sources", "custom"];
  assert.equal(remembered(names, "custom"), "custom");
  assert.equal(remembered(names, "gone"), null);
  assert.equal(remembered(names, null), null);
  assert.equal(remembered(names, ""), null);
});
