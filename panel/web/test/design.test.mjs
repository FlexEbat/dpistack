// The design rules of tech.md 9.1 (the Aurora NOC design, v0.47.0) as tests:
// they read the stylesheets and the page and fail when a rule is broken, so
// the look cannot drift into ad hoc values. There is no browser in CI, so
// what a browser would render is checked by the rules, not by pixels.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const web = join(dirname(fileURLToPath(import.meta.url)), "..");
const read = (f) => readFileSync(join(web, f), "utf8");
const SHEETS = { "app.css": read("app.css") };

// parse reads a stylesheet into rules {selector, decls, atrule}. Only what
// these sheets use: nested @media, @font-face and @keyframes.
function parse(css) {
  css = css.replace(/\/\*[\s\S]*?\*\//g, "");
  const rules = [];
  function block(text, atrule) {
    let i = 0;
    while (i < text.length) {
      const open = text.indexOf("{", i);
      if (open < 0) break;
      const selector = text.slice(i, open).trim();
      let depth = 1, j = open + 1;
      while (j < text.length && depth) {
        if (text[j] === "{") depth++;
        else if (text[j] === "}") depth--;
        j++;
      }
      const body = text.slice(open + 1, j - 1);
      if (selector.startsWith("@media")) block(body, selector);
      else if (selector.startsWith("@keyframes")) {
        rules.push({ selector, atrule: "keyframes", decls: [], frames: parse(body) });
      } else {
        const decls = [];
        // a value may hold ; inside quotes or url(...), none here do
        for (const d of body.split(";")) {
          const k = d.indexOf(":");
          if (k > 0) decls.push([d.slice(0, k).trim().toLowerCase(), d.slice(k + 1).trim()]);
        }
        rules.push({ selector, atrule, decls });
      }
      i = j;
    }
  }
  block(css, "");
  return rules;
}

const PARSED = Object.fromEntries(Object.entries(SHEETS).map(([k, v]) => [k, parse(v)]));
const each = (fn) => {
  for (const [name, rules] of Object.entries(PARSED)) for (const r of rules) fn(name, r);
};

const BANNED_FONTS = /\b(Inter|Roboto|Arial|Open Sans|Helvetica)\b/i;
const TOKEN_RULES = ["--bg", "--card", "--edge", "--text", "--muted", "--blue", "--cyan", "--green", "--amber", "--red", "--violet", "--ease"];
const classesOf = (css) => new Set([...css.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\{[^}]*\}/g, "{}").matchAll(/\.([a-zA-Z][\w-]*)/g)].map((m) => m[1]));

test("the fonts: Geist and Geist Mono bundled, no banned family, no italics", () => {
  for (const [name, css] of Object.entries(SHEETS)) {
    assert.doesNotMatch(css, BANNED_FONTS, name);
    assert.doesNotMatch(css, /font-style:\s*(italic|oblique)/, name);
  }
  assert.match(SHEETS["app.css"], /--sans:\s*"Geist"/);
  assert.match(SHEETS["app.css"], /--mono:\s*"Geist Mono"/);
  assert.match(SHEETS["app.css"], /url\("fonts\/geist\.woff2"\)/);
  for (const f of ["fonts/geist.woff2", "fonts/geist-mono.woff2", "fonts/OFL.txt"]) assert.ok(existsSync(join(web, f)), f);
});

test("no weight above bold (700)", () => {
  each((name, r) => {
    if (r.selector.startsWith("@font-face")) return;
    for (const [p, v] of r.decls) if (p === "font-weight") assert.ok(Number(v) <= 700, `${name} ${r.selector}: ${p} ${v}`);
  });
});

test("every colour of the design is a token: both sheets define the palette and the scheme", () => {
  for (const [name, css] of Object.entries(SHEETS)) for (const t of TOKEN_RULES) assert.match(css, new RegExp(`${t}:`), `${name} ${t}`);
  assert.match(SHEETS["app.css"], /color-scheme:\s*dark/, "the panel is dark by design");
});

test("the type scale: font sizes are tokens, except inside the SVG drawings", () => {
  each((name, r) => {
    if (r.selector.startsWith("@")) return;
    for (const [p, v] of r.decls) {
      if (p !== "font-size") continue;
      if (/^\.(chart|ring|radar)/.test(r.selector)) continue;
      assert.match(v, /^(0|var\(--t-[a-z0-9]+\))$/, `${name} ${r.selector}: ${v}`);
    }
  });
});

test("spacing and radius stay on the grid: 4px steps (and 2px) for spacing, token radii", () => {
  const SPACING = ["padding", "margin", "gap", "row-gap", "column-gap"];
  each((name, r) => {
    for (const [p, v] of r.decls) {
      if (SPACING.some((s) => p === s || p.startsWith(s + "-")) && !p.startsWith("scroll")) {
        for (const px of v.matchAll(/(-?[\d.]+)px/g)) assert.ok(Number(px[1]) % 4 === 0 || Number(px[1]) === 2 || Number(px[1]) === 1, `${name} ${r.selector}: ${p} ${v}`);
      }
      if (p === "border-radius") assert.match(v, /^(0|50%|6px|var\(--r-(sm|md|lg|full)\))$/, `${name} ${r.selector}: ${v}`);
    }
  });
});

