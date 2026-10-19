// Interaction-state captures for QA: keyboard focus on the trace, CP3 selected,
// copy feedback, no-JS rendering. Own headless Chromium; launched and closed here.
// Usage: PLAYWRIGHT_MODULE=... node site/.qa/states.mjs <baseUrl> <outDir>
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";
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
const [rawBase, outDir] = process.argv.slice(2);
const base = /^[a-z][a-z0-9+.-]*:/i.test(rawBase || "") ? rawBase : pathToFileURL(path.resolve(rawBase || ".")).href;
fs.mkdirSync(outDir, { recursive: true });
const browser = await chromium.launch();
const log = [];
try {
  for (const [name, w, h, scheme] of [["desk", 1440, 1000, "dark"], ["mob", 390, 844, "light"], ["narrow", 320, 640, "dark"]]) {
    const ctx = await browser.newContext({ viewport: { width: w, height: h }, colorScheme: scheme, permissions: ["clipboard-read", "clipboard-write"] });
    const page = await ctx.newPage();
    await page.goto(base, { waitUntil: "networkidle" });
    await page.evaluate(() => document.fonts.ready);
    await page.focus("#gate-0");
    await page.keyboard.press("ArrowRight");
    await page.keyboard.press("ArrowRight");
    await page.keyboard.press("ArrowRight");
    await page.waitForTimeout(400);
    const trace = page.locator("[data-trace]");
    await trace.screenshot({ path: path.join(outDir, `${name}-trace-cp3-focus.png`) });
    const st = await page.evaluate(() => ({
      selected: document.querySelector('[role=tab][aria-selected=true]').id,
      focused: document.activeElement.id,
      count: document.querySelector("[data-trace-count]").textContent,
      visiblePanels: [...document.querySelectorAll(".step")].filter((s) => !s.hidden).length,
      car: getComputedStyle(document.querySelector("[data-trace-car]")).width,
    }));
    await page.click(".step:not([hidden]) .copy");
    await page.waitForTimeout(150);
    await trace.screenshot({ path: path.join(outDir, `${name}-trace-copied.png`) });
    let clip = null;
    try { clip = await page.evaluate(() => navigator.clipboard.readText()); } catch (e) { clip = "ERR " + e; }
    await page.keyboard.press("End");
    await page.focus(".btn--signal");
    await page.keyboard.press("Shift+Tab"); await page.keyboard.press("Tab");
    await page.locator(".cta").screenshot({ path: path.join(outDir, `${name}-cta-focus.png`) });
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.focus('.nav a[href="#updates"]');
    await page.keyboard.press("Shift+Tab"); await page.keyboard.press("Tab");
    await page.locator(".bar").screenshot({ path: path.join(outDir, `${name}-nav-updates-focus.png`) });
    const navEnd = await page.evaluate(() => {
      const a = document.querySelector('.nav a[href="#updates"]').getBoundingClientRect();
      return { left: Math.round(a.left), right: Math.round(a.right), vw: document.documentElement.clientWidth };
    });
    log.push({ name, ...st, clip, navEnd });
    await ctx.close();
  }
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, javaScriptEnabled: false, colorScheme: "dark" });
  const page = await ctx.newPage();
  await page.goto(base, { waitUntil: "networkidle" });
  await page.locator("[data-trace]").screenshot({ path: path.join(outDir, "nojs-trace.png") });
  log.push({ name: "nojs", steps: await page.locator(".step").count(),
    visibleSteps: await page.locator(".step:visible").count(),
    navVisible: await page.locator("[data-trace-nav]").isVisible(),
    moodVisible: await page.locator("[data-mood-toggle]").isVisible() });
  await ctx.close();
} finally {
  await browser.close();
}
console.log(JSON.stringify(log, null, 2));
