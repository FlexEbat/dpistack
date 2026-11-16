// Opens every screen of the panel at three widths in headless Chromium, writes
// a screenshot of each and fails when a screen scrolls sideways or the page
// throws. Usage: node check.mjs <panel url> <output directory>
import fs from "node:fs";
import chromium from "@sparticuz/chromium";
import puppeteer from "puppeteer-core";

const [url = "http://127.0.0.1:9800/", out = "shots"] = process.argv.slice(2);
fs.mkdirSync(out, { recursive: true });

const WIDTHS = [
  [390, 844],
  [768, 1024],
  [1440, 900],
];
const VIEWS = ["overview", "network", "traffic", "events", "metrics", "alerts", "rules", "exceptions", "ips", "components", "logs", "tests", "backups", "configs", "settings"];

const browser = await puppeteer.launch({
  args: [...chromium.args, "--no-sandbox"],
  executablePath: await chromium.executablePath(),
  headless: "shell",
});
const page = await browser.newPage();
const problems = [];
page.on("pageerror", (e) => problems.push(`script error: ${e.message}`));

await page.setViewport({ width: 1440, height: 900 });
await page.goto(url, { waitUntil: "networkidle0" });
await page.type("#password", "correct horse");
await page.click("#login-form button[type=submit]");
await new Promise((r) => setTimeout(r, 2500));

for (const [w, h] of WIDTHS) {
  await page.setViewport({ width: w, height: h });
  for (const v of VIEWS) {
    const found = await page.evaluate((v) => {
      const b = document.querySelector(`button[data-view="${v}"]`);
      if (b) b.click();
      return !!b;
    }, v);
    if (!found) continue; // a screen that this build does not have
    await new Promise((r) => setTimeout(r, 900));
    const o = await page.evaluate(() => ({
      sw: document.documentElement.scrollWidth,
      cw: document.documentElement.clientWidth,
      note: document.querySelector(".devnote-top")?.getBoundingClientRect().top ?? -1,
    }));
    if (o.sw > o.cw) problems.push(`${v} at ${w}px scrolls sideways (${o.sw} > ${o.cw})`);
    if (o.note !== 0) problems.push(`${v} at ${w}px: the note is not at the very top (${o.note})`);
    await page.screenshot({ path: `${out}/${v}-${w}.png` });
  }
}
await browser.close();

if (problems.length) {
  console.error("ui-check FAILED:\n" + [...new Set(problems)].join("\n"));
  process.exit(1);
}
console.log(`ui-check ok: ${VIEWS.length} screens at ${WIDTHS.map((x) => x[0]).join(", ")} px, shots in ${out}`);
