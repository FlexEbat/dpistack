import test from "node:test";
import assert from "node:assert/strict";
import { niceMax, gridTicks, runs, smooth, areaGeometry, indexAt, polar, arcPath, donutSegments, radarPoints, shortNumber } from "../modules/charts.js";

test("niceMax rounds up to a readable top and never returns zero", () => {
  assert.equal(niceMax(0), 1);
  assert.equal(niceMax(-4), 1);
  assert.equal(niceMax(7), 10);
  assert.equal(niceMax(1.8), 2);
  assert.equal(niceMax(2.3), 2.5);
  assert.equal(niceMax(8186), 10000);
});

test("gridTicks runs from zero to the top in equal steps", () => {
  assert.deepEqual(gridTicks(100, 4), [0, 25, 50, 75, 100]);
});

test("runs splits at gaps so a missing stretch is not bridged", () => {
  assert.deepEqual(runs([1, 2, null, 3, undefined, NaN, 4, 5]), [[[0, 1], [1, 2]], [[3, 3]], [[6, 4], [7, 5]]]);
  assert.deepEqual(runs([]), []);
  assert.deepEqual(runs([null, null]), []);
});

test("smooth draws a curve through the points and survives one point or none", () => {
  assert.equal(smooth([]), "");
  assert.match(smooth([[1, 2]]), /^M1\.0,2\.0/);
  const d = smooth([[0, 10], [10, 0], [20, 5]]);
  assert.match(d, /^M0\.0,10\.0C/);
  assert.equal((d.match(/C/g) || []).length, 2);
});

test("areaGeometry keeps values in the box and closes each area on the baseline", () => {
  const g = areaGeometry([0, 5, 10], { w: 100, h: 50, pad: { t: 0, r: 0, b: 0, l: 0 }, max: 10 });
  assert.equal(g.top, 10);
  assert.equal(g.y(10), 0);
  assert.equal(g.y(0), 50);
  assert.equal(g.y(99), 0, "a value above the top is clamped");
  assert.equal(g.x(0), 0);
  assert.equal(g.x(2), 100);
  assert.equal(g.lines.length, 1);
  assert.match(g.areas[0], /Z$/);
  const gap = areaGeometry([1, null, 2], { w: 100, h: 50 });
  assert.equal(gap.lines.length, 2, "a gap makes two lines");
});

test("indexAt maps a pointer to the nearest value and clamps outside", () => {
  const box = { left: 10, width: 100 };
  assert.equal(indexAt(10, box, 11), 0);
  assert.equal(indexAt(110, box, 11), 10);
  assert.equal(indexAt(60, box, 11), 5);
  assert.equal(indexAt(-50, box, 11), 0);
  assert.equal(indexAt(900, box, 11), 10);
  assert.equal(indexAt(60, box, 1), 0);
});

test("polar puts 0 degrees at the top and 90 at the right", () => {
  const [x0, y0] = polar(50, 50, 10, 0);
  assert.ok(Math.abs(x0 - 50) < 1e-9 && Math.abs(y0 - 40) < 1e-9);
  const [x1, y1] = polar(50, 50, 10, 90);
  assert.ok(Math.abs(x1 - 60) < 1e-9 && Math.abs(y1 - 50) < 1e-9);
});

test("arcPath takes the long way only past 180 degrees", () => {
  assert.match(arcPath(60, 60, 44, 0, 90), / 0 0 1 /);
  assert.match(arcPath(60, 60, 44, 0, 270), / 0 1 1 /);
  assert.doesNotThrow(() => arcPath(60, 60, 44, 0, 720));
});

test("donutSegments share the circle by value, skip zeros and leave gaps", () => {
  assert.deepEqual(donutSegments([{ value: 0 }, { value: 0 }]), []);
  const one = donutSegments([{ value: 3 }, { value: 0 }]);
  assert.equal(one.length, 1);
  assert.equal(one[0].from, 0);
  assert.ok(Math.abs(one[0].to - 360) < 1e-9);
  const two = donutSegments([{ value: 1, tone: "ok" }, { value: 3, tone: "crit" }], 4);
  assert.equal(two.length, 2);
  assert.ok(Math.abs(two[0].share - 0.25) < 1e-9);
  assert.ok(two[1].from > two[0].to, "the segments do not touch");
  assert.ok(two[1].to <= 360);
});

test("radarPoints scale each axis by its value and clamp to the ring", () => {
  const p = radarPoints([1, 0, 2], 0, 0, 10);
  assert.equal(p.length, 3);
  assert.ok(Math.abs(Math.hypot(...p[0]) - 10) < 1e-9);
  assert.ok(Math.abs(Math.hypot(...p[1])) < 1e-9);
  assert.ok(Math.abs(Math.hypot(...p[2]) - 10) < 1e-9, "a value above 1 stays on the ring");
});

test("shortNumber keeps axis labels short", () => {
  assert.equal(shortNumber(0), "0");
  assert.equal(shortNumber(2.5), "2.5");
  assert.equal(shortNumber(1500), "1.5K");
  assert.equal(shortNumber(2e6), "2M");
  assert.equal(shortNumber(3.2e9), "3.2G");
});
