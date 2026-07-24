// Headless responsive/visual check of the Flutter web build.
// Usage: node scripts/browser-check.mjs [baseUrl]
//   baseUrl defaults to http://localhost:8091 (serve mobile/build/web there first).
//
// For each viewport it loads the app, waits for the Flutter view to boot,
// attempts to enable Flutter's semantics (accessibility) tree so DOM-level
// interaction is possible, captures a full-page screenshot, and records
// console errors + failed network requests. Screenshots land in
// .playwright-artifacts/screenshots/. This is a proof/smoke harness; the
// Playwright MCP server (see .mcp.json) gives interactive tools after a
// Claude Code restart.
import { chromium } from 'playwright';
import { mkdirSync } from 'node:fs';

const baseUrl = process.argv[2] || 'http://localhost:8091';
const outDir = '.playwright-artifacts/screenshots';
mkdirSync(outDir, { recursive: true });

const viewports = [
  { name: 'desktop', width: 1440, height: 900 },
  { name: 'tablet', width: 768, height: 1024 },
  { name: 'mobile', width: 390, height: 844 },
];

const browser = await chromium.launch({ headless: true });
const results = [];

for (const vp of viewports) {
  const context = await browser.newContext({
    viewport: { width: vp.width, height: vp.height },
    deviceScaleFactor: 1,
    isMobile: vp.name === 'mobile',
  });
  const page = await context.newPage();
  const consoleErrors = [];
  const failedRequests = [];
  page.on('console', (m) => {
    if (m.type() === 'error') consoleErrors.push(m.text().slice(0, 200));
  });
  page.on('pageerror', (e) => consoleErrors.push('pageerror: ' + String(e).slice(0, 200)));
  page.on('requestfailed', (r) =>
    failedRequests.push(`${r.failure()?.errorText || 'failed'} ${r.url().slice(0, 120)}`),
  );

  let semantics = false;
  let booted = false;
  try {
    await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 30000 });
    // Wait for the Flutter view/glass pane to exist.
    await page.waitForSelector('flt-glass-pane, flutter-view', { timeout: 30000 });
    booted = true;
    // Give the CanvasKit surface a moment to paint the first frame.
    await page.waitForTimeout(2500);
    // Best-effort: enable Flutter semantics via a real (trusted) click so the
    // ARIA DOM tree populates for future DOM-level interaction.
    const ph = page.locator('flt-semantics-placeholder, [aria-label="Enable accessibility"]');
    if (await ph.count()) {
      await ph.first().click({ timeout: 2000, force: true }).catch(() => {});
      await page.waitForTimeout(800);
      semantics = (await page.locator('flt-semantics [aria-label]').count()) > 0;
    }
    // Screenshot works on a canvas app even while it repaints (no idle wait).
    await page.screenshot({
      path: `${outDir}/${vp.name}-${vp.width}x${vp.height}.png`,
      fullPage: false,
      animations: 'disabled',
      timeout: 15000,
    });
    // Horizontal overflow of the page document (canvas apps rarely trip this,
    // but catch any stray DOM element wider than the viewport).
    const scrollW = await page.evaluate(() => document.documentElement.scrollWidth);
    const clientW = await page.evaluate(() => document.documentElement.clientWidth);
    results.push({
      viewport: vp.name,
      size: `${vp.width}x${vp.height}`,
      booted,
      semantics,
      horizontalOverflow: scrollW > clientW + 1 ? `${scrollW}>${clientW}` : 'none',
      consoleErrors,
      failedRequests,
      screenshot: `${outDir}/${vp.name}-${vp.width}x${vp.height}.png`,
    });
  } catch (err) {
    results.push({ viewport: vp.name, size: `${vp.width}x${vp.height}`, booted, error: String(err).slice(0, 300) });
  } finally {
    await context.close();
  }
}

await browser.close();
console.log(JSON.stringify(results, null, 2));
