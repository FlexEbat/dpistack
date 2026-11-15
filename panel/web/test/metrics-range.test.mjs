import test from "node:test";
import assert from "node:assert/strict";
import { parseHours } from "../modules/metrics.js";

test("an own period is a whole number of hours from 1 to 24", () => {
  for (const [text, want] of [["12", 12], [" 3 ", 3], ["12h", 12], ["24H", 24], ["1", 1], ["07", 7]]) {
    assert.equal(parseHours(text), want, text);
  }
  for (const bad of ["", "0", "25", "1.5", "-3", "abc", "100", "1d", null, undefined]) {
    assert.equal(parseHours(bad), null, String(bad));
  }
});
