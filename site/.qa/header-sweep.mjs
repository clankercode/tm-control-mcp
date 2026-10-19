// Header geometry probe: every width in [lo,hi], both moods. Own headless Chromium.
// Usage: PLAYWRIGHT_MODULE=<dir> node probe.mjs <url> [lo] [hi] [shotWidths,comma,sep]
import { pathToFileURL } from "node:url";
import fs from "node:fs";
const { chromium } = await import(pathToFileURL(process.env.PLAYWRIGHT_MODULE + "/index.mjs").href);
const [base, lo = "320", hi = "1440", shotsArg = ""] = process.argv.slice(2);
const shotWidths = shotsArg ? shotsArg.split(",").map(Number) : [];
fs.mkdirSync("/tmp/hdrqa/shots", { recursive: true });
const browser = await chromium.launch();
const fails = []; const report = {};
for (const scheme of ["dark", "light"]) {
  const page = await browser.newPage({ viewport: { width: +hi, height: 700 }, colorScheme: scheme, reducedMotion: "reduce" });
  await page.goto(base, { waitUntil: "networkidle" });
  await page.evaluate(() => document.fonts.ready);
  for (let w = +lo; w <= +hi; w++) {
    await page.setViewportSize({ width: w, height: 700 });
    const r = await page.evaluate(() => {
      const vw = innerWidth, out = { issues: [] };
      const R = el => el.getBoundingClientRect();
      const ulEl = document.querySelector(".nav ul");
      // Only a scrolling strip clips its links; a visible-overflow nav must not hide spill-over.
      const clip = getComputedStyle(ulEl).overflowX === "visible" ? { left: -1e9, right: 1e9 } : R(ulEl);
      const items = [["brand", document.querySelector(".brand")], ["gh", document.querySelector(".bar__gh")], ["mood", document.querySelector(".mood")]]
        .filter(([, e]) => e && getComputedStyle(e).display !== "none");
      for (const a of document.querySelectorAll(".nav a")) items.push([a.textContent.trim(), a, true]);
      const boxes = [];
      for (const [n, e, inNav] of items) {
        const b = R(e); let l = b.left, rr = b.right;
        if (inNav) { l = Math.max(l, clip.left); rr = Math.min(rr, clip.right); }
        if (rr - l < 8) continue; // (almost) scrolled out of the nav strip: intended on mobile
        if (l < -0.5 || rr > vw + 0.5) out.issues.push(`${n} out of viewport ${l.toFixed(1)}..${rr.toFixed(1)}`);
        boxes.push({ n, l, r: rr, t: b.top, b: b.bottom, e, inNav: !!inNav, full: !inNav || (b.left >= clip.left - 0.5 && b.right <= clip.right + 0.5) });
      }
      for (let i = 0; i < boxes.length; i++) for (let j = i + 1; j < boxes.length; j++) {
        const a = boxes[i], c = boxes[j];
        const ox = Math.min(a.r, c.r) - Math.max(a.l, c.l), oy = Math.min(a.b, c.b) - Math.max(a.t, c.t);
        if (ox > 0.5 && oy > 0.5) out.issues.push(`overlap ${a.n}/${c.n} ${ox.toFixed(1)}px`);
      }
      for (const bx of boxes) {
        const x = (bx.l + bx.r) / 2, y = (bx.t + bx.b) / 2, hit = document.elementFromPoint(x, y);
        if (!hit || !(bx.e === hit || bx.e.contains(hit))) out.issues.push(`hit ${bx.n} @${x.toFixed(0)},${y.toFixed(0)} -> ${hit ? (hit.className?.baseVal ?? hit.className) || hit.tagName : "null"}`);
      }
      if (document.documentElement.scrollWidth > vw) out.issues.push(`scrollWidth ${document.documentElement.scrollWidth}`);
      out.barH = Math.round(R(document.querySelector(".bar")).height);
      out.rows = R(document.querySelector(".nav")).top > R(document.querySelector(".brand")).bottom - 1 ? 2 : 1;
      const nav = boxes.filter(b => b.inNav);
      out.navAllVisible = nav.length === 5 && nav.every(b => b.full);
      const last = R(document.querySelector(".nav li:last-child a")), tools = R(document.querySelector(".bar__tools"));
      out.navToToolsGap = Math.round(tools.left - last.right);
      if (out.rows === 1 && out.navToToolsGap < 12) out.issues.push(`nav->tools gap ${out.navToToolsGap}px`);
      if (out.rows === 1 && !out.navAllVisible) out.issues.push("single row but a nav link is clipped");
      for (const a of document.querySelectorAll(".nav a")) if (R(a).height > 48) out.issues.push(`${a.textContent.trim()} wraps (h=${Math.round(R(a).height)})`);
      const brandName = R(document.querySelector(".brand__name"));
      if (brandName.height > 24) out.issues.push(`brand wraps (h=${Math.round(brandName.height)})`);
      out.boxes = boxes.map(b => `${b.n}:${b.l.toFixed(0)}-${b.r.toFixed(0)}x${b.t.toFixed(0)}-${b.b.toFixed(0)}`).join(" | ");
      return out;
    });
    report[`${scheme}-${w}`] = r;
    if (r.issues.length) fails.push(`${scheme} ${w}: ${r.issues.join("; ")}`);
    if (shotWidths.includes(w)) await page.screenshot({ path: `/tmp/hdrqa/shots/${scheme}-${w}.png`, clip: { x: 0, y: 0, width: w, height: 140 } });
  }
  await page.close();
}
await browser.close();
fs.writeFileSync("/tmp/hdrqa/report.json", JSON.stringify(report, null, 1));
console.log(`checked ${lo}-${hi} x2 moods; failing widths: ${fails.length}`);
for (const f of fails) console.log(f);
