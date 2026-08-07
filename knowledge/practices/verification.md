---
id: knowledge:practices/verification
title: Verification Methods
domain: practices
version: "2026-08"
topics: [playwright, headless-browser, flutter-web, canvaskit, e2e, widget-test, fake-async, privileged-port, computer-use, desktop-verify, coordinate-clicks]
summary: The two verification methods proven on this project - headless Playwright against a no-DOM Flutter-web CanvasKit app (screenshot+console+network, coordinate clicks, viewport set, single-listener-on-port check) and per-protocol E2E lanes that prove each in-app host against a real third-party client - plus the widget-test fake-async pitfall and privileged-port classification that both depend on.
related:
  - knowledge:practices/index
  - knowledge:practices/development-process
  - knowledge:app/protocol-hosting
  - knowledge:app/ui-performance
learnings: [CL-9, CL-10, CL-11, CL-16]
---

# Verification Methods

> **Current as of:** 2026-08 (verified against the implementation on `main`).
> **Origin:** `CLAUDE.md` (browser verification section), `scripts/serve-web.sh`,
> `scripts/browser-check.mjs`, `tool/*_e2e.sh` (all ten lanes), `mobile/test/defaults/
> flagship_gateway_no_autostart_test.dart`, `mobile/test/defaults/all_water_test.dart`,
> `.playwright-artifacts/defaults-redo-verify.md`.
> **Read this before:** verifying any UI-facing change, adding a widget test that opens a
> real socket, or standing up a new protocol's E2E lane.

---

## 1. The headline rule

**This app is a canvas app, not a DOM app - verify it with headless Playwright screenshots,
console capture and network capture, not with DOM queries.**

