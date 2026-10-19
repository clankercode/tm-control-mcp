// QA + asset renderer for site/. Own headless Playwright Chromium (launched and
// closed here); never attaches to a shared CDP browser.
// Usage: node site/.qa/render.mjs <baseUrl> <outDir> [shots|icons|og]
//   icons: baseUrl unused; writes favicon-32.png + apple-touch-icon.png from assets/favicon.svg
//   og:    baseUrl = URL/path of og-source.html; writes og-image.png (1200x630)
// Needs Playwright with Chromium. Resolution order: $PLAYWRIGHT_MODULE (path to a
// playwright package dir or its index.mjs), then "playwright" resolved from the
// current working directory (e.g. `npm i --no-save playwright && npx playwright install chromium`).
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";
import fs from "node:fs";

async function loadPlaywright() {
  const tries = [];
  if (process.env.PLAYWRIGHT_MODULE) tries.push(process.env.PLAYWRIGHT_MODULE);
  try { tries.push(createRequire(path.join(process.cwd(), "noop.js")).resolve("playwright")); } catch {}
  for (const t of tries) {
    try {
      const p = fs.statSync(t).isDirectory() ? path.join(t, "index.mjs") : t;
      return await import(pathToFileURL(p).href);
    } catch {}
  }
  throw new Error("Playwright not found: set PLAYWRIGHT_MODULE or install `playwright` where you run this");
}
const { chromium } = await loadPlaywright();

const [base, outDir, mode = "shots"] = process.argv.slice(2);
const here = path.dirname(fileURLToPath(import.meta.url));
const site = path.resolve(here, "..");
fs.mkdirSync(outDir, { recursive: true });

const browser = await chromium.launch();
try {
  if (mode === "icons") {
    const svg = fs.readFileSync(path.join(site, "assets/favicon.svg"), "utf8")
      .replace("<svg ", '<svg width="100%" height="100%" style="display:block" ');
    for (const [size, name, bg] of [[32, "favicon-32.png", false], [180, "apple-touch-icon.png", true]]) {
      const page = await browser.newPage({ viewport: { width: size, height: size } });
      await page.setContent(`<html><body style="margin:0;width:${size}px;height:${size}px;background:${bg ? "#0b6e43" : "transparent"}">${svg}</body></html>`);
      await page.waitForTimeout(150);
      await page.screenshot({ path: path.join(outDir, name), omitBackground: !bg });
      await page.close();
    }
  } else if (mode === "og") {
    const page = await browser.newPage({ viewport: { width: 1200, height: 630 } });
    await page.goto(base, { waitUntil: "networkidle" });
    await page.evaluate(() => document.fonts.ready);
    await page.screenshot({ path: path.join(outDir, "og-image.png") });
    await page.close();
  } else {
    const shots = [
      ["desktop-1440-night", 1440, 1000, "dark", true],
      ["desktop-1440-day", 1440, 1000, "light", true],
      ["tablet-1024-night", 1024, 768, "dark", true],
      ["mobile-390-night", 390, 844, "dark", true],
      ["mobile-390-day", 390, 844, "light", true],
      ["narrow-320-night", 320, 640, "dark", true],
      ["narrow-320-day", 320, 640, "light", true],
    ];
    const report = [];
    for (const [name, w, h, scheme, full] of shots) {
      const ctx = await browser.newContext({ viewport: { width: w, height: h }, colorScheme: scheme, reducedMotion: "reduce" });
      const page = await ctx.newPage();
      const errors = [];
      page.on("pageerror", (e) => errors.push(String(e)));
      page.on("console", (m) => { if (m.type() === "error") errors.push(m.text()); });
      await page.goto(base, { waitUntil: "networkidle" });
      await page.evaluate(() => document.fonts.ready);
      await page.screenshot({ path: path.join(outDir, name + "-top.png") });
      if (full) await page.screenshot({ path: path.join(outDir, name + "-full.png"), fullPage: true });
      const geo = await page.evaluate(() => {
        const vw = document.documentElement.clientWidth;
        const over = [];
        for (const el of document.querySelectorAll("body *")) {
          const r = el.getBoundingClientRect();
          if (r.width === 0 || r.height === 0) continue;
          if (el.closest(".nav ul, .table-scroll, pre, .sr-only, .skip, .mood, .bar__gh")) continue;
          if (r.right > vw + 0.5 || r.left < -0.5) over.push(el.tagName + "." + el.className + " [" + Math.round(r.left) + "," + Math.round(r.right) + "]");
        }
        const fonts = [...document.fonts].filter((f) => f.status === "loaded").map((f) => f.family + " " + f.style + " " + f.weight);
        return { scrollW: document.documentElement.scrollWidth, vw, over: over.slice(0, 12), fonts,
                 version: (document.querySelector("[data-version-chip]") || {}).textContent,
                 file: (document.querySelector("[data-latest-file]") || {}).textContent };
      });
      report.push({ name, errors, ...geo });
      await ctx.close();
    }
    fs.writeFileSync(path.join(outDir, "report.json"), JSON.stringify(report, null, 2));
    console.log(JSON.stringify(report, null, 2));
  }
} finally {
  await browser.close();
}
