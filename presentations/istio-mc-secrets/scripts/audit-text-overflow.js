// Programmatic audit: every <text> element inside an SVG animation must fit
// inside its smallest enclosing <rect>. Run from the deck directory:
//   node scripts/audit-text-overflow.js
// Requires playwright (npm i playwright; npx playwright install chromium).
const { chromium } = require('playwright');
const path = require('path');

(async () => {
  const file = path.resolve(__dirname, '..', 'index.html');
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1920, height: 1080 } });
  const page = await ctx.newPage();
  await page.goto('file://' + file);
  await page.waitForFunction(() => window.Reveal && window.Reveal.isReady());
  await page.evaluate(() => Reveal.configure({ transition: 'none' }));

  const totalSlides = await page.evaluate(() => Reveal.getTotalSlides());
  const overflows = [];
  for (let i = 0; i < totalSlides; i++) {
    await page.evaluate(n => Reveal.slide(n, 0, -1), i);
    const fragCount = await page.evaluate(() => Reveal.getCurrentSlide().querySelectorAll('.fragment').length);
    for (let f = 0; f < fragCount; f++) await page.evaluate(() => Reveal.nextFragment());
    await page.waitForTimeout(200);
    const slideOverflows = await page.evaluate(() => {
      const svg = Reveal.getCurrentSlide().querySelector('svg.diagram');
      if (!svg) return [];
      const rects = Array.from(svg.querySelectorAll('rect')).map(r => ({
        x: parseFloat(r.getAttribute('x')) || 0,
        y: parseFloat(r.getAttribute('y')) || 0,
        w: parseFloat(r.getAttribute('width')) || 0,
        h: parseFloat(r.getAttribute('height')) || 0,
      })).map(r => ({ ...r, right: r.x + r.w, bottom: r.y + r.h, area: r.w * r.h }));
      const results = [];
      for (const t of svg.querySelectorAll('text')) {
        const tb = t.getBBox();
        const cx = tb.x + tb.width / 2;
        const cy = tb.y + tb.height / 2;
        let container = null, area = Infinity;
        for (const r of rects) {
          if (cx >= r.x && cx <= r.right && cy >= r.y && cy <= r.bottom && r.area < area) {
            container = r; area = r.area;
          }
        }
        if (!container) continue;
        const overflowR = (tb.x + tb.width) - container.right;
        const overflowL = container.x - tb.x;
        const overflowT = container.y - tb.y;
        const overflowB = (tb.y + tb.height) - container.bottom;
        const max = Math.max(overflowR, overflowL, overflowT, overflowB);
        if (max > 1.0) {
          results.push({
            text: t.textContent.trim().slice(0, 60),
            container: `${container.x},${container.y} ${container.w}x${container.h}`,
            overflow_px: { l: +overflowL.toFixed(1), r: +overflowR.toFixed(1), t: +overflowT.toFixed(1), b: +overflowB.toFixed(1) },
          });
        }
      }
      return results;
    });
    for (const o of slideOverflows) overflows.push({ slide: i + 1, ...o });
  }
  await browser.close();
  if (overflows.length === 0) {
    console.log('PASS: no text overflows.');
    process.exit(0);
  } else {
    console.log('FAIL: ' + overflows.length + ' text overflows:');
    for (const o of overflows) console.log(JSON.stringify(o));
    process.exit(1);
  }
})().catch(e => { console.error(e); process.exit(2); });
