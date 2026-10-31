// The design rules of tech.md 9.1 (the landing page design skill) as tests:
// they read the stylesheets and the page and fail when a rule is broken, so
// the look cannot drift back to ad hoc values. There is no browser in CI, so
// what a browser would render is checked by the rules, not by pixels.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const web = join(dirname(fileURLToPath(import.meta.url)), "..");
const read = (f) => readFileSync(join(web, f), "utf8");
const SHEETS = { "full.css": read("full.css"), "lite.css": read("lite.css") };

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
const SPACING = ["0", "2px", "4px", "8px", "12px", "16px", "24px", "32px", "40px", "48px", "64px", "80px", "96px"];
const TYPE = {
  xs: ["0.75rem", "1rem"], sm: ["0.875rem", "1.25rem"], base: ["1rem", "1.5rem"], lg: ["1.125rem", "1.75rem"],
  xl: ["1.25rem", "1.75rem"], "2xl": ["1.5rem", "2rem"], "3xl": ["1.875rem", "2.25rem"],
};
const RADII = ["2px", "4px", "6px", "8px", "12px", "16px", "24px", "32px", "9999px"];
const DARK_BG = ["#000000", "#181818", "#1F1F1F", "#272727", "#313131", "#131209"];

test("the fonts: Geist only in the full edition, no banned family anywhere, no italics", () => {
  for (const [name, css] of Object.entries(SHEETS)) {
    assert.doesNotMatch(css, /\b(Inter|Roboto|Arial|Open Sans|Helvetica)\b/i, name);
    assert.doesNotMatch(css, /font-style:\s*(italic|oblique)/, name);
  }
  assert.match(SHEETS["full.css"], /--sans:\s*"Geist"/);
  assert.match(SHEETS["full.css"], /--mono:\s*"Geist Mono"/);
  for (const f of ["fonts/geist.woff2", "fonts/geist-mono.woff2", "fonts/OFL.txt"]) assert.ok(existsSync(join(web, f)), f);
  assert.match(SHEETS["full.css"], /url\("fonts\/geist\.woff2"\)/);
});

test("no weight above bold (700), no ultra bold", () => {
  each((name, r) => {
    if (r.selector.startsWith("@font-face")) return;
    for (const [p, v] of r.decls) {
      const w = p === "font-weight" ? v : p === "font" ? v.match(/^(\d{3})\b/)?.[1] : null;
      if (w) assert.ok(Number(w) <= 700, `${name} ${r.selector}: ${p} ${v}`);
    }
  });
});