test("motion: colour and position changes take 200ms or more, nothing animates all, reduced motion is honoured", () => {
  each((name, r) => {
    if (r.atrule && r.atrule.includes("prefers-reduced-motion")) return;
    for (const [p, v] of r.decls) {
      if (p !== "transition") continue;
      assert.doesNotMatch(v, /\ball\b/, `${name} ${r.selector}: animates all`);
      for (const one of v.split(/,(?![^(]*\))/)) {
        const dur = one.trim().match(/\s(\d+)ms\b/);
        assert.ok(dur && Number(dur[1]) >= 200, `${name} ${r.selector}: ${one.trim()}`);
      }
    }
  });
  for (const [name, css] of Object.entries(SHEETS)) assert.match(css, /prefers-reduced-motion:\s*reduce/, name);
});

test("states: focus ring, active press, skeleton, empty state, hidden stays hidden", () => {
  for (const [name, css] of Object.entries(SHEETS)) {
    assert.match(css, /:focus-visible/, name);
    assert.match(css, /button:active:not\(:disabled\)\s*\{[^}]*scale\(0\.98\)/, name);
    assert.match(css, /\.skeleton/, name);
    assert.match(css, /\.empty/, name);
    assert.match(css, /\[hidden\]\s*\{\s*display:\s*none\s*!important/, name);
  }
});

test("the sheets load nothing from the network", () => {
  for (const [name, css] of Object.entries(SHEETS)) {
    assert.doesNotMatch(css, /@import|url\(\s*["']?https?:/, name);
  }
});

test("the page and the scripts use only classes that the stylesheet knows", () => {
  const known = classesOf(SHEETS["app.css"]);
  // names that mark state or behaviour for scripts, or are set by the models
  const plain = new Set(["fill", "in", "js-reveal", "static", "bad", "inactive", "na", "ok", "warn", "crit", "wide", "ico", "editor", "result", "log", "has-update", "bar-a", "bar-b", "bar-c", "mark", "version", "primary", "small", "clickable", "switch", "actions"]);
  const html = read("index.html");
  for (const m of html.matchAll(/class="([^"]+)"/g)) for (const c of m[1].split(/\s+/)) assert.ok(known.has(c) || plain.has(c), `index.html: .${c} has no style`);
});

test("the charts are drawn by the chart kit and styled by classes, never inline", () => {
  const charts = read("modules/charts.js");
  assert.doesNotMatch(charts, /setAttribute\(["']style["']|innerHTML|\bfetch\(/);
  for (const c of ["chart-line", "chart-area", "chart-grid", "chart-cursor", "chart-band", "chart-tip", "ring-fill", "donut-seg", "radar-shape", "stop-top", "stop-bottom"]) {
    assert.match(SHEETS["app.css"], new RegExp(`\\.${c}\\b`), c);
  }
});

test("the page: skip link, description, favicon, skeletons, Phosphor icons, no hyphens or exclamation marks in the text", () => {
  const html = read("index.html");
  assert.match(html, /id="skip"/);
  assert.match(html, /<meta name="description"/);
  assert.match(html, /<link rel="icon" href="favicon\.svg"/);
  assert.ok(existsSync(join(web, "favicon.svg")));
  assert.ok((html.match(/class="skeleton"/g) || []).length >= 5);
  assert.doesNotMatch(html, /material|Material/);
  assert.equal((html.match(/viewBox="0 0 256 256"/g) || []).length >= 12, true, "Phosphor icons use a 256 grid");
  const text = html.replace(/<(script|style)[\s\S]*?<\/\1>/g, "").replace(/<svg[\s\S]*?<\/svg>/g, "");
  for (const m of text.matchAll(/>([^<>]+)</g)) {
    const t = m[1].trim();
    if (!t) continue;
    assert.doesNotMatch(t, /[A-Za-z]-[A-Za-z]| - |!/, `text: ${t}`);
  }
  for (const m of text.matchAll(/(?:placeholder|aria-label|title)="([^"]*)"/g)) {
    if (m[1] === "emerging-p2p.rules") continue; // a file name, not copy
    assert.doesNotMatch(m[1], /[A-Za-z]-[A-Za-z]| - |!/, `attribute: ${m[1]}`);
  }
});

test("the settings descriptions have no hyphens inside the sentences", () => {
  for (const line of read("modules/settings-model.js").split("\n")) {
    const m = line.match(/^\s{2}[A-Z0-9_]+: "(.*)",?$/);
    if (m) assert.doesNotMatch(m[1], /[A-Za-z]-[A-Za-z]/, line);
  }
});

test("no alert() anywhere in the scripts", () => {
  for (const f of ["app.js", "modules/chrome.js"]) assert.doesNotMatch(read(f), /(^|[^.\w])alert\(/, f);
});
