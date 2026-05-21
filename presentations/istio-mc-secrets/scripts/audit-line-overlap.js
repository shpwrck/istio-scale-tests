// Programmatic audit: no orthogonal arrow segment may run COINCIDENT with a
// rect border for more than 2 pixels. Catches "line lying on a box edge"
// violations of visual rule 4. Run from the deck directory:
//   node scripts/audit-line-overlap.js
// Requires playwright (npm i playwright; npx playwright install chromium).
const { chromium } = require('playwright');
const path = require('path');

function parsePath(d) {
  const tokens = d.split(/[\s,]+/).filter(Boolean);
  const segs = []; let cx = 0, cy = 0;
  let i = 0;
  while (i < tokens.length) {
    const cmd = tokens[i++];
    if (cmd === 'M') { cx = +tokens[i++]; cy = +tokens[i++]; }
    else if (cmd === 'H') { const nx = +tokens[i++]; segs.push({ x1: cx, y1: cy, x2: nx, y2: cy }); cx = nx; }
    else if (cmd === 'V') { const ny = +tokens[i++]; segs.push({ x1: cx, y1: cy, x2: cx, y2: ny }); cy = ny; }
    else if (cmd === 'L') { const nx = +tokens[i++], ny = +tokens[i++]; segs.push({ x1: cx, y1: cy, x2: nx, y2: ny }); cx = nx; cy = ny; }
  }
  return segs;
}

(async () => {
  const file = path.resolve(__dirname, '..', 'index.html');
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1920, height: 1080 } });
  const page = await ctx.newPage();
  await page.goto('file://' + file);
  await page.waitForFunction(() => window.Reveal && window.Reveal.isReady());
  await page.evaluate(() => Reveal.configure({ transition: 'none' }));

  const totalSlides = await page.evaluate(() => Reveal.getTotalSlides());
  const allViolations = [];
  for (let i = 0; i < totalSlides; i++) {
    await page.evaluate(n => Reveal.slide(n, 0, -1), i);
    const fragCount = await page.evaluate(() => Reveal.getCurrentSlide().querySelectorAll('.fragment').length);
    for (let f = 0; f < fragCount; f++) await page.evaluate(() => Reveal.nextFragment());
    await page.waitForTimeout(200);
    const data = await page.evaluate(() => {
      const svg = Reveal.getCurrentSlide().querySelector('svg.diagram');
      if (!svg) return null;
      const paths = [];
      for (const el of svg.querySelectorAll('path[d]')) {
        if (el.closest('marker')) continue;
        paths.push(el.getAttribute('d'));
      }
      const rects = [];
      for (const r of svg.querySelectorAll('rect')) {
        const x = +r.getAttribute('x'); const y = +r.getAttribute('y');
        const w = +r.getAttribute('width'); const h = +r.getAttribute('height');
        rects.push({ x, y, w, h, right: x + w, bottom: y + h });
      }
      return { paths, rects };
    });
    if (!data) continue;
    const tol = 1.0;
    data.paths.forEach((d, pi) => {
      const segs = parsePath(d);
      segs.forEach((s, si) => {
        const isH = s.y1 === s.y2;
        const isV = s.x1 === s.x2;
        const sxmin = Math.min(s.x1, s.x2), sxmax = Math.max(s.x1, s.x2);
        const symin = Math.min(s.y1, s.y2), symax = Math.max(s.y1, s.y2);
        data.rects.forEach(r => {
          if (isH && Math.abs(s.y1 - r.y) <= tol) {
            const ov = Math.min(sxmax, r.right) - Math.max(sxmin, r.x);
            if (ov > 2) allViolations.push({ slide: i + 1, path: pi + 1, segment: si + 1, border: 'top', rect: `(${r.x},${r.y}) ${r.w}x${r.h}`, overlap_px: +ov.toFixed(1) });
          }
          if (isH && Math.abs(s.y1 - r.bottom) <= tol) {
            const ov = Math.min(sxmax, r.right) - Math.max(sxmin, r.x);
            if (ov > 2) allViolations.push({ slide: i + 1, path: pi + 1, segment: si + 1, border: 'bottom', rect: `(${r.x},${r.y}) ${r.w}x${r.h}`, overlap_px: +ov.toFixed(1) });
          }
          if (isV && Math.abs(s.x1 - r.x) <= tol) {
            const ov = Math.min(symax, r.bottom) - Math.max(symin, r.y);
            if (ov > 2) allViolations.push({ slide: i + 1, path: pi + 1, segment: si + 1, border: 'left', rect: `(${r.x},${r.y}) ${r.w}x${r.h}`, overlap_px: +ov.toFixed(1) });
          }
          if (isV && Math.abs(s.x1 - r.right) <= tol) {
            const ov = Math.min(symax, r.bottom) - Math.max(symin, r.y);
            if (ov > 2) allViolations.push({ slide: i + 1, path: pi + 1, segment: si + 1, border: 'right', rect: `(${r.x},${r.y}) ${r.w}x${r.h}`, overlap_px: +ov.toFixed(1) });
          }
        });
      });
    });
  }
  await browser.close();
  if (allViolations.length === 0) {
    console.log('PASS: no line-on-border overlaps.');
    process.exit(0);
  } else {
    console.log('FAIL: ' + allViolations.length + ' line-on-border overlaps:');
    for (const v of allViolations) console.log(JSON.stringify(v));
    process.exit(1);
  }
})().catch(e => { console.error(e); process.exit(2); });