test("the type scale: tokens are the Tailwind steps, every size resolves to a token", () => {
  for (const [name, css] of Object.entries(SHEETS)) {
    for (const [step, [size, lh]] of Object.entries(TYPE)) {
      if (css.includes(`--text-${step}:`)) {
        assert.match(css, new RegExp(`--text-${step}:\\s*${size.replace(".", "\\.")}`), `${name} ${step} size`);
        assert.match(css, new RegExp(`--lh-${step}:\\s*${lh.replace(".", "\\.")}`), `${name} ${step} line height`);
      }
    }
  }
  each((name, r) => {
    if (r.selector === ":root") return;
    for (const [p, v] of r.decls) {
      if (p === "font-size") assert.match(v, /^var\(--text-(xs|sm|base|lg|xl|2xl|3xl)\)$/, `${name} ${r.selector}`);
      if (p === "font" && /\//.test(v)) assert.match(v, /var\(--text-[\w]+\)\/var\(--lh-[\w]+\)/, `${name} ${r.selector}: ${v}`);
    }
  });
});

test("the spacing table: the tokens are exactly the table, spacing properties use only tokens", () => {
  for (const [name, css] of Object.entries(SHEETS)) {
    const got = [...css.matchAll(/--s-\d+:\s*([^;]+);/g)].map((m) => m[1].trim());
    assert.deepEqual(got, SPACING, name);
  }
  const prop = /^(padding|margin|gap|row-gap|column-gap)(-(top|right|bottom|left))?$/;
  each((name, r) => {
    if (r.selector === ":root") return;
    for (const [p, v] of r.decls) {
      if (!prop.test(p)) continue;
      const parts = v.replace(/calc\(var\(--s-\d+\) \* -1\)/g, "var(--s-0)").split(/\s+/);
      for (const part of parts) {
        assert.ok(part === "0" || part === "auto" || /^var\(--s-(0|25|50|75|100|200|300|400|500|600|700|800|900)\)$/.test(part), `${name} ${r.selector}: ${p} ${v}`);
      }
    }
  });
});

test("main buttons: 8px by 12px padding and the base size", () => {
  for (const [name, rules] of Object.entries(PARSED)) {
    const base = rules.find((r) => /(^|,\s*)button(,|$)/.test(r.selector) && r.decls.some(([p]) => p === "padding"));
    assert.ok(base, name);
    assert.equal(base.decls.find(([p]) => p === "padding")[1], "var(--s-75) var(--s-100)", name);
    assert.match(base.decls.find(([p]) => p === "font")[1], /var\(--text-base\)\/var\(--lh-base\)/, name);
  }
});

test("radius: Tailwind values only", () => {
  for (const [name, css] of Object.entries(SHEETS)) {
    for (const m of css.matchAll(/--r-[\w]+:\s*([^;]+);/g)) assert.ok(RADII.includes(m[1].trim()), `${name} ${m[0]}`);
  }
  each((name, r) => {
    for (const [p, v] of r.decls) {
      if (p === "border-radius") assert.match(v, /^(0|var\(--r-(lg|xl|2xl|full)\))$/, `${name} ${r.selector}: ${v}`);
    }
  });
});

test("backgrounds are flat: a gradient only fills text, and only the heading uses it", () => {
  each((name, r) => {
    const has = r.decls.some(([, v]) => /gradient\(/.test(v));
    if (!has) return;
    // the dark scheme of lite only swaps the colours of the heading rule
    const swap = r.selector === "h1" && /prefers-color-scheme: dark/.test(r.atrule || "");
    assert.ok(swap || r.decls.some(([p, v]) => p === "background-clip" && v === "text"), `${name} ${r.selector}`);
    assert.match(r.selector, /^h1$/, `${name} ${r.selector}`);
    assert.ok(r.decls.every(([, v]) => !/radial|conic/.test(v)), name);
  });
  const dark = SHEETS["full.css"];
  assert.match(dark, /linear-gradient\(90deg, #FFFFFF, #9B9B9B\)/);
  assert.match(SHEETS["lite.css"], /linear-gradient\(90deg, #000000, #666666\)/);
  assert.match(SHEETS["lite.css"], /linear-gradient\(90deg, #FFFFFF, #9B9B9B\)/);
});

test("dark backgrounds come from the list of six", () => {
  const full = SHEETS["full.css"];
  for (const t of ["bg", "card", "card-2", "hover", "edge", "well"]) {
    const m = full.match(new RegExp(`--${t}:\\s*(#[0-9A-Fa-f]{6})`));
    assert.ok(m && DARK_BG.includes(m[1].toUpperCase()), `full ${t}`);
  }
  const darkBlock = SHEETS["lite.css"].match(/prefers-color-scheme: dark\)\s*\{\s*:root\s*\{([^}]*)\}/)[1];
  for (const t of ["bg", "card", "card-2", "border"]) {
    const m = darkBlock.match(new RegExp(`--${t}:\\s*(#[0-9A-Fa-f]{6})`));
    assert.ok(m && DARK_BG.includes(m[1].toUpperCase()), `lite dark ${t}`);
  }
  each((name, r) => {
    for (const [p, v] of r.decls) {
      if (p === "background" || p === "background-color") {
        assert.doesNotMatch(v, /#[0-9A-Fa-f]{3,6}\b/, `${name} ${r.selector}: literal colour in a background`);
      }
    }
  });
});

test("borders: never on one side of a card", () => {
  const sideOk = new Set(["nav", "th, td", ".setting", ".setting:first-of-type", "tr:last-child td"]);
  each((name, r) => {
    for (const [p] of r.decls) {
      if (/^border-(left|right|top|bottom)$/.test(p)) assert.ok(sideOk.has(r.selector), `${name} ${r.selector}: ${p}`);
    }
    for (const [p, v] of r.decls) {
      if (p === "box-shadow") assert.doesNotMatch(v, /inset\s+\d+px\s+0\s+0/, `${name} ${r.selector}: a one sided inset edge`);
    }
  });
});

test("motion: one curve, nothing under 200ms, only transform, opacity and colour change", () => {
  const ALLOWED = new Set(["transform", "opacity", "background-color", "border-color", "color", "visibility"]);
  each((name, r) => {
    for (const [p, v] of r.decls) {
      if (p === "transition" || p === "transition-property" || p === "animation" || p === "transition-timing-function" || p === "animation-timing-function") {
        assert.doesNotMatch(v, /(^|[\s,])(ease|ease-in|ease-out|ease-in-out|linear)(?=[\s,;]|$)/, `${name} ${r.selector}: ${v}`);
      }
      if (p === "transition") {
        assert.doesNotMatch(v, /\ball\b/, `${name} ${r.selector}`);
        for (const one of v.split(/,(?![^(]*\))/)) {
          const prop = one.trim().split(/\s+/)[0];
          assert.ok(ALLOWED.has(prop), `${name} ${r.selector}: animates ${prop}`);
          const dur = one.trim().split(/\s+/)[1];
          const ms = dur.endsWith("ms") ? parseFloat(dur) : parseFloat(dur) * 1000;
          if (prop !== "visibility") assert.ok(ms >= 200, `${name} ${r.selector}: ${dur}`);
        }
        assert.match(v, /var\(--ease\)/, `${name} ${r.selector}: no curve`);
      }
      if (p === "animation" && !/^none\b/.test(v)) assert.match(v, /var\(--ease\)/, `${name} ${r.selector}`);
    }
    if (r.atrule === "keyframes") {
      for (const f of r.frames) for (const [p] of f.decls) assert.ok(p === "opacity" || p === "transform", `${name} keyframes ${p}`);
    }
  });
  assert.match(SHEETS["full.css"], /--ease:\s*cubic-bezier\(0\.22, 1, 0\.36, 1\)/);
  assert.match(SHEETS["full.css"], /prefers-reduced-motion: reduce/);
});

test("the hero heading and its subheading are capped at 680px; headings balance, paragraphs stay pretty", () => {
  for (const [name, rules] of Object.entries(PARSED)) {
    const h1 = rules.find((r) => r.selector === "h1" && !r.atrule);
    assert.ok(h1.decls.some(([p, v]) => p === "max-width" && v === "680px"), name);
    const sub = rules.find((r) => r.selector === "header .titles p");
    assert.ok(sub.decls.some(([p, v]) => p === "max-width" && v === "680px"), name);
    assert.ok(rules.find((r) => r.selector === "h1, h2, h3").decls.some(([p, v]) => p === "text-wrap" && v === "balance"), name);
    assert.ok(rules.find((r) => r.selector === "p").decls.some(([p, v]) => p === "text-wrap" && v === "pretty"), name);
  }
});

test("states: focus ring, active press, skeleton, empty state", () => {
  for (const [name, css] of Object.entries(SHEETS)) {
    assert.match(css, /:focus-visible/, name);
    assert.match(css, /button:active:not\(:disabled\)\s*\{[^}]*scale\(0\.98\)/, name);
    assert.match(css, /\.skeleton/, name);
    assert.match(css, /\.muted\.empty/, name);
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
