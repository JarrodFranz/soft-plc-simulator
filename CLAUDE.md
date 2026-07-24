# Soft PLC Simulator — repo guide

## Browser verification (headless Playwright)

Verify user-facing changes in the **Flutter web build** with headless Playwright —
no visible browser, no mouse/keyboard takeover, runs in the background.

**Setup (one-time; already done):** `@playwright/mcp` + `playwright` are dev
deps (root `package.json`); the `playwright` MCP server is configured in
`.mcp.json`. The MCP tools load at Claude Code startup, so **restart Claude
Code** after first setup to get them. `node_modules/` and `.playwright-artifacts/`
are git-ignored.

**Each verification run:**
1. Build + serve the web app: `scripts/serve-web.sh --build` (serves
   `mobile/build/web` at `http://localhost:8091`; drop `--build` to reuse an
   existing build). Run it as a background process.
2. Drive the headless browser — either the `playwright` MCP tools (interactive)
   or the smoke script: `node scripts/browser-check.mjs`.
3. Test these viewports (the app is responsive — mobile shows a drawer + single
   column, desktop a multi-pane shell):
   - Desktop **1440×900**
   - Tablet **768×1024**
   - Mobile **390×844**
4. Capture full screenshots into `.playwright-artifacts/screenshots/` with
   descriptive names (`<screen>-<viewport>.png`); review them.
5. Check the browser **console** for errors/warnings (Flutter logs layout
   overflow — "A RenderFlex overflowed" — to the console) and **failed network
   requests**.
6. Fix issues, rebuild, reload, re-screenshot. Don't call UI work done until
   browser verification passes.
7. Never launch a headed/visible browser.

**Flutter-web caveats (this is a canvas app, not a DOM app):**
- Playwright **screenshots and viewport resize work fine** despite the app's
  continuous scan-loop repaint — capture without waiting for network idle.
  (The in-app Browser pane's screenshot *times out* on this app; use Playwright.)
- The UI renders to `<canvas>`, so there's **no DOM to click by default**.
  Screenshots + console + network cover responsive/visual/diagnostic checks.
  For DOM-level interaction, enable Flutter's semantics tree first (a real
  Playwright click on `flt-semantics-placeholder`); if that doesn't populate an
  ARIA tree, fall back to coordinate clicks (`page.mouse.click(x, y)`) read off
  a screenshot.
- Web uses browser localStorage for projects (separate from the desktop app's
  file storage), so it opens a default project, not your desktop's saved ones.
- The desktop build is the only way to interact with *saved* projects; see the
  `desktop-verify-harness` memory for that path (computer-use driven).

## Project layout

The Flutter app lives in `mobile/` (package `soft_plc_mobile`). Run all
`flutter` commands from `mobile/`. `flutter` is at `/c/flutter/bin/flutter`
(not on PATH). Deferred work is tracked in `docs/DEFERRED.md`.
