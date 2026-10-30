import { test } from "node:test";
import assert from "node:assert/strict";
import { REVEAL_SELECTOR, revealOnce, menu } from "../modules/chrome.js";

class FakeClasses {
  constructor() { this.set = new Set(); }
  add(c) { this.set.add(c); }
  toggle(c, on) { if (on) this.set.add(c); else this.set.delete(c); }
  contains(c) { return this.set.has(c); }
}
const node = () => ({ classList: new FakeClasses() });

test("revealOnce marks blocks, reveals each once and stops watching it", () => {
  const nodes = [node(), node()];
  let cb, observed = [], unobserved = [];
  class Fake {
    constructor(fn) { cb = fn; }
    observe(n) { observed.push(n); }
    unobserve(n) { unobserved.push(n); }
    disconnect() {}
  }
  const root = { querySelectorAll: (sel) => (sel === REVEAL_SELECTOR ? nodes : []) };
  revealOnce(root, Fake);
  assert.deepEqual(observed, nodes);
  assert.ok(nodes.every((n) => n.classList.contains("js-reveal") && !n.classList.contains("in")));
  cb([{ isIntersecting: false, target: nodes[0] }, { isIntersecting: true, target: nodes[1] }]);
  assert.ok(!nodes[0].classList.contains("in"));
  assert.ok(nodes[1].classList.contains("in"));
  assert.deepEqual(unobserved, [nodes[1]]);
});

test("without IntersectionObserver nothing is hidden", () => {
  const n = node();
  revealOnce({ querySelectorAll: () => [n] }, undefined);
  assert.ok(!n.classList.contains("js-reveal"));
});

test("the menu toggles on click, closes on Escape and on demand, and keeps aria-expanded true to the state", () => {
  const attrs = new Map();
  const nav = {
    toggleAttribute(name, on) { if (on) attrs.set(name, ""); else attrs.delete(name); },
    hasAttribute: (name) => attrs.has(name),
  };
  let click, key, focused = false, expanded = "false";
  const toggle = {
    addEventListener: (type, fn) => { if (type === "click") click = fn; },
    setAttribute: (n, v) => { if (n === "aria-expanded") expanded = v; },
    focus: () => { focused = true; },
  };
  const root = new FakeClasses();
  const doc = {
    getElementById: (id) => (id === "nav" ? nav : id === "menu-toggle" ? toggle : null),
    addEventListener: (type, fn) => { if (type === "keydown") key = fn; },
    documentElement: { classList: root },
  };
  const m = menu(doc);
  click();
  assert.equal(expanded, "true");
  assert.ok(nav.hasAttribute("data-open") && root.contains("menu-open"));
  key({ key: "Escape" });
  assert.equal(expanded, "false");
  assert.ok(!nav.hasAttribute("data-open") && focused);
  click();
  m.close();
  assert.equal(expanded, "false");
  assert.ok(!root.contains("menu-open"));
});
