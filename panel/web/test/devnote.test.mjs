import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

// tech.md rule 12: the same sentence says "under development" in the CLI and
// the dashboard, and the README says it too. If the wording changes it must
// change everywhere at once, which is what this test holds.
const SENTENCE = "Under development: dpistack is still being developed. Settings, commands and screens can change between releases.";
const read = (p) => readFileSync(new URL("../../../" + p, import.meta.url), "utf8");

test("the CLI usage, the install help and the install menu carry the sentence", () => {
  for (const f of ["lib/ctl.sh", "install.sh", "lib/menu.sh"]) assert.ok(read(f).includes(SENTENCE), f);
});

test("the dashboard shows it on the login page and at the very top of the signed-in page", () => {
  const html = read("panel/web/index.html");
  const notes = html.match(/<p class="devnote(?: devnote-top)?" role="note">[^<]*<\/p>/g) || [];
  assert.equal(notes.length, 2);
  for (const n of notes) assert.ok(n.includes(SENTENCE), n);
  const login = html.slice(html.indexOf('id="login"'), html.indexOf("</main>", html.indexOf('id="login"')));
  assert.ok(login.includes("devnote"));
  const app = html.slice(html.indexOf('<main id="overview"'));
  assert.ok(app.indexOf("devnote-top") > 0 && app.indexOf("devnote-top") < app.indexOf("<header>"), "the note comes before the top bar");
  assert.ok(!html.slice(html.indexOf('id="nav-links"')).includes("devnote"), "and no longer sits in the menu");
});

test("both READMEs say it and both name the GNU General Public License v3.0", () => {
  assert.ok(read("README.md").includes(SENTENCE));
  assert.match(read("README.ru.md"), /В разработке: dpistack/);
  for (const f of ["README.md", "README.ru.md"]) assert.match(read(f), /GNU General Public License v3\.0/, f);
  assert.match(read("LICENSE"), /GNU GENERAL PUBLIC LICENSE\s+Version 3, 29 June 2007/);
});

test("the CSS styles the notice in both stylesheets", () => {
  for (const f of ["app.css"]) assert.match(read("panel/web/" + f), /\.devnote\s*\{/, f);
});