The UI renders entirely to a `<canvas>` (Flutter web's CanvasKit renderer). There is no DOM
to click by default (CL-9). Anyone reaching for `page.click('button:has-text(...)')` or a
DOM-based Playwright locator will find nothing, because Flutter never produces those
elements - it paints pixels. Verification instead relies on visual screenshots at fixed
viewports, the browser console (Flutter logs layout overflow - "A RenderFlex overflowed" -
to the console), and the network tab (failed asset/font requests).

A second, easy-to-miss trap: the in-app Browser pane's own screenshot tool **times out** on
this app, because the app repaints continuously (the scan loop drives a live UI - see
[ui-performance.md](../app/ui-performance.md)) and that pane waits for something resembling
network/paint idle that never arrives (CL-16). Headless Playwright's `page.screenshot()`
does not wait for idle and captures cleanly despite the same repaint loop. **Always use
Playwright for this app; never the embedded preview screenshotter.**

---

## 2. The headless Playwright web-verification loop

### 2.1 Build and serve

```bash
scripts/serve-web.sh --build   # rebuild mobile/build/web, then serve it
scripts/serve-web.sh           # reuse an existing build
```

`scripts/serve-web.sh` runs `flutter build web` (when `--build` is passed) from `mobile/`,
then serves `mobile/build/web` at `http://localhost:8091` via `python -m http.server 8091
--bind 127.0.0.1`. Run it as a background process; it blocks in the foreground otherwise.

**Single-listener-on-port check.** Before trusting a screenshot, confirm exactly one process
is listening on 8091. A stale `http.server` left running from an earlier session serves a
stale build silently - the port still answers, so nothing errors, but every screenshot after
that shows old UI. A clean verification report records this explicitly (`.playwright-
artifacts/defaults-redo-verify.md`: "Build under test: ... (PID 7884, single listener
confirmed)"). On Windows, check with `netstat -ano | grep :8091` before capturing, and kill
any leftover listener first if a rebuild is meant to replace it.

### 2.2 Viewports

Test at three fixed viewports (`scripts/browser-check.mjs`'s `viewports` array; the app is
responsive - mobile collapses to a drawer + single column, desktop shows a multi-pane shell):

| Name | Size |
|---|---|
| Desktop | 1440x900 |
| Tablet | 768x1024 |
| Mobile | 390x844 |

For an unusually wide screen (e.g. a dense HMI dashboard), add 768x1024 as a middle check in
addition to the two required extremes.

### 2.3 What to capture

For each screen at each viewport:

1. A full screenshot into `.playwright-artifacts/screenshots/`, named
   `<screen>-<viewport>.png` (or `<project-slug>-<screen>-<viewport>.png` when the app has
   multiple loaded projects, as in the default-projects catalog).
2. Console messages at `warning` and `error` level for the whole session (not just since the
   last navigation) - zero is the bar. Watch specifically for "A RenderFlex overflowed",
   Flutter's console signature for a layout that doesn't fit.
3. Failed network requests - zero is the bar (CanvasKit/font bootstrap assets should all
   return 200).
4. Horizontal document overflow (`document.documentElement.scrollWidth` vs `clientWidth`) -
   canvas apps rarely trip this since almost nothing is DOM, but a stray DOM overlay can.

`scripts/browser-check.mjs` automates steps 1-4 as a smoke script (`node scripts/browser-
check.mjs [baseUrl]`); the Playwright MCP tools give the same coverage interactively plus
click-driven flows (see 2.4).

### 2.4 DOM-level interaction (when a click, not just a screenshot, is needed)

Flutter web can optionally populate an ARIA/DOM semantics tree for accessibility. Try to
enable it with a real (trusted) click on the `flt-semantics-placeholder` element (or
`[aria-label="Enable accessibility"]`) before relying on DOM locators - `browser-check.mjs`
does this as a best-effort step. If `flt-semantics [aria-label]` elements don't populate
afterward, semantics-tree clicks are unreliable for this app; fall back to coordinate clicks,
`page.mouse.click(x, y)`, reading the target position off a prior screenshot (CL-9). This is
the normal path, not a last resort - most interactive verification on this app (forcing a
tag, toggling a live-sync switch, clicking START on an HMI) is done by coordinate, confirmed
working in `.playwright-artifacts/defaults-redo-verify.md`'s live-behavior spot-checks (SFC
active-step highlighting, Flagship's START buttons, PID convergence charts).

### 2.5 Fix -> rebuild -> reload -> re-screenshot

Don't call UI work done until this loop passes clean: fix the issue, rebuild (`scripts/
serve-web.sh --build`), reload the page, re-screenshot, re-check console/network. A pass
report states counts explicitly (see `.playwright-artifacts/defaults-redo-verify.md` §4:
"0 warnings, 0 errors ... across the entire session").

---

## 3. Widget tests that touch real sockets: fake-async vs `dart:io`

**A `dart:io` future never completes inside a widget-test's fake-async zone - real socket
work must run inside `tester.runAsync`, and the `runAsync` result must be asserted
`isNotNull`** (CL-10).

`flutter_test`'s `testWidgets` runs the test body in a `FakeAsync` zone so timers and
microtasks can be driven synchronously with `tester.pump()`. Real OS I/O (`ServerSocket.
bind`, a real TCP connect) never resolves in that zone - the future just hangs, and if the
calling code swallows the hang (e.g. inside a `catch` that returns `null` on any error), the
test can silently pass having tested nothing.

The fix, from `mobile/test/defaults/flagship_gateway_no_autostart_test.dart`:

```dart
final probe = await tester.runAsync(() async {
  // real ServerSocket.bind() calls live here
  return {'hard': hardFailures, 'skipped': skipped};
});
expect(probe, isNotNull,
    reason: 'runAsync did not complete - the port probe never ran');
```

The `expect(probe, isNotNull, ...)` line is not decorative - `runAsync`'s callback throwing
(rather than the socket call itself failing normally) makes `runAsync` return `null`, and
without this assertion a broken probe silently degrades into an always-green test. Any new
widget test that opens a real socket, spawns a real process, or otherwise leaves the Dart
event loop needs both: wrap the I/O in `tester.runAsync`, and assert its result is non-null
before trusting anything it returned.

---

## 4. Privileged-port classification

**Binding port 502 requires OS privilege - POSIX raises `EACCES` (errno 13), Windows raises
`WSAEACCES` (10013) - and a port-probe test must classify that outcome separately from
address-already-in-use or it false-fails for any unprivileged CI/dev user** (CL-11).

A "prove nothing auto-started a protocol host" test typically tries to bind the host's
configured port itself: if the bind succeeds, the port was free (pass); if it fails with
"address in use", something is already listening (real failure - a host auto-started, or
an unrelated process holds the port). But Modbus's default port, 502, is in the OS's
privileged range (<1024). An unprivileged user gets a permission error there regardless of
whether anything is listening, which says nothing about the property under test. OPC UA's
4840 is unprivileged everywhere, so a bind failure on 4840 is unambiguous.

Classification helper (`flagship_gateway_no_autostart_test.dart`):

```dart
bool _isPermissionDenied(SocketException e) {
  final code = e.osError?.errorCode;
  if (code == 13 || code == 10013) return true;
  final message = (e.osError?.message ?? e.message).toLowerCase();
  return message.contains('permission denied') ||
      message.contains('access permissions') ||
      message.contains('permissions to access a socket');
}
```

Usage: `if (_isPermissionDenied(e) && port < 1024)` routes the failure to a `skipped` bucket
(logged, not asserted) instead of a `hardFailures` bucket (asserted empty). Any port over
1024 (or any error that is not a permission error) still hard-fails - this narrows the
exemption to exactly the ambiguous case, it does not weaken the test generally.

A second escape hatch belongs to the human running the test, not the code: if a bind fails
on a developer machine because an unrelated real process (e.g. an actual OPC UA server)
already holds the port, that is an environment collision, not a regression - confirm with
`netstat`/`ss` before concluding the app auto-started a host.

---

## 5. Per-protocol E2E lanes with real clients

**A protocol host is proven correct against a real third-party client, not against another
Dart test in the same codebase - the `tool/*_e2e.sh` lanes are that proof, one per
protocol.** A Dart-only test can (and does) exercise the codec and host logic, but it cannot
catch a wire-format mistake that both the encoder and a same-author decoder agree on. Only
an independent implementation, driven the way a real integrator would drive it, closes that
gap.

### 5.1 The lane pattern

Every `tool/<protocol>_e2e.sh` follows the same shape:

1. Start the in-app fixture host (`mobile/tool/<protocol>_host_probe.dart`, run via
   `dart run`) on a non-default port, redirecting its output to a log file.
2. Poll the log for a `READY ...` marker (bounded wait, e.g. ~90s) - never assume the host is
   up after a fixed sleep.
3. Run a REAL third-party client against it and capture its exit code.
4. Unconditionally kill the fixture host on exit (`trap cleanup EXIT`) and propagate the
   client's exit code as the script's exit code, so the lane fails the pipeline exactly when
   the client's assertions fail.

### 5.2 Real clients per protocol

| Protocol | Lane | Real client |
|---|---|---|
| Modbus TCP / RTU-over-TCP | `tool/modbus_e2e.sh`, `tool/modbus_rtu_e2e.sh` | Rust `tokio-modbus` crate (`gateway/examples/modbus_probe.rs`) |
| OPC UA | `tool/opcua_e2e.sh` | Rust `opcua` crate (`gateway/examples/opcua_probe.rs`); two legs, None/Anonymous and secured |
| EtherNet/IP + CIP | `tool/enip_e2e.sh` | Python `pycomm3` (`tool/py/enip_probe.py`) |
| S7comm | `tool/s7_e2e.sh` | Python `python-snap7` (`tool/py/s7_probe.py`) |
| FINS (UDP) | `tool/fins_e2e.sh` | Pure-Python `fins` library (`tool/py/fins_probe.py`) - the Python lane's first UDP use, prior probes were all TCP |
| SLMP | `tool/slmp_e2e.sh` | Pure-Python `pymcprotocol` (`tool/py/slmp_probe.py`) |
| DNP3 | `tool/dnp3_e2e.sh` | Rust `dnp3` crate, Step Function I/O (`gateway/examples/dnp3_probe.rs`) |
| BACnet/IP | `tool/bacnet_e2e.sh` | Python `bacpypes3` (`tool/py/bacnet_probe.py`) |
| MQTT Sparkplug B | `tool/mqtt_e2e.sh` | Self-contained: embeds a real `rumqttd` broker and a real `rumqttc` subscriber inside the Rust probe itself, spawning the Dart fixture host three times (JSON, Sparkplug B, Sparkplug B with a self-initiated disconnect to prove NDEATH) |

### 5.3 Windows PID-of-listener teardown

**Under Git Bash on Windows, `$!` after `dart run ... &` is a synthetic MSYS job id, not the
real Windows PID of the spawned `dart.exe` - `taskkill //PID $!` silently fails to find it
and the process keeps the port bound.** `dart run` is a wrapper (`dart.bat`) that spawns a
real `dart.exe` child; the shell's job-control PID and the OS PID diverge. The fix used by
every lane (`tool/modbus_e2e.sh`, mirrored by `tool/opcua_e2e.sh` and the rest): look up
whoever is actually LISTENING on the target port via `netstat -ano`, and kill that PID with
`taskkill //F //T //PID <real_pid>` (`//T` also takes any of its own children). Fall back to
the bash job PID + `kill`/`wait` on non-Windows.

```bash
find_listening_pid() {
  netstat -ano 2>/dev/null | grep "LISTENING" | grep ":${PORT} " | awk '{print $NF}' | head -n1
}
```

This is the general fix for "I started a Dart process from Git Bash and need to kill it
reliably on Windows" - port-owning-PID lookup, not `$!`.

### 5.4 Early-gate discipline

Each lane targets one non-default, hardcoded port and is self-contained (build/start/probe/
teardown in one script, no shared fixture state between lanes) so lanes can run independently
or in CI without colliding. A lane is a machine-proof gate for the workstream that introduced
it: it is expected to pass before that workstream's PR merges, the same way the whole-branch
review gate is (see [development-process.md](./development-process.md) §2) - an E2E lane
that never ran, or that ran once and was never re-run after a later codec change, is not
proof of anything.

---

## 6. Desktop computer-use verification harness

Web verification (§2) covers layout, rendering and console/network health, but the web build
uses browser `localStorage` for projects - a fresh default project every time, never the
user's actual saved work. **The desktop build is the only way to interact with real saved
projects** (`CLAUDE.md`'s browser-verification section notes this explicitly), and it needs
a different tool: computer-use driving the real Windows executable, not Playwright.

Working recipe for the build -> run -> interact -> verify loop on Windows:

1. Close any stale instance: `taskkill //IM soft_plc_mobile.exe //F`. Leave `dart.exe` /
   `dartvm.exe` processes alone - those are unrelated tooling.
2. Build: `cd mobile && /c/flutter/bin/flutter build windows --debug`.
3. Launch exactly ONE instance (`cmd //c start "" "soft_plc_mobile.exe"` from the `Debug`
   output directory). Two instances racing against the same project files on disk causes
   autosave conflicts.
4. Grant computer-use access. Computer-use's `request_access` only resolves installed
   Start-menu apps, so it cannot target a freshly-built dev exe by process name or window
   title. Create a Start-menu `.lnk` shortcut pointing at the stable `Debug` output path once,
   then request access by the shortcut's name; keep the shortcut so every future verification
   run skips this step.
5. Drive the app with the `computer-use` MCP tools (click/drag/screenshot) against the real,
   currently-loaded project.
6. Courtesy/cleanup: block-position drags in the editors are not on the undo stack - restore
   a moved block by dragging it back manually, not Ctrl+Z. Switch the app back to whatever
   project was open before verification started.

Do not attempt this loop against the web build - per §1/CL-16, the web build's continuous
repaint defeats screenshot tooling that waits for idle, and computer-use screenshotting a
browser window inherits the same problem plus the DOM-interaction limits of §2.4.

---

## What this means practically

### "How do I verify a UI change is done?"
Build and serve the web app, run the headless Playwright loop (§2) at all three viewports,
confirm zero console warnings/errors and zero failed requests, and don't call it done until
that passes clean after your fix.

### "I need to click something in the app, not just screenshot it - how?"
Try enabling Flutter's semantics tree with a real click on `flt-semantics-placeholder`
first; if the ARIA tree doesn't populate, read the target's pixel position off a screenshot
and use `page.mouse.click(x, y)` (§2.4). This is the normal path for this app, not a
fallback of last resort.

### "My widget test opens a socket and just hangs / times out."
It's running inside `flutter_test`'s fake-async zone, which never completes real `dart:io`
futures. Wrap the socket work in `tester.runAsync(...)` and assert the result `isNotNull`
(§3, CL-10).

### "My port-probe test fails on my machine but not in CI (or vice versa)."
Check whether the port is privileged (<1024, e.g. Modbus's 502). An unprivileged user gets
EACCES/WSAEACCES there independent of whether anything is listening - that must be
classified separately from address-in-use, not asserted as a hard failure (§4, CL-11).

### "How do I prove a new protocol host actually speaks the wire protocol correctly?"
Write a `tool/<protocol>_e2e.sh` lane following the pattern in §5: start the in-app Dart
fixture host, wait for its `READY` log marker, run a real third-party client library against
it, and propagate the client's exit code. A same-codebase Dart test proves internal
consistency, not wire correctness.

### "I need to verify against my actual saved projects, not a fresh default."
Use the desktop computer-use harness (§6), not the web build - the web build's projects live
in browser `localStorage` and are always fresh/default.

---

## Related

- [index.md](./index.md) - domain hub.
- [development-process.md](./development-process.md) - where verification fits in the
  overall pipeline (browser-verify is the gate immediately before PR).
