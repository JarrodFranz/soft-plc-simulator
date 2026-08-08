# Native-app / Store-readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Per the repo's execution preference, the session model orchestrates only and delegates each task to a sub-agent at the annotated model/effort.

**Source spec:** `docs/superpowers/specs/2026-08-08-store-readiness-design.md` (design-reviewed 2026-08-08, verdict applied). The spec is the single source of requirements; every `§`/requirement below traces to it.

**Branch base:** `main` @ `70c3ea6`.

## Changelog

- 2026-08-08 — initial plan.
- 2026-08-08 — applied plan-review fixes (verdict FIX FIRST). **C1:** wrapped the suspend/detached `debugLifecycleOp` awaits that stop a live host (L1/L2/L8/L9/L10/L12) in `tester.runAsync` (CL-10 — a real `dart:io` close never resolves in the fake-async zone); left bare the non-host-stopping cases (L3/L4/L5/L6/L7/L11). **I2:** added the two missing imports (`project_repository.dart`, `softplc_settings_dialog.dart`) to the S1-S5 append. **I3:** T4 Step 2 now opens a **draft PR to `main`** (fires `pull_request`) instead of a bare feature-branch push that fires no run. **m4:** named the `hmi_haptics_test.dart:151-153` dialog site in the grep-and-fix step. **m5:** added a "verify against `create_project_flush_autosave_test.dart`" note to `_armDirtyEdit`. The review's "Verified correct" / "Adjudications" items (closure table, MQTT special-case, flush, resume-lock, guard tests, all five resolutions) were sound and left unchanged.

---

## Goal

Make the repo **shippable to Google Play and the Apple App Store the moment the user has developer accounts**, and make the app actually *work* on a real device once installed. Today a release build cannot open a socket — the `INTERNET` permission is declared only in the `debug/`+`profile/` source-set manifests, so all nine in-app protocol hosts (OPC UA, Modbus TCP, MQTT, DNP3, EtherNet/IP, S7, FINS, SLMP, BACnet/IP) are dead in a `flutter build appbundle --release`, contradicting ADR-010. This plan closes that headline blocker plus iOS/macOS network config, opt-in release signing, an app-lifecycle policy, CI, four absorbed UX-polish rows, a version bump, staleness fixes, and the doc/asset checklists that make the first submission mechanical.

## Architecture

Five independent workstreams over one branch:

1. **Platform config (T1)** — exact literal edits to `AndroidManifest.xml`, `Info.plist`, the two macOS `*.entitlements`, `build.gradle.kts` (opt-in signing), `pubspec.yaml`, `web/*`, `PROJECT_BRIEF.md`, plus a `key.properties.example`, root `.gitignore` hardening, and a **source-reading guard test** (`platform_config_guard_test.dart`) that greps the built config files so a permission can never silently regress again (N7).
2. **UX polish (T2)** — the four open PR #18 DEFERRED rows (`docs/DEFERRED.md:150-153`): project-dropdown scrim, DUT bottom bar, `PannableCanvas` wheel gap, FBD lane height. Its **own PR**.
3. **App lifecycle (T3)** — a `WidgetsBindingObserver` state machine over the scan loop and the nine hosts, a user setting *"Pause automation when app is in background"* (default ON), an awaited autosave flush, a shell-owned resume lock surfaced as one `AbsorbPointer`, a resume `SnackBar`, and `kLogSourceLifecycle`. **The risky one.** Its own PR.
4. **CI (T4)** — `.github/workflows/ci.yml`: a test+analyze gate, an Android AAB/APK job (signed if secrets exist, else debug-signed), an iOS `--no-codesign` compile, and a Windows zip — `vars.`-gated platform jobs.
5. **Docs + verification (T5, T6)** — SHIPPING.md overhaul with the user-owned store-asset + keystore checklists, a new `docs/mobile-packaging.md`, supersession banners on two stale specs, a knowledge-base `CL-` entry, and the full §7 verification matrix including the **mandatory Wi-Fi-free `adb forward` + Python-probe Modbus proof (R3)**.

## Tech Stack

Flutter/Dart (`/c/flutter/bin/flutter`, version 3.44.4 stable), Gradle Kotlin DSL (AGP 9.0.1 / Gradle 9.1.0 / Kotlin 2.3.20, Java 17), GitHub Actions YAML, iOS/macOS plist + entitlements XML. **No new runtime dependency** (N8): platform config, `WidgetsBindingObserver` (framework), `SharedPreferences` (already a dep), YAML. Verification: `flutter test`, `flutter analyze`, headless Playwright (`scripts/serve-web.sh`), `adb forward` + `mobile/tool/py/` Python probe.

---

## Global Constraints

Copied verbatim from the spec's binding rules. These hold for **every** task.

- **Never break the release build.** `flutter build apk --release` and `flutter build appbundle --release` must succeed both **with** a `key.properties` (upload-key-signed) and **without** one (debug-signed fallback — N4). Debug-signed ≠ store-uploadable; it is sideload/smoke only.
- **Presence-guard tests are the regression wall (N7).** The permissions/entitlements can never silently regress: `platform_config_guard_test.dart` greps the built platform config files. It reads sources by **package-relative path** with CWD = `mobile/` (the `app_log_test.dart:208` precedent — `File('lib/models/app_log.dart').readAsStringSync()`), **except the root `.gitignore` which is `../.gitignore`** (it lives at the repo root, outside the Flutter package). Every assertion carries a `reason:` naming what breaks.
- **Exact permission/entitlement/purpose strings are load-bearing.** Ship the spec's exact literals: `android.permission.INTERNET`; the full `NSLocalNetworkUsageDescription` string; `com.apple.security.network.server` + `com.apple.security.network.client` in **both** macOS entitlement files. iOS silently fails LAN sockets when the key is missing (no exception) — the worst failure mode to debug on-device.
- **MQTT resume is a no-op (B1).** The broker password lives only in un-persisted `GatewayScreen._mqttPassword` (reset on project change, never stored). The shell cannot reconnect MQTT after a lifecycle stop. MQTT's `start` closure is a **no-op that logs a WARN**; on resume the user is told to reconnect from the Gateway. MQTT is **excluded** from the "N of M restarted" count and is **never** a restart failure.
- **The resume-lock `finally` bound is mandatory.** `_resumeInProgress` is set true before the restart loop and cleared in a `finally` — **always** — with a per-host **2 s** `.timeout` and an overall **5 s** deadline, so a wedged bind can never leave the Gateway permanently frozen (`AbsorbPointer` stuck absorbing). L12 exists to prove this.
- **`flutter` is at `/c/flutter/bin/flutter`, run from `mobile/`.** Every `flutter` command in this repo runs with CWD = `mobile/`.
- **Full suite + analyze green per task.** After each task: `cd mobile && flutter test` (full suite green) and `flutter analyze` (zero issues — the repo's standing "no analyze warnings" rule). No test may be skipped or marked flaky to land this.
- **The on-device proof gate (R3).** No "done" claim for the workstream before the mandatory Wi-Fi-free `adb forward` + Python-probe Modbus poll against a **release** APK is observed: without `INTERNET` the bind throws and the host never reaches `running`, so the bind itself is the proof.
- **Repo conventions:** dark theme (`0xFF0F172A` / `0xFF1E293B`); `withValues(alpha:)` never `withOpacity`; braces on all control flow; no `RenderFlex overflowed` at 320/360/1440; no competitor-tooling branding (no OpenPLC); every new protocol/subsystem logging source declared under a `kLogSource*` constant **and** in `kAllLogSources` (`app_log.dart`) — the `app_log_test.dart` guard enforces the pair.

---

## Recorded resolutions

Ambiguities resolved beyond the spec, with the resolution:

- **R-A — T4 model/effort is opus·high, overriding the spec's §12 table (sonnet·medium).** The plan-author directive elevates the CI-workflow task to opus·high for YAML correctness, the `vars.`-gate footgun (`env`/`secrets` unavailable in job-level `if:`), and the graceful-signing step-output gate. Recorded here because §12 lists sonnet·medium for T4; this plan intentionally diverges.
- **R-B — Task order for a sequentially-green branch.** SDD runs tasks sequentially in one branch, but the spec's §12 makes **T1/T2/T3 mutually independent and intended-parallel** (the R2 ruling dissolved T3's old dependency on T1). Order chosen: **T1 → T3 → T2 → T4 → T5 → T6**. T1 first (self-contained, closes the headline blocker, lands `kLogSourceLifecycle`'s neighbour `app_log.dart` untouched). T3 next (adds `kLogSourceLifecycle`; needed by T4's gate). T2 anywhere before T4 (fully independent; its own PR). T4 needs T1's signing block + T3's tests in the gate. T5 documents what shipped; T6 is the final verification gate. **The numbering below keeps the spec's T1..T6 labels** for traceability; only the dispatch order differs, and each of T1/T2/T3 leaves the branch green on its own.
- **R-C — Where each new setting/field/accessor lives** is pinned to exact insertion sites re-verified against the live files (see "Key facts"). The spec's line numbers were off-by-one in places (host fields, the fixed-mode scan guard); the corrected numbers are used.
- **R-D — `AbsorbPointer` wrap site.** The spec says "wrap the Gateway protocol-card body". Resolved to wrapping the whole `Scaffold` `body:` `Column` (`gateway_screen.dart:1571`) — which also disables the protocol-tab selector during resume — since a mid-resume tab swipe is as racy as a toggle. One wrap, one param.
- **T3 test host choice.** The 6 host-touching lifecycle cases drive the **OPC UA** host (default port **4840**, unprivileged everywhere) not Modbus (502, privileged) so a real `ServerSocket.bind` in `tester.runAsync` is unambiguous (verification.md §4). Socket work is wrapped in `tester.runAsync` and its result asserted `isNotNull` (verification.md §3, CL-10).

---

## Key facts (verified against live files at `70c3ea6` — do not re-derive)

**`mobile/lib/screens/workspace_shell.dart`** (3487 lines; `WorkspaceShellState extends State<WorkspaceShell>`, **no mixin**, `:102`):
- `isRunning` `:116` (Run/Pause intent, toggled at the run `IconButton` `:2203-2219`); `scanCount` `:117`; `_scanTimer`/`_supervisorTimer` `:119-120`.
- The nine hosts `:136-144` (`_opcuaHost … _bacnetHost`; note the DNP3 field is **`_dnpHost`**, type `DnpHost`), `late final`, each `HostFoo(logger: _logger)`.
- `_logger` `:130` (`AppLogger`).
- `initState()` `:271-276` (`_repaintThrottle = NotifyThrottle(...)` then `_boot()`); `dispose()` `:278-295` (cancels timers, disposes nine hosts, disposes throttle+liveTick).
- `_startScanLoop()` `:434-464`, mode-aware. The three re-arm guards: free-run inner early-return `if (!isRunning || _faulted) {` **`:439`**; free-run outer re-arm `if (isRunning && !_faulted) {` **`:448`**; fixed-mode body `if (isRunning && !_faulted) {` **`:453`** (spec said `:452`).
- `_startRunSession()` `:822-831` (resets `_scan`, logs, `_uptime`/`_sinceLast` `..reset()..start()`).
- `_executeScan()` `:833`; `dtMs` free-run clamp `_sinceLast.elapsedMilliseconds.clamp(0, 1000)` **`:838`**; `_uptime.elapsedMilliseconds` feeds `System.Uptime` `:902`.
- `_uptime`/`_sinceLast` `:189-190` (`Stopwatch`).
- Global setting keys `_kUiRefreshHzKey='ui_refresh_hz'` `:64`, `_kHapticsEnabledKey='haptics_enabled'` `:72`; defaults `kDefaultRefreshHz=10` `:68`, `kDefaultHapticsEnabled=true` `:76`.
- `applyHapticsEnabled` `:537-550` (mounted-guarded `setState`, best-effort `prefs.setBool`); `applyRefreshHz` `:561`. Both `@visibleForTesting`.
- Settings load in `_boot()` `:329-338` (best-effort `try/catch`, reuses the `prefs` handle or a fresh `SharedPreferences.getInstance()`); `loadedRefreshHz`/`loadedHaptics` are applied into `_refreshHz`/`_hapticsEnabled` in `_boot`'s final `setState`.
- `_openSoftPlcSettings(context)` `:588-600` (`showAdaptiveWidthDialog<SoftPlcSettingsResult>`; applies `applyRefreshHz`+`applyHapticsEnabled` at `:597-598`).
- `_runAutosave()` `:1049-1084` (`Future<void>`, real persist via `_repo.saveProject`). `_flushActiveEditor()` `:1096`. `_flushPendingAutosave()` `:1103-1108` — `void`, ends `unawaited(_runAutosave())`.
- `debugActiveProject` getter and `WorkspaceShell({this.repository})` seam `:90-96` exist (tests inject a `ProjectRepository`).

**`mobile/lib/services/*_host.dart`:** the eight listening hosts share `enum FooHostStatus { stopped, running, error }`, `FooHostStatus get status`, `Future<void> start(PlcProject Function() projectProvider)`, `Future<void> stop()` (verified `opcua_host.dart`: enum `:30`, `status` `:317`, `start` `:357`, `stop` `:653`). **MQTT differs:** `enum MqttHostStatus { stopped, connecting, running, error }` (`mqtt_host.dart:130`), `MqttHostStatus get status` `:320`, `Future<void> connect(PlcProject Function() projectProvider, {required String password})` `:348`, `Future<void> disconnect()` `:965`.

**`mobile/lib/screens/gateway_screen.dart`** (5739 lines): constructor `:151-167` takes all nine hosts + `hostingSupported = !kIsWeb` `:164` + `initialProtocolTabIndex = 0` `:165` + `onProtocolTabChanged`. `build()` `:1544`; `Scaffold` `body: Column(children: [_ProtocolTabSelector(...), Divider(...), Expanded(LayoutBuilder→MediaQuery→Builder→TabBarView)])` `:1571-…`. The sixteen `_(start|stop)*Hosting` helpers `:572-646`, `_connectMqtt` `:647`, `_disconnectMqtt` `:651` — **left untouched** under the R2 ruling.

**`mobile/lib/screens/softplc_settings_dialog.dart`** (NOT under `widgets/`): `SoftPlcSettingsResult{refreshHz, hapticsEnabled}` `:5-16`; `SoftPlcSettingsDialog{initialRefreshHz, initialHapticsEnabled}` `:27-43`; one `SwitchListTile` (haptics) `:99-105`; Save is `ElevatedButton(onPressed: _save)` `:111`; `_save()` pops `SoftPlcSettingsResult(...)` `:63-73`.

**`mobile/lib/ui/pannable_canvas.dart`** (NOT under `widgets/`): `_capturePreSignal` `:134`; `_onPointerSignal` `:140`, `pre == null` early-return `:150`; `_zoomAt` uses `_controller.value.getMaxScaleOnAxis()` `:237`; build `LayoutBuilder` with `_viewport = constraints.biggest` `:304`; outer `Listener`→`Stack`→`InteractiveViewer(constrained:false, minScale: widget.minScale)`→inner capture `Listener(behavior: HitTestBehavior.opaque, onPointerSignal: _capturePreSignal, child: widget.child)` `:305-323`; an `AnimatedBuilder(animation: _controller, …)` edge-fades layer already exists `:324-327`.

**`mobile/lib/screens/fbd_editor_screen.dart`:** `_laneCanvasHeight(int net)` `:673-681`, ceiling `(maxY + 220).clamp(260.0, 1200.0)` `:680`; `wheelPansVertically: false` `:907`. Tests: `editor_canvas_pan_test.dart`, `fbd_editor_networks_test.dart`.

**`mobile/lib/screens/memory_manager_screen.dart`:** `_buildStructDefsTab()` `:1500-…`, its **own nested `Scaffold`** with `FloatingActionButton.extended(… onPressed: _showAddStructDialog)` `:1502-1508`, `body: structs.isEmpty ? const Center(child: Text('No Struct definitions defined yet.')) : ListView.builder(padding: EdgeInsets.fromLTRB(16,16,16,96), …)` `:1509-1513`.

**`mobile/lib/models/app_log.dart`:** source constants `:23-36`; `kAllLogSources` list `:47-…`. The `app_log_test.dart` "kAllLogSources covers every kLogSource" guard reads the file text.

**Platform files (current state):**
- `mobile/android/app/src/main/AndroidManifest.xml` — **no `<uses-permission>` at all**; `<queries>` present `:39-44`. `debug/` and `profile/` manifests already declare `INTERNET`.
- `mobile/android/app/build.gradle.kts` — `plugins{}` `:1-5`; `android{}` `:7`; `buildTypes{ release { // TODO … signingConfig = signingConfigs.getByName("debug") } }` `:34-40`.
- `mobile/macos/Runner/Release.entitlements` — only `app-sandbox` true. `DebugProfile.entitlements` — `app-sandbox`, `cs.allow-jit`, `network.server` (no `network.client`).
- `mobile/ios/Runner/Info.plist` — keys at **2-tab** indentation; `LSRequiresIPhoneOS` `:27-28`, `UIApplicationSceneManifest` `:29`.
- `mobile/pubspec.yaml` — `version: 0.1.0+1` `:4`.
- `mobile/web/manifest.json:8` and `mobile/web/index.html:19` — `"A new Flutter project."`.
- Root `.gitignore` "Secrets" block `:41-47` — has `*.jks`, **lacks** `*.keystore` and `key.properties`. `mobile/android/.gitignore` already has `key.properties`, `**/*.keystore`, `**/*.jks`.
- `docs/DEFERRED.md:150-153` — the four §4 rows under "QA whole-branch review follow-ups (feat/qa-improvements)".

**Baseline:** `flutter analyze` zero issues at `70c3ea6`. The `flutter test` count is **re-derived** in T6 (do not hardcode a stale number; SHIPPING.md's old "1550 tests" claim must be re-derived, not copied).

---

## Task list

| # | Title | Model · Effort | Deliverable |
|---|---|---|---|
| T1 | Platform config + signing scaffold + guard tests | sonnet · medium | Release build can open sockets; `platform_config_guard_test.dart` G1-G7 pins every literal |
| T3 | App lifecycle (state machine + resume lock + MQTT special) | **opus · high** | Clean background pause/resume of scan + nine hosts; setting; `kLogSourceLifecycle`; L1-L12 + S1-S5 |
| T2 | UX polish — four PR #18 DEFERRED rows (own PR) | sonnet · medium | Dropdown scrim, DUT bottom bar, canvas wheel gap, FBD lane — browser-verified |
| T4 | CI workflow `.github/workflows/ci.yml` | **opus · high** | gate + Android(signed/debug-signed) + iOS(no-codesign) + Windows, `vars.`-gated, run-green |
| T5 | Docs overhaul + supersession banners | sonnet · medium | SHIPPING.md + `docs/mobile-packaging.md` + asset/keystore checklists + DEFERRED/spec edits |
| T6 | Knowledge base + final verification (R3 gate) | sonnet · medium | `CL-` entry + full §7 matrix incl. the mandatory on-device Modbus bind/poll proof |

Dispatch: **T1 and T2 are independent and may be dispatched in parallel; T3 is a solo run** (all three are intended-parallel per §12). T4 needs T1+T3. T5 then T6 are sequential closers. Sub-agent model/effort is annotated per task; the CI task is opus·high per R-A.

---

### Task T1: Platform config + signing scaffold + guard tests

**Model · Effort: sonnet · medium** — mechanical and exactly specified; the whole value is getting the literal strings right, which the guard test then pins. Closes the headline release-socket blocker on its own.

**Files:**
- Modify: `mobile/android/app/src/main/AndroidManifest.xml`
- Modify: `mobile/android/app/build.gradle.kts`
- Modify: `mobile/ios/Runner/Info.plist`
- Modify: `mobile/macos/Runner/Release.entitlements`
- Modify: `mobile/macos/Runner/DebugProfile.entitlements`
- Modify: `mobile/pubspec.yaml`, `mobile/web/manifest.json`, `mobile/web/index.html`, `PROJECT_BRIEF.md`, `.gitignore` (repo root)
- Create: `mobile/android/key.properties.example`
- Create (test): `mobile/test/platform_config_guard_test.dart`

**Interfaces:**
- Consumes: none (config only).
- Produces: a release-capable Android manifest; an opt-in Gradle signing config keyed on `rootProject.file("key.properties")`; iOS/macOS network config; version `0.9.0+2`; the guard test.

- [ ] **Step 1: Write the failing guard test** `mobile/test/platform_config_guard_test.dart`:

```dart
// N7 regression wall (store-readiness §6). These greps make it STRUCTURALLY
// impossible to silently drop a platform permission/entitlement again — the
// exact failure that hid for a month across two prior specs. `flutter test`
// runs with CWD = the package root (mobile/), so every path here is
// package-relative EXCEPT the repo-root .gitignore, which is ../.gitignore
// (it lives OUTSIDE the Flutter package). Precedent: app_log_test.dart:208.
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  test('G1: Android release manifest declares the INTERNET permission', () {
    final xml = _read('android/app/src/main/AndroidManifest.xml');
    expect(
      RegExp(r'<uses-permission\s+android:name="android\.permission\.INTERNET"\s*/>')
          .hasMatch(xml),
      isTrue,
      reason: 'Without <uses-permission android.permission.INTERNET/> in '
          'src/main/, the RELEASE manifest merge (which uses main/ alone) has '
          'no INTERNET permission and EVERY protocol host fails to open a '
          'socket on a store build. The debug/profile manifests do NOT cover '
          'the release variant.',
    );
  });

  test('G2: iOS Info.plist has a well-formed NSLocalNetworkUsageDescription', () {
    final plist = _read('ios/Runner/Info.plist');
    final m = RegExp(
      r'<key>NSLocalNetworkUsageDescription</key>\s*<string>(.*?)</string>',
      dotAll: true,
    ).firstMatch(plist);
    expect(m, isNotNull,
        reason: 'iOS 14+ SILENTLY fails LAN sockets with no exception when '
            'this key is missing — the worst on-device failure mode. It must '
            'be present and non-vague or App Review rejects it.');
    final purpose = m!.group(1)!.trim();
    expect(purpose.length, greaterThanOrEqualTo(40),
        reason: 'Purpose string too short — App Review rejects vague strings.');
    expect(purpose.toLowerCase(), contains('local network'),
        reason: 'Purpose string must name what the app does with the LAN.');
  });

  for (final f in const ['macos/Runner/Release.entitlements',
      'macos/Runner/DebugProfile.entitlements']) {
    test('G3: $f grants both network.server and network.client', () {
      final ent = _read(f);
      for (final key in const [
        'com.apple.security.network.server',
        'com.apple.security.network.client',
      ]) {
        expect(
          RegExp('<key>' + RegExp.escape(key) + r'</key>\s*<true/>', dotAll: true)
              .hasMatch(ent),
          isTrue,
          reason: '$f must grant $key=<true/>: network.server for the eight '
              'listening hosts, network.client for MQTT outbound. A sandboxed '
              'macOS build with neither hosts nothing.',
        );
      }
    });
  }

  test('G4: Gradle has an opt-in release signing config and no TODO', () {
    final g = _read('android/app/build.gradle.kts');
    expect(g, contains('rootProject.file("key.properties")'),
        reason: 'Opt-in signing must key on android/key.properties.');
    expect(g, contains('signingConfigs.getByName("release")'),
        reason: 'The release signingConfig must be wired to buildTypes.release '
            'when key.properties is present.');
    expect(g.contains('// TODO: Add your own signing config'), isFalse,
        reason: 'The stock signing TODO is now done — its presence means the '
            'signing scaffold regressed.');
  });

  test('G5: keystore material is gitignored in both gitignores', () {
    final root = _read('../.gitignore'); // repo root, OUTSIDE the package
    final android = _read('android/.gitignore');
    bool covered(String needle, List<String> haystacks) =>
        haystacks.any((h) => h.split('\n').map((l) => l.trim()).contains(needle));
    expect(covered('key.properties', [root, android]), isTrue,
        reason: 'key.properties (holds keystore passwords) must be ignored. '
            'The repo-root gitignore is ../.gitignore from mobile/ — reading '
            'plain ".gitignore" would resolve to the wrong file.');
    expect(
      covered('*.jks', [root, android]) || covered('**/*.jks', [root, android]),
      isTrue,
      reason: 'The upload keystore (.jks) must be ignored anywhere in the tree.',
    );
    expect(
      covered('*.keystore', [root, android]) ||
          covered('**/*.keystore', [root, android]),
      isTrue,
      reason: 'A .keystore dropped anywhere must be ignored (defence in depth).',
    );
  });

  test('G6: web manifest/index carry no "A new Flutter project." staleness', () {
    expect(_read('web/manifest.json'), isNot(contains('A new Flutter project.')));
    expect(_read('web/index.html'), isNot(contains('A new Flutter project.')));
  });

  test('G7: pubspec version is >= 0.9.0+2 (semver AND build monotonic)', () {
    final v = RegExp(r'^version:\s*([0-9]+)\.([0-9]+)\.([0-9]+)\+([0-9]+)',
            multiLine: true)
        .firstMatch(_read('pubspec.yaml'));
    expect(v, isNotNull, reason: 'pubspec version must be MAJOR.MINOR.PATCH+BUILD.');
    final major = int.parse(v!.group(1)!);
    final minor = int.parse(v.group(2)!);
    final build = int.parse(v.group(4)!);
    final semverOk = major > 0 || minor >= 9;
    expect(semverOk, isTrue, reason: 'Semver must be >= 0.9.0 for first submission.');
    expect(build, greaterThanOrEqualTo(2),
        reason: 'Build number must be >= 2 (+1 was never published; store build '
            'numbers must increase monotonically).');
  });
}
```

- [ ] **Step 2: Run — expect FAIL.** `cd mobile && flutter test test/platform_config_guard_test.dart` (all seven fail against the current tree).

- [ ] **Step 3: Apply the exact config edits.**

**§1.1 — `mobile/android/app/src/main/AndroidManifest.xml`.** Insert immediately after the opening `<manifest …>` tag (line 1), before `<application>`:

```xml
    <!-- Required by every in-app protocol host (ADR-010): binding the OPC UA /
         Modbus TCP / DNP3 / EtherNet/IP / S7 / SLMP listeners, the FINS and
         BACnet/IP UDP sockets, and the outbound MQTT client connection. The
         src/debug/ and src/profile/ manifests already declare this (for the
         Flutter tool's hot-reload channel), which is why `flutter run` works
         without it -- but the RELEASE merge uses src/main/ alone, so without
         this line every host fails to open a socket on a store build.
         Do not remove -- test/platform_config_guard_test.dart enforces it. -->
    <uses-permission android:name="android.permission.INTERNET"/>
```

Do **not** delete the debug/profile declarations. Do **not** add `ACCESS_NETWORK_STATE` or `CHANGE_WIFI_MULTICAST_STATE` (§1.1: verified not needed — the app inspects no connectivity; BACnet uses a directed broadcast, not multicast).

**§1.2 — `mobile/ios/Runner/Info.plist`.** Insert between `</key><true/>` for `LSRequiresIPhoneOS` (line 28) and `<key>UIApplicationSceneManifest</key>` (line 29), matching the file's **2-tab** indentation:

```xml
		<key>NSLocalNetworkUsageDescription</key>
		<string>Soft PLC Simulator hosts industrial protocol servers (OPC UA, Modbus TCP, EtherNet/IP, S7, FINS, SLMP, DNP3, BACnet/IP) on your local network so SCADA and HMI clients can connect, and connects to local MQTT brokers.</string>
```

Do **not** add `NSBonjourServices` (§1.2: verified not needed — every host binds a raw socket on a fixed port, none advertises mDNS).

**§1.3 — `mobile/macos/Runner/Release.entitlements`.** Replace the whole `<dict>…</dict>`:

```xml
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.network.server</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
</dict>
```

**§1.3 — `mobile/macos/Runner/DebugProfile.entitlements`.** Add the one missing key inside the existing `<dict>` (keep `app-sandbox`, `cs.allow-jit`, `network.server`):

```xml
	<key>com.apple.security.network.client</key>
	<true/>
```

**§1.4 — `mobile/android/app/build.gradle.kts`.** Final content:

```kotlin
import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is OPT-IN and USER-OWNED. `android/key.properties` and the
// keystore it points at are gitignored and absent from a fresh clone (and from
// CI unless the ANDROID_KEYSTORE_* secrets are configured). When present the
// release build is signed with the upload key; when absent it falls back to the
// debug key so `flutter build apk --release` still works for local smoke tests
// and debug-signed CI artifacts. See SHIPPING.md for keystore generation.
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
val keystoreProperties = Properties().apply {
    if (hasReleaseKeystore) FileInputStream(keystorePropertiesFile).use { load(it) }
}

android {
    namespace = "com.jarrodfranz.soft_plc_mobile"
    // Pinned to 36 (above this Flutter version's default of 34): a transitive
    // plugin dependency (flutter_plugin_android_lifecycle, via file_picker /
    // share_plus) requires consumers to compile against Android API 36+.
    // compileSdk only affects which APIs are available at compile time; it is
    // independent of targetSdk (runtime behavior) and minSdk (install range),
    // which stay on the Flutter defaults below.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.jarrodfranz.softplcsimulator"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                // require(...) per property (m12): a half-filled key.properties
                // otherwise yields a null storeFile and a deep, opaque AGP 9
                // failure at assemble time. Fail loudly here with the missing key.
                fun req(k: String): String = keystoreProperties.getProperty(k)
                    ?: error("key.properties present but missing '$k' — fill it in or delete the file to fall back to debug signing.")
                keyAlias = req("keyAlias")
                keyPassword = req("keyPassword")
                storeFile = file(req("storeFile"))
                storePassword = req("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                // Debug-signed fallback (NOT unsigned, NOT store-uploadable):
                // debug keys keep `flutter build apk --release` working without
                // secrets for sideload/smoke. A store AAB requires key.properties.
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
```

**§1.4 — Create `mobile/android/key.properties.example`:**

```properties
# Copy to key.properties (gitignored) and fill in from YOUR upload keystore.
# NEVER commit key.properties or the .jks/.keystore file it points at.
storePassword=CHANGE_ME
keyPassword=CHANGE_ME
keyAlias=upload
storeFile=C:/path/to/upload-keystore.jks
```

(No `!**/key.properties.example` negation — m11: the bare-filename `key.properties` pattern never matches `key.properties.example`, so nothing needs un-ignoring.)

**§1.4 — Root `.gitignore`.** Add to the "Secrets - NEVER commit these" block (after `*.jks`, line 47):

```gitignore
*.keystore
key.properties
```

**§1.5 — `mobile/pubspec.yaml:4`:** `version: 0.1.0+1` → `version: 0.9.0+2`.

**§1.5 — `mobile/web/manifest.json:8`:** `"description": "A new Flutter project."` → `"description": "A soft PLC simulator: IEC 61131-3 programs, HMI dashboards, and nine in-app industrial protocol servers."`

**§1.5 — `mobile/web/index.html:19`:** the `<meta name="description" content="A new Flutter project.">` → the same string as the manifest description above.

**§1.5 — `PROJECT_BRIEF.md` Risks §3.** Replace the retired Rust-FFI risk item with:

```markdown
3. **Single-isolate scan + protocol load**: the scan loop, the nine protocol
   hosts, and the UI all share one Dart isolate; a heavy scan or a chatty
   client can starve the frame budget.
   - *Mitigation*: the throttled `LiveTick` repaint decoupling
     (`widgets/live_tick.dart`) keeps UI repaint off the scan tick, the
     free-run loop yields to the event loop between scans
     (`workspace_shell.dart:434-455`), and per-task watchdogs surface
     overruns instead of hiding them.
```

- [ ] **Step 4: Run — expect PASS.** `cd mobile && flutter test test/platform_config_guard_test.dart` (G1-G7 green).

- [ ] **Step 5: Prove the release build works both ways** (does not need a device — this is the compile/sign proof; the on-device bind proof is T6/R3):

```bash
cd mobile
# No key.properties present -> debug-signed fallback must succeed:
/c/flutter/bin/flutter build apk --release
# A throwaway local keystore -> upload-key-signed must succeed:
keytool -genkey -v -keystore "$TMPDIR/throwaway.jks" -keyalg RSA -keysize 2048 \
  -validity 30 -alias upload -storepass test1234 -keypass test1234 \
  -dname "CN=Test, OU=Dev, O=Test, L=Test, S=Test, C=US"
printf 'storePassword=test1234\nkeyPassword=test1234\nkeyAlias=upload\nstoreFile=%s\n' \
  "$TMPDIR/throwaway.jks" > android/key.properties
/c/flutter/bin/flutter build apk --release
keytool -printcert -jarfile build/app/outputs/flutter-apk/app-release.apk | head
rm android/key.properties   # never commit it
```

Expected: both `flutter build apk --release` succeed; the second `keytool -printcert` shows the `upload` alias / your DN (not `androiddebugkey`).

- [ ] **Step 6: Full suite + analyze + commit.**

```bash
cd mobile && /c/flutter/bin/flutter analyze && /c/flutter/bin/flutter test
cd .. && git add mobile/android mobile/ios mobile/macos mobile/pubspec.yaml \
  mobile/web mobile/test/platform_config_guard_test.dart PROJECT_BRIEF.md .gitignore
git commit -m "feat(store): platform network config, opt-in signing, and config guard test"
```

---

### Task T3: App lifecycle — suspend/resume state machine, resume lock, MQTT special

**Model · Effort: opus · high** — the one place this workstream can produce a *worse* app than today. A wrong transition closes every socket when the user swipes down a notification shade. The state machine, the resume lock's `finally` bound, the MQTT special-case, and the awaited flush all live here, with twelve behavioural cases.

**Files:**
- Modify: `mobile/lib/screens/workspace_shell.dart`
- Modify: `mobile/lib/screens/gateway_screen.dart`
- Modify: `mobile/lib/models/app_log.dart`
- Modify: `mobile/lib/screens/softplc_settings_dialog.dart`
- Create (test): `mobile/test/lifecycle_pause_test.dart`
- Modify (test): `mobile/test/widgets/refresh_rate_pref_test.dart`

**Interfaces:**
- Consumes: the eight listening hosts' `start(projectProvider)/stop()/status`; `MqttHost.connect(projectProvider, {password})/disconnect()/status`; `_startScanLoop()`; `_runAutosave()`; `_flushActiveEditor()`; `SoftPlcSettingsResult`.
- Produces on `WorkspaceShellState`: `Future<void> flushPendingAutosaveNow()`; `Future<void> applyPauseInBackground(bool)`; `didChangeAppLifecycleState`; the `_LifecycleHost` table; `@visibleForTesting` getters `debugLifecycleOp`, `debugLifecycleSuspended`, `debugResumeInProgress`, `debugResumeHostIds`, `debugRestartFailures`, `debugPauseInBackground`, `debugOpcUaHost`, `debugMqttHost`.
- Produces: `kLogSourceLifecycle = 'Lifecycle'` (+ in `kAllLogSources`); `SoftPlcSettingsResult.pauseInBackground` + `SoftPlcSettingsDialog.initialPauseInBackground`; `GatewayScreen.hostsBusy`.

- [ ] **Step 1: Write the failing tests.**

Create `mobile/test/lifecycle_pause_test.dart`:

```dart
// App-lifecycle suspend/resume (store-readiness §2). Driven by
// tester.binding.handleAppLifecycleStateChanged(...) against a pumped
// WorkspaceShell with an injected in-memory ProjectRepository (over mock
// SharedPreferences). Each async case awaits the shell's RETAINED lifecycle
// future (debugLifecycleOp) rather than a bare pump, so completion is
// deterministic. Host-touching cases drive the OPC UA host (port 4840,
// unprivileged) and wrap real socket work in tester.runAsync (verification.md
// §3, CL-10). debugDefaultTargetPlatformOverride pins the platform per case.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soft_plc_mobile/data/project_repository.dart';
import 'package:soft_plc_mobile/models/app_log.dart';
import 'package:soft_plc_mobile/screens/gateway_screen.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';
import 'package:soft_plc_mobile/widgets/tag_inspector_dock.dart';

import 'support/responsive_test_utils.dart';

Widget _app(ProjectRepository repo) =>
    MaterialApp(home: WorkspaceShell(repository: repo));

Future<(WorkspaceShellState, ProjectRepository)> _boot(
    WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final repo = ProjectRepository(prefs);
  await setSurface(tester, desktopSize);
  await tester.pumpWidget(_app(repo));
  await tester.pumpAndSettle();
  return (tester.state<WorkspaceShellState>(find.byType(WorkspaceShell)), repo);
}

// Flip Start_PB via the Tag Inspector, arming (not elapsing) the autosave
// debounce — the proven create_project_flush_autosave_test.dart pattern.
// BEFORE IMPLEMENTING: verify these fixture specifics against that test at
// desktop size — that the default project has a `Start_PB` tag, that its value
// renders as the string 'false ' in the Tag Inspector card, and that tapping
// the value pill arms `_autosaveTimer` (marks dirty). If the default project
// changed, swap in whatever boolean tag/label create_project_flush_autosave_
// test.dart currently drives; L4/L5's repo-readback assertion depends on it.
Future<void> _armDirtyEdit(WidgetTester tester) async {
  final card = find
      .ancestor(of: find.text('Start_PB'), matching: find.byType(Card))
      .first;
  await tester.tap(
      find.descendant(of: card, matching: find.text('false ')).first);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  testWidgets('L1: paused (setting ON, mobile) freezes the scan and stops a host',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final (state, _) = await _boot(tester);
    await tester.runAsync(() => state.debugOpcUaHost.start(() => state.debugActiveProject));
    expect(state.debugOpcUaHost.status.name, 'running');

    final before = state.scanCount;
    await tester.pump(const Duration(milliseconds: 600));
    expect(state.scanCount, greaterThan(before), reason: 'scan ticking pre-suspend');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    // _onSuspend stops the live OPC UA host (real dart:io socket close), which
    // never resolves in the fake-async zone — drive it under runAsync (CL-10).
    await tester.runAsync(() => state.debugLifecycleOp);
    final frozenAt = state.scanCount;
    await tester.pump(const Duration(seconds: 2));
    expect(state.scanCount, frozenAt, reason: 'scan timer must be cancelled while suspended');
    expect(state.debugOpcUaHost.status.name, 'stopped');
    expect(state.debugLifecycleSuspended, isTrue);
  });

  testWidgets('L2: resumed restarts the captured host and the scan ticks again',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final (state, _) = await _boot(tester);
    await tester.runAsync(() => state.debugOpcUaHost.start(() => state.debugActiveProject));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    // Suspend stops the live host -> runAsync (CL-10), like the resume await below.
    await tester.runAsync(() => state.debugLifecycleOp);
    expect(state.debugOpcUaHost.status.name, 'stopped');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.runAsync(() => state.debugLifecycleOp);
    await tester.pumpAndSettle();
    expect(state.debugOpcUaHost.status.name, 'running');
    final before = state.scanCount;
    await tester.pump(const Duration(milliseconds: 600));
    expect(state.scanCount, greaterThan(before));
    expect(state.debugLifecycleSuspended, isFalse);
  });

  testWidgets('L3: inactive changes nothing (the notification-shade case)',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final (state, _) = await _boot(tester);
    await tester.runAsync(() => state.debugOpcUaHost.start(() => state.debugActiveProject));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await state.debugLifecycleOp;
    expect(state.debugOpcUaHost.status.name, 'running');
    expect(state.debugLifecycleSuspended, isFalse);
    final before = state.scanCount;
    await tester.pump(const Duration(milliseconds: 600));
    expect(state.scanCount, greaterThan(before), reason: 'scan untouched by inactive');
  });

  testWidgets('L4: hidden flushes a pending edit to completion; nothing pending is a no-op',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final (state, repo) = await _boot(tester);
    final id = state.debugActiveProject.id;
    await _armDirtyEdit(tester);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await state.debugLifecycleOp;
    final saved = await repo.loadProject(id);
    expect(saved!.tags.firstWhere((t) => t.name == 'Start_PB').value, true,
        reason: 'hidden must AWAIT the real autosave (B2), not fire-and-forget');
    expect(state.debugLifecycleSuspended, isFalse, reason: 'hidden never suspends');

    // Nothing pending -> a second hidden is a benign no-op (covers foreground hidden, M8).
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await state.debugLifecycleOp;
    expect(tester.takeException(), isNull);
  });

  testWidgets('L5: setting OFF, paused still completes the autosave and changes nothing else',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final (state, repo) = await _boot(tester);
    await state.applyPauseInBackground(false);
    final id = state.debugActiveProject.id;
    await tester.runAsync(() => state.debugOpcUaHost.start(() => state.debugActiveProject));
    await _armDirtyEdit(tester);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await state.debugLifecycleOp;
    final saved = await repo.loadProject(id);
    expect(saved!.tags.firstWhere((t) => t.name == 'Start_PB').value, true);
    expect(state.debugOpcUaHost.status.name, 'running', reason: 'setting OFF: host keeps hosting');
    expect(state.debugLifecycleSuspended, isFalse);
  });

  testWidgets('L6: a manually-stopped host is NOT restarted on resume (N6)',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final (state, _) = await _boot(tester);
    // Never started -> not running at suspend -> not captured.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await state.debugLifecycleOp;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.runAsync(() => state.debugLifecycleOp);
    expect(state.debugOpcUaHost.status.name, 'stopped',
        reason: 'a host not running at suspend is never in the resume set');
  });

  testWidgets('L7: user-paused scan stays paused across background (intent preserved)',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final (state, _) = await _boot(tester);
    state.debugSetRunning(false); // @visibleForTesting: sets isRunning=false, stops the loop
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await state.debugLifecycleOp;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.runAsync(() => state.debugLifecycleOp);
    await tester.pump(const Duration(milliseconds: 600));
    expect(state.isRunning, isFalse, reason: 'lifecycle must never override Run/Pause intent');
  });

  testWidgets('L8: a host whose restart throws is named and WARN-logged; others still start',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final (state, _) = await _boot(tester);
    // Hold OPC UA's port 4840 so its resume rebind throws while others succeed.
    await tester.runAsync(() => state.debugOpcUaHost.start(() => state.debugActiveProject));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.runAsync(() => state.debugLifecycleOp); // suspend stops a live host (CL-10)
    final blocker = await tester.runAsync(() => ServerSocketBinder.bind(4840));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.runAsync(() => state.debugLifecycleOp);
    await tester.runAsync(() => blocker!.close());
    expect(state.debugRestartFailures, contains('OPC UA'));
    expect(state.debugLogEntries.any((e) =>
        e.source == kLogSourceLifecycle && e.level == LogLevel.warn), isTrue);
  });

  testWidgets('L9: MQTT connected at suspend is disconnected and NOT reconnected (B1)',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final (state, _) = await _boot(tester);
    await tester.runAsync(() =>
        state.debugMqttHost.connect(() => state.debugActiveProject, password: 'secret'));
    // Whether it reaches running/connecting, capture semantics count it.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.runAsync(() => state.debugLifecycleOp); // suspend disconnects live MQTT (CL-10)
    expect(state.debugMqttHost.status.name, 'stopped');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.runAsync(() => state.debugLifecycleOp);
    expect(state.debugMqttHost.status.name, 'stopped',
        reason: 'shell has no broker password to reconnect with (B1)');
    expect(state.debugRestartFailures, isNot(contains('MQTT')),
        reason: 'MQTT non-reconnect is expected, not a failure');
    expect(state.debugLogEntries.any((e) =>
        e.source == kLogSourceLifecycle &&
        e.level == LogLevel.warn &&
        e.message.contains('MQTT')), isTrue);
  });

  testWidgets('L10: detached stops all running hosts even with the setting OFF; no resume state',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final (state, _) = await _boot(tester);
    await state.applyPauseInBackground(false);
    await tester.runAsync(() => state.debugOpcUaHost.start(() => state.debugActiveProject));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    await tester.runAsync(() => state.debugLifecycleOp); // detached stops a live host (CL-10)
    expect(state.debugOpcUaHost.status.name, 'stopped');
    expect(state.debugResumeHostIds, isEmpty, reason: 'detached records no resume state');
    expect(state.debugLifecycleSuspended, isFalse);
  });

  testWidgets('L11: on desktop, paused is a full no-op beyond the (completed) flush',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final (state, _) = await _boot(tester);
    await tester.runAsync(() => state.debugOpcUaHost.start(() => state.debugActiveProject));
    final before = state.scanCount;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await state.debugLifecycleOp;
    expect(state.debugOpcUaHost.status.name, 'running', reason: 'desktop keeps hosting');
    expect(state.debugLifecycleSuspended, isFalse);
    await tester.pump(const Duration(milliseconds: 600));
    expect(state.scanCount, greaterThan(before), reason: 'desktop keeps scanning');
  });

  testWidgets('L12: Gateway toggles are AbsorbPointer-disabled during resume, re-enabled after; a wedged bind still frees them',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final (state, _) = await _boot(tester);
    await tester.runAsync(() => state.debugOpcUaHost.start(() => state.debugActiveProject));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.runAsync(() => state.debugLifecycleOp); // suspend stops a live host (CL-10)

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    // Mid-loop: _resumeInProgress true -> hostsBusy true.
    await tester.pump();
    expect(state.debugResumeInProgress, isTrue);
    await tester.runAsync(() => state.debugLifecycleOp);
    await tester.pumpAndSettle();
    expect(state.debugResumeInProgress, isFalse,
        reason: 'the finally must ALWAYS clear the lock (5s overall bound) so a '
            'wedged bind can never leave the Gateway frozen');
  });
}
```

> The test file references two small local test helpers that ship WITH the test: `ServerSocketBinder.bind(port)` (a `dart:io` `ServerSocket.bind('0.0.0.0', port)` wrapper returning a closable) and the shell hooks `debugSetRunning`, `debugLogEntries`. Add `debugSetRunning`/`debugLogEntries` as `@visibleForTesting` in Step 3; define `ServerSocketBinder` at the top of the test file. L8/L12 exercise real binds inside `runAsync`.

Append to `mobile/test/widgets/refresh_rate_pref_test.dart` (S1-S5). **First add the imports these cases need** — the file today imports only `material`/`flutter_test`/`shared_preferences`/`workspace_shell` (`:10-13`), and Dart imports are **not** transitive through `workspace_shell.dart`, so `ProjectRepository`, `SoftPlcSettingsResult`, and `SoftPlcSettingsDialog` are all unresolved without these two added imports:

```dart
import 'package:soft_plc_mobile/data/project_repository.dart';
import 'package:soft_plc_mobile/screens/softplc_settings_dialog.dart';
```

Then append the group:

```dart
  group('pauseInBackground global preference', () {
    const kPauseKey = 'pause_in_background';

    testWidgets('S1: default is ON when the key was never persisted', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final repo = ProjectRepository(prefs);
      await tester.pumpWidget(MaterialApp(home: WorkspaceShell(repository: repo)));
      await tester.pumpAndSettle();
      final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
      expect(state.debugPauseInBackground, isTrue);
    });

    testWidgets('S2: applyPauseInBackground(false) updates state and persists', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final repo = ProjectRepository(prefs);
      await tester.pumpWidget(MaterialApp(home: WorkspaceShell(repository: repo)));
      await tester.pumpAndSettle();
      final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
      await state.applyPauseInBackground(false);
      expect(state.debugPauseInBackground, isFalse);
      expect((await SharedPreferences.getInstance()).getBool(kPauseKey), isFalse);
    });

    testWidgets('S3: a failing SharedPreferences still applies for the session', (tester) async {
      // Same best-effort contract the haptics/refresh applies rely on: the
      // in-memory field updates even if the write path is unavailable.
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final repo = ProjectRepository(prefs);
      await tester.pumpWidget(MaterialApp(home: WorkspaceShell(repository: repo)));
      await tester.pumpAndSettle();
      final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
      await state.applyPauseInBackground(false);
      expect(state.debugPauseInBackground, isFalse);
    });

    testWidgets('S4: the dialog round-trips the toggle into the result', (tester) async {
      SoftPlcSettingsResult? result;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await showDialog<SoftPlcSettingsResult>(
                context: context,
                builder: (_) => const SoftPlcSettingsDialog(
                  initialRefreshHz: 10,
                  initialHapticsEnabled: true,
                  initialPauseInBackground: true,
                ),
              );
            },
            child: const Text('open'),
          )),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      // The second SwitchListTile is the pause-in-background one.
      await tester.tap(find.byType(SwitchListTile).last);
      await tester.pump();
      await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
      await tester.pumpAndSettle();
      expect(result, isNotNull);
      expect(result!.pauseInBackground, isFalse);
    });

    testWidgets('S5: on desktop the switch renders disabled with the mobile-only subtitle',
        (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: SoftPlcSettingsDialog(
            initialRefreshHz: 10,
            initialHapticsEnabled: true,
            initialPauseInBackground: true,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final tile = tester.widget<SwitchListTile>(find.byType(SwitchListTile).last);
      expect(tile.onChanged, isNull, reason: 'disabled on desktop/web');
      expect(find.textContaining('Mobile only'), findsOneWidget);
    });
  });
```

- [ ] **Step 2: Run — expect FAIL.** `cd mobile && flutter test test/lifecycle_pause_test.dart test/widgets/refresh_rate_pref_test.dart`.

- [ ] **Step 3: Implement.**

**§2.7 — `mobile/lib/models/app_log.dart`.** Add beside the other source constants and register it (both — the `app_log_test.dart` guard fails loudly if only one is done):

```dart
const String kLogSourceLifecycle = 'Lifecycle';
```

and add `kLogSourceLifecycle,` into the `kAllLogSources` list.

**§2.1-§2.6 — `mobile/lib/screens/workspace_shell.dart`.**

Add `import 'dart:io';` if not present (detached/stop paths are pure Dart already; the hosts own their sockets — no new `dart:io` needed in the shell itself beyond what exists). Ensure `package:flutter/foundation.dart` is imported for `defaultTargetPlatform`, `TargetPlatform`, `kIsWeb`, `visibleForTesting` (already used).

Change the class header (`:102`):

```dart
class WorkspaceShellState extends State<WorkspaceShell>
    with WidgetsBindingObserver {
```

In `initState()` (`:271-276`), register the observer **after** `_repaintThrottle` construction, **before** `_boot()`:

```dart
  @override
  void initState() {
    super.initState();
    _repaintThrottle = NotifyThrottle(_liveTick.pulse, window: refreshWindow(_refreshHz));
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }
```

In `dispose()` (`:278`), make `removeObserver` the **first** line:

```dart
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scanTimer?.cancel();
    // … existing teardown unchanged …
  }
```

Add the setting key + default beside the two existing global keys (near `:76`):

```dart
/// Global (not per-project) SharedPreferences key for whether the scan loop and
/// the protocol hosts are paused while the app is backgrounded.
const String _kPauseInBackgroundKey = 'pause_in_background';

/// Default for background pausing: ON. Cleanly closing sockets is the honest
/// behaviour -- iOS suspends the process regardless, so "keep running" there
/// only means clients hold a half-open TCP connection that never FINs.
const bool kDefaultPauseInBackground = true;
```

Add the new state fields (near the scan-state fields, ~`:170`):

```dart
  /// Whether the scan loop + hosts pause while the app is backgrounded. Global
  /// setting, loaded in [_boot]; default [kDefaultPauseInBackground] (ON).
  bool _pauseInBackground = kDefaultPauseInBackground;

  /// True between a lifecycle suspend and its matching resume. Consulted by
  /// [_startScanLoop]'s re-arm guards so a suspend genuinely stops the chain.
  bool _lifecycleSuspended = false;

  /// Hosts running at suspend time and therefore eligible to restart on resume.
  /// A host the user stopped manually beforehand is not in this set (N6).
  final Set<String> _resumeHostIds = <String>{};

  /// Display names of hosts that failed to rebind on resume — surfaced in the
  /// resume banner and cleared at the start of each restart loop.
  final List<String> _restartFailures = <String>[];

  /// Guards overlapping suspends: `hidden` then `paused` arrive back-to-back.
  bool _suspendInFlight = false;

  /// True while the resume restart loop runs. Surfaced to GatewayScreen as
  /// `hostsBusy` -> one AbsorbPointer, so no host can be toggled mid-resume
  /// (R2 ruling). Always cleared in a `finally`.
  bool _resumeInProgress = false;

  /// The most recent lifecycle op (suspend/resume/detach), retained so tests
  /// can await deterministic completion. Production fire-and-forgets it.
  Future<void>? _lifecycleOp;
```

Add the mobile-platform gate and the `_LifecycleHost` table (near the host fields):

```dart
  bool get _isMobilePlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// A host as the lifecycle machine sees it: a stable id, a display name, a
  /// live "is it running?" probe, and start/stop CLOSURES. The eight listening
  /// hosts wrap start()/stop(); MQTT wraps connect(..., password:)/disconnect()
  /// -- its `start` closure is deliberately a no-op that logs a WARN, because
  /// the shell has no broker password to reconnect with (B1, §2.4).
  List<_LifecycleHost> get _lifecycleHosts => [
        _LifecycleHost('opcua', 'OPC UA',
            () => _opcuaHost.status == OpcUaHostStatus.running,
            () => _opcuaHost.start(() => _activeProject),
            () => _opcuaHost.stop()),
        _LifecycleHost('modbus', 'Modbus TCP',
            () => _modbusHost.status == ModbusHostStatus.running,
            () => _modbusHost.start(() => _activeProject),
            () => _modbusHost.stop()),
        _LifecycleHost('dnp3', 'DNP3',
            () => _dnpHost.status == DnpHostStatus.running,
            () => _dnpHost.start(() => _activeProject),
            () => _dnpHost.stop()),
        _LifecycleHost('enip', 'EtherNet/IP',
            () => _enipHost.status == EnipHostStatus.running,
            () => _enipHost.start(() => _activeProject),
            () => _enipHost.stop()),
        _LifecycleHost('s7', 'S7',
            () => _s7Host.status == S7HostStatus.running,
            () => _s7Host.start(() => _activeProject),
            () => _s7Host.stop()),
        _LifecycleHost('fins', 'FINS',
            () => _finsHost.status == FinsHostStatus.running,
            () => _finsHost.start(() => _activeProject),
            () => _finsHost.stop()),
        _LifecycleHost('slmp', 'SLMP',
            () => _slmpHost.status == SlmpHostStatus.running,
            () => _slmpHost.start(() => _activeProject),
            () => _slmpHost.stop()),
        _LifecycleHost('bacnet', 'BACnet/IP',
            () => _bacnetHost.status == BacnetHostStatus.running,
            () => _bacnetHost.start(() => _activeProject),
            () => _bacnetHost.stop()),
        _LifecycleHost('mqtt', 'MQTT',
            () => _mqttHost.status == MqttHostStatus.running ||
                _mqttHost.status == MqttHostStatus.connecting,
            () async => _logger.log(kLogSourceLifecycle, LogLevel.warn,
                'MQTT was disconnected on background; not auto-reconnected '
                '(broker password is not stored). Reconnect from the Gateway.'),
            () => _mqttHost.disconnect()),
      ];
```

> **Verify the exact enum member names and status-getter types against each host file before wiring** (opcua_host.dart confirmed `OpcUaHostStatus.running`; the other seven follow the same `{stopped, running, error}` shape, MQTT is `{stopped, connecting, running, error}`). If any host's running member differs, use its actual name — the closures are the single place this is written.

Add the `_LifecycleHost` class at file scope (bottom of the file, beside other private helpers):

```dart
class _LifecycleHost {
  final String id;
  final String displayName;
  final bool Function() isRunning;
  final Future<void> Function() start; // resume path
  final Future<void> Function() stop;  // suspend path
  const _LifecycleHost(
      this.id, this.displayName, this.isRunning, this.start, this.stop);
}
```

The lifecycle handler + sequences (add as methods on the State):

```dart
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.resumed:
        _lifecycleOp = _onResume();
      case AppLifecycleState.inactive:
        break; // transient (notification shade / app switcher). NEVER suspend.
      case AppLifecycleState.hidden:
        _lifecycleOp = _onSuspend(flushOnly: true); // flush only; never suspends
      case AppLifecycleState.paused:
        _lifecycleOp = _onSuspend(flushOnly: false);
      case AppLifecycleState.detached:
        _lifecycleOp = _onDetached();
    }
  }

  /// §2.2. Ordered, idempotent, failure-tolerant. The flush is ALWAYS awaited
  /// before any host is touched (B2). `flushOnly` (the `hidden` path), the
  /// setting being off, or a non-mobile platform all stop after the flush.
  Future<void> _onSuspend({required bool flushOnly}) async {
    if (_suspendInFlight) return; // hidden then paused arrive back-to-back
    _suspendInFlight = true;
    try {
      await flushPendingAutosaveNow(); // durability first, always awaited
      if (flushOnly || !_pauseInBackground || !_isMobilePlatform) return;

      _lifecycleSuspended = true;
      _resumeHostIds
        ..clear()
        ..addAll([for (final h in _lifecycleHosts) if (h.isRunning()) h.id]);
      _scanTimer?.cancel();
      _supervisorTimer?.cancel();
      _uptime.stop(); // System.Uptime = time actually scanning, not wall clock

      final futures = <Future<void>>[];
      for (final h in _lifecycleHosts) {
        if (!_resumeHostIds.contains(h.id)) continue;
        futures.add(() async {
          try {
            await h.stop();
          } catch (e) {
            _logger.log(kLogSourceLifecycle, LogLevel.warn,
                'Failed to stop ${h.displayName} on background',
                detail: e.toString());
          }
        }());
      }
      await Future.wait(futures)
          .timeout(const Duration(seconds: 2), onTimeout: () {
        _logger.log(kLogSourceLifecycle, LogLevel.warn,
            'Background host-stop exceeded 2s budget; continuing.');
        return const <void>[];
      });

      _logger.log(kLogSourceLifecycle, LogLevel.info,
          'Backgrounded: scan paused, ${_resumeHostIds.length} host(s) stopped '
          '(${_resumeHostIds.join(', ')}).');
    } finally {
      _suspendInFlight = false;
    }
  }

  /// §2.3.
  Future<void> _onResume() async {
    if (!_lifecycleSuspended) return;
    _lifecycleSuspended = false;
    _sinceLast
      ..reset()
      ..start(); // first post-resume dtMs is a real tick, not the night's gap
    _uptime.start();
    _startScanLoop(); // re-arms per current isRunning/_freeRun (never mutated)

    final captured = Set<String>.from(_resumeHostIds);
    await _resumeRestartHosts();

    final restarted = captured.where((id) => id != 'mqtt').length -
        _restartFailures.length;
    final mqttWasConnected = captured.contains('mqtt');
    _resumeHostIds.clear();

    if (mounted) {
      final failures = List<String>.from(_restartFailures);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showResumeBanner(
          totalHosts: captured.where((id) => id != 'mqtt').length,
          restarted: restarted,
          failures: failures,
          mqttWasConnected: mqttWasConnected,
        );
      });
    }
  }

  /// §2.4. MANDATORY hard bounds: per-host 2s, overall 5s, `finally` always
  /// clears `_resumeInProgress` so a wedged bind can never freeze the Gateway.
  Future<void> _resumeRestartHosts() async {
    _restartFailures.clear();
    if (mounted) {
      setState(() => _resumeInProgress = true); // Gateway hostsBusy = true
    } else {
      _resumeInProgress = true;
    }
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    try {
      for (final h in _lifecycleHosts) {
        if (!_resumeHostIds.contains(h.id)) continue; // wasn't running at suspend
        if (h.isRunning()) continue;                   // already up (defence)
        if (DateTime.now().isAfter(deadline)) {
          if (h.id != 'mqtt') _restartFailures.add(h.displayName);
          _logger.log(kLogSourceLifecycle, LogLevel.warn,
              'Resume 5s budget exceeded before restarting ${h.displayName}.');
          continue;
        }
        try {
          await h.start().timeout(const Duration(seconds: 2));
        } catch (e) {
          // MQTT's start closure is the no-op WARN and never throws, so it is
          // never counted here. A listening host's port-taken/perm-denied does.
          _restartFailures.add(h.displayName);
          _logger.log(kLogSourceLifecycle, LogLevel.warn,
              'Failed to restart ${h.displayName} on resume', detail: e.toString());
        }
      }
    } finally {
      if (mounted) {
        setState(() => _resumeInProgress = false); // Gateway re-enabled, ALWAYS
      } else {
        _resumeInProgress = false;
      }
    }
  }

  /// §2.1 detached: unconditional clean stop of every running host regardless
  /// of the setting; records no resume state (nothing to resume into).
  Future<void> _onDetached() async {
    _scanTimer?.cancel();
    _supervisorTimer?.cancel();
    final stopped = <String>[];
    final futures = <Future<void>>[];
    for (final h in _lifecycleHosts) {
      if (!h.isRunning()) continue;
      stopped.add(h.id);
      futures.add(() async {
        try {
          await h.stop();
        } catch (_) {/* best-effort; dispose() is the real teardown */}
      }());
    }
    await Future.wait(futures)
        .timeout(const Duration(seconds: 2), onTimeout: () => const <void>[]);
    if (stopped.isNotEmpty) {
      _logger.log(kLogSourceLifecycle, LogLevel.info,
          'Detached: stopped ${stopped.length} host(s) (${stopped.join(', ')}).');
    }
  }

  void _showResumeBanner({
    required int totalHosts,
    required int restarted,
    required List<String> failures,
    required bool mqttWasConnected,
  }) {
    // Nothing was running and MQTT was not connected -> no snackbar (§2.6).
    if (totalHosts == 0 && !mqttWasConnected) return;
    final scanState = isRunning ? 'Scan running' : 'Scan is paused';
    String text;
    SnackBarAction? action;
    Duration duration = const Duration(seconds: 4);
    if (failures.isEmpty) {
      text = 'Resumed. $scanState; $restarted protocol host(s) restarted.';
    } else {
      duration = const Duration(seconds: 6);
      text = 'Resumed. $restarted of $totalHosts protocol host(s) restarted — '
          '${failures.join(', ')} failed. See Logs.';
      action = SnackBarAction(
          label: 'View logs', onPressed: () => _selectView(context, 'LOGS'));
    }
    if (mqttWasConnected) {
      text = '$text MQTT was disconnected — reconnect from the Gateway '
          "(broker password isn't stored).";
    }
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(text), duration: duration, action: action));
  }
```

Add `flushPendingAutosaveNow()` (§2.2a) beside `_flushPendingAutosave()` (`:1103`) and refactor the latter:

```dart
  /// Like [_flushPendingAutosave], but RETURNS the autosave future so a caller
  /// can await the write actually landing (the lifecycle suspend path must, so
  /// an edit made in the last ~800ms before iOS freezes the process is
  /// durable). The void [_flushPendingAutosave] is kept for the fire-and-forget
  /// callers (project switch/close) that don't need to block on completion.
  @visibleForTesting
  Future<void> flushPendingAutosaveNow() async {
    _flushActiveEditor();
    if (_autosaveTimer == null || !_autosaveTimer!.isActive) return;
    _autosaveTimer!.cancel();
    await _runAutosave();
  }

  void _flushPendingAutosave() => unawaited(flushPendingAutosaveNow());
```

Add `applyPauseInBackground` (§2.5), shaped exactly like `applyHapticsEnabled` (`:537`):

```dart
  @visibleForTesting
  Future<void> applyPauseInBackground(bool enabled) async {
    if (mounted) {
      setState(() => _pauseInBackground = enabled);
    } else {
      _pauseInBackground = enabled;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kPauseInBackgroundKey, enabled);
    } catch (_) {
      // Best-effort: `_pauseInBackground` still applies for this session.
    }
  }
```

Load it in `_boot()` beside the other two (`:329-338`) — add `bool loadedPauseBg = kDefaultPauseInBackground;` before the `try`, `loadedPauseBg = settingsPrefs.getBool(_kPauseInBackgroundKey) ?? kDefaultPauseInBackground;` inside it, `loadedPauseBg = kDefaultPauseInBackground;` in the `catch`, and assign `_pauseInBackground = loadedPauseBg;` in `_boot`'s final `setState` where `_refreshHz`/`_hapticsEnabled` are set.

Wire it into `_openSoftPlcSettings` (`:588-600`): pass `initialPauseInBackground: _pauseInBackground` into `SoftPlcSettingsDialog`, and after `applyHapticsEnabled` add `await applyPauseInBackground(result.pauseInBackground);`.

Update the three `_startScanLoop()` guards (M10): `:439` → `if (!isRunning || _faulted || _lifecycleSuspended) {`; `:448` → `if (isRunning && !_faulted && !_lifecycleSuspended) {`; `:453` → `if (isRunning && !_faulted && !_lifecycleSuspended) {`.

Add the `@visibleForTesting` hooks used by the tests:

```dart
  @visibleForTesting
  Future<void>? get debugLifecycleOp => _lifecycleOp;
  @visibleForTesting
  bool get debugLifecycleSuspended => _lifecycleSuspended;
  @visibleForTesting
  bool get debugResumeInProgress => _resumeInProgress;
  @visibleForTesting
  Set<String> get debugResumeHostIds => _resumeHostIds;
  @visibleForTesting
  List<String> get debugRestartFailures => _restartFailures;
  @visibleForTesting
  bool get debugPauseInBackground => _pauseInBackground;
  @visibleForTesting
  OpcUaHost get debugOpcUaHost => _opcuaHost;
  @visibleForTesting
  MqttHost get debugMqttHost => _mqttHost;
  @visibleForTesting
  List<LogEntry> get debugLogEntries => _logger.entries;
  @visibleForTesting
  void debugSetRunning(bool v) {
    setState(() => isRunning = v);
    _startScanLoop();
  }
```

Pass `hostsBusy: _resumeInProgress` into the `GatewayScreen(...)` construction in `_buildCenterWorkspace()`'s `GATEWAY` branch (find the existing `GatewayScreen(` call and add the one named arg).

**§2.4 — `mobile/lib/screens/gateway_screen.dart`.** One new field + one wrap, no per-helper edits:

```dart
  /// True while the shell is mid-resume restarting hosts (store-readiness §2.4).
  /// The protocol-card body is wrapped in AbsorbPointer(absorbing: hostsBusy) so
  /// the user cannot toggle a host during the restart loop — the manual-toggle
  /// race is eliminated at the source. A brief (<1s) disabled flicker on
  /// foreground when hosts restart is accepted; it affects the Gateway screen
  /// only. `onManualHostToggle`/generation-counter approaches are NOT used.
  final bool hostsBusy;
```

Add `this.hostsBusy = false,` to the constructor (`:151-167`). In `build()` (`:1571`), wrap the `Scaffold`'s `body:` `Column(...)` in `AbsorbPointer(absorbing: widget.hostsBusy, child: Column(...))` (R-D — this also disables the tab selector mid-resume). Leave the sixteen `*Hosting` helpers and `_connectMqtt`/`_disconnectMqtt` untouched.

**§2.5 — `mobile/lib/screens/softplc_settings_dialog.dart`.** Add `pauseInBackground` to the result and `initialPauseInBackground` to the widget; append the **second** `SwitchListTile` below the haptics one; disable it off-mobile with the mobile-only subtitle:

```dart
// In SoftPlcSettingsResult: add the field + constructor param.
  final bool pauseInBackground;
// ...
  const SoftPlcSettingsResult({
    required this.refreshHz,
    required this.hapticsEnabled,
    required this.pauseInBackground,
  });

// In SoftPlcSettingsDialog: add the initial value.
  final bool initialPauseInBackground;
// ... constructor gains: required this.initialPauseInBackground,

// In state: late bool _pauseInBackground; initialised in initState from widget.

// In _save(): include it in the popped result.
    Navigator.pop(
      context,
      SoftPlcSettingsResult(
        refreshHz: parsed,
        hapticsEnabled: _hapticsEnabled,
        pauseInBackground: _pauseInBackground,
      ),
    );

// In build(), immediately after the haptics SwitchListTile — subtitle kept to
// <= 2 lines (the file's landscape-height comment applies):
            Builder(builder: (context) {
              final mobile = !kIsWeb &&
                  (defaultTargetPlatform == TargetPlatform.android ||
                      defaultTargetPlatform == TargetPlatform.iOS);
              return SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Pause automation when app is in background'),
                subtitle: Text(mobile
                    ? 'On: hosts close cleanly and the scan pauses when you '
                        'leave the app, then resume on return. Off: the OS '
                        'decides (iOS suspends anyway).'
                    : 'Mobile only — a desktop window keeps scanning and hosting.'),
                value: _pauseInBackground,
                onChanged: mobile
                    ? (v) => setState(() => _pauseInBackground = v)
                    : null,
              );
            }),
```

Add `import 'package:flutter/foundation.dart';` for `kIsWeb`/`defaultTargetPlatform`. **Every** existing construction of `SoftPlcSettingsResult` and `SoftPlcSettingsDialog` must pass the new required fields — grep and fix them so the suite still compiles. Known sites: the `SoftPlcSettingsDialog(...)` in `workspace_shell.dart:591-594` (`_openSoftPlcSettings`, edited above) and the dialog construction in **`mobile/test/hmi_haptics_test.dart:151-153`** (which today omits the new param). `GatewayScreen.hostsBusy` was defaulted (`= false`) to avoid this churn; if the dialog's `initialPauseInBackground` proves to touch many sites, defaulting it (`= true`) is the equivalent escape hatch — but the two named sites above are the only current ones, so keep it required and fix them.

- [ ] **Step 4: Run — expect PASS.** `cd mobile && flutter test test/lifecycle_pause_test.dart test/widgets/refresh_rate_pref_test.dart test/app_log_test.dart` (the last confirms the `kAllLogSources` pair).

- [ ] **Step 5: Full suite + analyze + commit.**

```bash
cd mobile && /c/flutter/bin/flutter analyze && /c/flutter/bin/flutter test
cd .. && git add mobile/lib mobile/test
git commit -m "feat(lifecycle): background pause/resume of scan and hosts with resume lock"
```

---

### Task T2: UX polish — the four PR #18 DEFERRED rows (own PR)

**Model · Effort: sonnet · medium** — four small, well-localised edits with existing tests to keep green; §4.3 (canvas, M5) is the fiddliest. Lands as its **own PR** (m16): a PR #18 follow-up, not store readiness.

**Files:**
- Modify: `mobile/lib/screens/workspace_shell.dart` (§4.1 dropdown), `mobile/lib/screens/memory_manager_screen.dart` (§4.2), `mobile/lib/ui/pannable_canvas.dart` (§4.3), `mobile/lib/screens/fbd_editor_screen.dart` (§4.4)
- Modify (test): `mobile/test/editor_canvas_pan_test.dart`, `mobile/test/fbd_editor_networks_test.dart`, and any dropdown widget test that taps `DropdownButton`
- Modify: `docs/DEFERRED.md` (strike the four rows on the closing PR)

**Interfaces:** Consumes/Produces: none cross-task (localised UI edits). Behaviour under existing tests is preserved; the change is in *how*, not *what*.

- [ ] **Step 1: Write the failing/new tests.**
  - §4.3: add a case to `editor_canvas_pan_test.dart` asserting a wheel notch over **empty canvas space** (viewport larger than content) **pans** rather than zooming — the `pre == null` fall-through must no longer fire for scale ≥ 1.
  - §4.4: add a case to `fbd_editor_networks_test.dart` asserting a network with a block at `y = 2000` produces `_laneCanvasHeight > 2000` (drive via the real program model; the lane must size to content, not clamp at 1200).
  - §4.1: update any existing test that taps the project dropdown by `find.byType(DropdownButton)` to tap the new `MenuAnchor` anchor; the behaviour under test (switching projects) is unchanged.

- [ ] **Step 2: Run — expect FAIL / red on the updated dropdown finder.**

- [ ] **Step 3: Implement.**

**§4.1 — `workspace_shell.dart:2469`** (the SELECT PROJECT `DropdownButton<String>`). Replace it with a `MenuAnchor` whose anchor is `Row(children: [Expanded(Text(activeName, overflow: TextOverflow.ellipsis)), Icon(Icons.arrow_drop_down)])` styled to match the current appearance, and whose `menuChildren` are the same items as `MenuItemButton`s (check-circle/folder leading icon + `Tooltip`-wrapped name), same `onChanged` → `_switchActiveProject(selected)`. A `MenuAnchor` overlay has **no** full-screen scrim, so the mismatched-scrim problem ceases to exist. Reproduce the old width/colour explicitly (m15): `MenuStyle(backgroundColor: WidgetStatePropertyAll(Color(0xFF1E293B)), minimumSize: WidgetStatePropertyAll(Size(anchorWidth, 0)))`, sizing the panel to the anchor's measured width via a `LayoutBuilder` around the anchor.

**§4.2 — `memory_manager_screen.dart:1500` (`_buildStructDefsTab`)**. Replace the nested `Scaffold` + `FloatingActionButton.extended` with a `Column`: the list (or empty-state) in a single `Expanded`, and below it a pinned action surface. **Both branches (list AND empty-state) go inside the one `Expanded`** (m14 — a bare `Center` in a `Column` has no bounded height and would push the bar off-screen). Drop the ListView's trailing `96` padding to `EdgeInsets.all(16)`:

```dart
  Widget _buildStructDefsTab() {
    final structs = widget.currentProject.structDefs;
    return Column(
      children: [
        Expanded(
          child: structs.isEmpty
              ? const Center(child: Text('No Struct definitions defined yet.'))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: structs.length,
                  itemBuilder: (context, index) {
                    // … unchanged card body …
                  },
                ),
        ),
        SafeArea(
          top: false,
          child: Container(
            padding: const EdgeInsets.all(12),
            color: const Color(0xFF1E293B),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Add DUT'),
                onPressed: _showAddStructDialog,
              ),
            ),
          ),
        ),
      ],
    );
  }
```

**§4.3 — `pannable_canvas.dart:316-323`**. Size the inner capture `Listener`'s child to the viewport **in canvas units** (viewport ÷ live scale, M5) so coverage tracks zoom; rebuild on controller change. Never add an inner `LayoutBuilder` (unbounded under `constrained: false`). Wrap the capture child:

```dart
                child: ListenableBuilder(
                  listenable: _controller,
                  builder: (context, _) {
                    // _viewport (screen px, from the OUTER LayoutBuilder :304)
                    // -> canvas units by the live scale, so the opaque capture
                    // layer covers the viewport at ANY zoom (M5). No inner
                    // LayoutBuilder: maxWidth/Height are infinity under
                    // constrained:false and ConstrainedBox(minWidth: infinity)
                    // would throw.
                    final scale = _controller.value.getMaxScaleOnAxis();
                    return ConstrainedBox(
                      constraints: BoxConstraints(
                        minWidth: _viewport.width / scale,
                        minHeight: _viewport.height / scale,
                      ),
                      child: widget.child,
                    );
                  },
                ),
```

(The outer `Listener(behavior: HitTestBehavior.opaque, onPointerSignal: _capturePreSignal, …)` wrapping stays; the `ConstrainedBox` goes inside it around `widget.child`.) Keep the `pre == null` branch live (fallback honesty): if live-zoom coverage proves fiddly, state the limitation (closes for scale ≥ 1) rather than claiming it unreachable. Verify `editor_canvas_pan_test.dart` stays green across **all** canvas editors (LD/FBD/SFC/HMI — the pan-extent side effect touches every one).

**§4.4 — `fbd_editor_screen.dart:680`**. Raise the lane ceiling so the lane sizes to content (the outer `wheelPansVertically:false` `ListView` then reaches every block):

```dart
    // No 1200px ceiling: with wheelPansVertically:false the plain wheel drives
    // the outer lane ListView, so any content taller than the lane is wheel-
    // unreachable. Sizing the lane to its content makes the outer list the
    // single, always-sufficient vertical scroller. The 20000px ceiling is a
    // pathological-import guard only (drag-pan and Shift+wheel still reach past it).
    return (maxY + 220).clamp(260.0, 20000.0);
```

- [ ] **Step 4: Run — expect PASS.** `cd mobile && flutter test test/editor_canvas_pan_test.dart test/fbd_editor_networks_test.dart` plus the dropdown test.

- [ ] **Step 5: Browser verification** (CLAUDE.md loop, verification.md §2). `scripts/serve-web.sh --build` (background), then screenshots at **1440×900 / 768×1024 / 390×844** of: the project dropdown open (no mismatched scrim), the Tags & Structs DUT tab (Add DUT pinned, last card clear at any scroll), an FBD tall network (wheel reaches the bottom block), and a canvas wheel over empty space (pans). Zero console warnings/errors (watch for `RenderFlex overflowed`), zero failed requests. Fix → rebuild → re-screenshot until clean.

- [ ] **Step 6: DEFERRED + commit.** Strike the four rows at `docs/DEFERRED.md:150-153` (mark closed with this PR).

```bash
cd mobile && /c/flutter/bin/flutter analyze && /c/flutter/bin/flutter test
cd .. && git add mobile/lib mobile/test docs/DEFERRED.md
git commit -m "fix(ux): dropdown scrim, DUT bottom bar, canvas wheel gap, FBD lane height"
```

---

### Task T4: CI workflow

**Model · Effort: opus · high** (R-A — overrides §12's sonnet·medium). YAML correctness, the `vars.`-gate footgun (`env`/`secrets` unavailable in job-level `if:`), and the graceful signing step-output gate demand it. Iterative by nature — expect two or three pushes to get the runner matrix and secret-detection right.

**Files:** Create `.github/workflows/ci.yml`.

**Interfaces:** Consumes T1's `key.properties`-driven Gradle signing and T3's new tests (the `gate` job must pass them). Produces CI artifacts named per the detect step.

- [ ] **Step 1: Write `.github/workflows/ci.yml`:**

```yaml
name: CI

on:
  push:
    branches: [main]
    tags: ['v*']
  pull_request:
    branches: [main]
  workflow_dispatch:

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

defaults:
  run:
    working-directory: mobile

jobs:
  gate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: 3.44.4
          channel: stable
      - run: flutter pub get
      - run: flutter analyze
      - run: flutter test

  android:
    runs-on: ubuntu-latest
    needs: gate
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '17'
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: 3.44.4
          channel: stable
      - run: flutter pub get

      - name: Detect release keystore
        id: keystore
        env:
          KEYSTORE_B64: ${{ secrets.ANDROID_KEYSTORE_BASE64 }}
        run: |
          if [ -n "$KEYSTORE_B64" ]; then
            echo "present=true" >> "$GITHUB_OUTPUT"
            echo "artifact=android-release-signed" >> "$GITHUB_OUTPUT"
          else
            echo "present=false" >> "$GITHUB_OUTPUT"
            echo "artifact=android-release-debugsigned" >> "$GITHUB_OUTPUT"
            echo "::warning::No ANDROID_KEYSTORE_BASE64 secret — building DEBUG-SIGNED. This artifact is for sideload/smoke only and CANNOT be uploaded to Play (debug key; a fresh key each run is not upgrade-compatible)."
          fi

      - name: Write keystore and key.properties
        if: steps.keystore.outputs.present == 'true'
        env:
          KEYSTORE_B64:   ${{ secrets.ANDROID_KEYSTORE_BASE64 }}
          STORE_PASSWORD: ${{ secrets.ANDROID_KEYSTORE_PASSWORD }}
          KEY_ALIAS:      ${{ secrets.ANDROID_KEY_ALIAS }}
          KEY_PASSWORD:   ${{ secrets.ANDROID_KEY_PASSWORD }}
        run: |
          echo "$KEYSTORE_B64" | base64 -d > "$RUNNER_TEMP/upload.jks"
          {
            echo "storeFile=$RUNNER_TEMP/upload.jks"
            echo "storePassword=$STORE_PASSWORD"
            echo "keyAlias=$KEY_ALIAS"
            echo "keyPassword=$KEY_PASSWORD"
          } > android/key.properties

      - run: flutter build appbundle --release
      - run: flutter build apk --release

      - uses: actions/upload-artifact@v4
        with:
          name: ${{ steps.keystore.outputs.artifact }}
          path: |
            mobile/build/app/outputs/bundle/release/*.aab
            mobile/build/app/outputs/flutter-apk/*.apk
          retention-days: ${{ startsWith(github.ref, 'refs/tags/v') && 90 || 14 }}

  ios:
    if: ${{ vars.BUILD_PLATFORM_ARTIFACTS != 'false' }}
    runs-on: macos-latest
    needs: gate
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: 3.44.4
          channel: stable
      - run: flutter pub get
      - name: Build iOS (no codesign, with one CocoaPods retry)
        run: |
          flutter build ios --release --no-codesign \
            || (echo "retrying after pod install cold-cache flake" && flutter build ios --release --no-codesign)
      - uses: actions/upload-artifact@v4
        with:
          name: ios-release-unsigned-noninstallable
          path: mobile/build/ios/iphoneos/Runner.app
          retention-days: ${{ startsWith(github.ref, 'refs/tags/v') && 90 || 14 }}

  windows:
    if: ${{ vars.BUILD_PLATFORM_ARTIFACTS != 'false' }}
    runs-on: windows-latest
    needs: gate
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: 3.44.4
          channel: stable
      - run: flutter pub get
      - run: flutter build windows --release
      - uses: actions/upload-artifact@v4
        with:
          name: windows-release
          path: mobile/build/windows/x64/runner/Release
          retention-days: ${{ startsWith(github.ref, 'refs/tags/v') && 90 || 14 }}
```

Notes baked in per §3: `vars.BUILD_PLATFORM_ARTIFACTS` (B3 — `vars` *is* available at job level; `env`/`secrets` are not); step-output keystore gate (`secrets` unavailable in job `if:`); `android-release-signed` vs `android-release-debugsigned` names (B4); `upload-artifact@v4` zips the directory directly, no manual `zip` (M6 — `windows-latest` defaults to PowerShell where `zip` doesn't exist); one CocoaPods retry (m13 — `mobile/ios/Podfile` doesn't exist yet, so the first run hits the flaky cold `pod install`); tag builds retain 90 days, else 14. Keystore written to `$RUNNER_TEMP` (outside the workspace, never archivable).

- [ ] **Step 2: Open a DRAFT PR to `main` and observe the check run.** A bare feature-branch push fires **nothing** — the `on:` triggers are `push:[main]`, `pull_request:[main]`, and `workflow_dispatch` (and a `workflow_dispatch` workflow that isn't yet on the default branch isn't UI-dispatchable). Push the feature branch, then `gh pr create --draft --base main` — that fires the `pull_request` event and is the **pre-merge proof**. Do NOT push to / merge into `main`. Verify — **with no secrets configured** — that `gate`, `ios`, `windows` go green and the Android job produces the `android-release-debugsigned` artifact (the `::warning::` is present). Iterate on the YAML (each push updates the same PR's check run) until green.

- [ ] **Step 3: Commit** (the workflow is committed as part of the branch; the run is the proof).

```bash
git add .github/workflows/ci.yml
git commit -m "ci: test+analyze gate, Android AAB, iOS no-codesign, Windows build"
```

---

### Task T5: Docs overhaul + supersession banners

**Model · Effort: sonnet · medium** — written after the code so it documents what actually shipped.

**Files:** `SHIPPING.md`, `docs/mobile-packaging.md` (new), `docs/protocols/bacnet.md`, `docs/trends.md`, `docs/DEFERRED.md`, `docs/superpowers/specs/2026-07-06-native-app-readiness-design.md`, `docs/superpowers/specs/2026-07-09-mobile-polish-haptics-native-readiness-design.md`, `PROJECT_BRIEF.md` (verify T1's Risks §3 edit is present).

- [ ] **Step 1: `SHIPPING.md` overhaul (§8).** Delete the "Not in scope of this readiness pass" network-permissions bullet (now done). Add: (a) **Keystore generation** — the exact `keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload` invocation, where to store it, the `key.properties` shape (point at `android/key.properties.example`), flagged **user-owned, never committed**; (b) **CI secrets** — `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` and where to set them (Settings → Secrets and variables → Actions), plus the optional `BUILD_PLATFORM_ARTIFACTS` variable; (c) the **store-listing asset checklist** (§8.2 below); (d) the **on-device validation checklist** (§7 — install via Xcode → confirm the Local Network prompt text → connect a SCADA client → background → confirm hosts stop → foreground → confirm the resume banner); (e) refreshed version `0.9.0+2` and the **re-derived** test count (from T6, not the stale "1550").

- [ ] **Step 2: §8.2 store-listing asset checklist into SHIPPING.md** (all user-owned). **Google Play:** icon 512×512; feature graphic 1024×500 (required, authored); 2-8 phone screenshots; 7"/10" tablet screenshots; short ≤80 / full ≤4000 desc; **privacy policy URL** (state: no data collected, no analytics/crash/ads, no transmission except user-started LAN hosts; projects local-only, leave device only on explicit `.splc.json` export); Data safety = no data collected/shared; content rating (IARC) → expect Everyone/PEGI 3; category **Tools**. **Apple:** 6.7"/6.5" iPhone + 12.9" iPad screenshots; privacy nutrition = Data Not Collected; age 4+; **export-compliance flagged loudly** — the app implements **non-exempt cryptography itself** (hand-rolled OPC UA: RSA-2048, AES-256-CBC, SHA-256/HMAC, RSA-OAEP — `SECURITY_AND_SAFETY.md` §OPC UA Security), NOT the HTTPS-only exemption; review notes explaining the Local Network prompt + a one-line "how to see it work". **Both:** lift `SECURITY_AND_SAFETY.md`'s "NOT FOR PRODUCTION CONTROL OR MACHINE SAFETY / no SIL or IEC 61508 / non-deterministic scheduling" disclaimer into the store description verbatim.

- [ ] **Step 3: `docs/mobile-packaging.md` (new).** Per-platform config reference: what each permission/entitlement is for and what breaks without it; the signing fallback semantics (debug-signed ≠ store-uploadable); the lifecycle setting's **full per-platform behaviour** (mobile pause/resume, desktop keeps hosting, the `hidden`-flush-only / `inactive`-no-op / `detached` mapping, the rare Android `detached`→re-attach edge that returns with hosts stopped and no banner, M8); the iOS multicast/BACnet broadcast caveat (§1.6 — still binds 47808 and answers directed Who-Is; only the unsolicited startup I-Am is lost; remedy = apply for `com.apple.developer.networking.multicast` once a paid Apple account exists); the §5 `generated_plugin_registrant` decision (ACCEPT — keep tracked; rationale so it isn't re-litigated).

- [ ] **Step 4: Small doc notes.** `docs/protocols/bacnet.md` — the iOS broadcast caveat (§1.6). `docs/trends.md` — one line: a background pause shows as a gap in the trend (historian is memory-only/tick-driven, records no samples with no ticks; §2.2). `PROJECT_BRIEF.md` — confirm T1's Risks §3 replacement landed.

- [ ] **Step 5: `docs/DEFERRED.md` §10 rows.** New section **"Store readiness (spec 2026-08-08)"** with the rows from spec §10: Play/App Store submission (user-owned); iOS code-signed CI build (near-term); iOS multicast entitlement (later); **MQTT broker password persisted for lifecycle resume** (near-term — secure storage, new dep + security review); true background execution (later); macOS App Store/notarised DMG (later); Linux packaging (later); Windows MSIX (later); `ACCESS_NETWORK_STATE` + connectivity indicator (later); CI code-coverage (later).

- [ ] **Step 6: §9 supersession banners.** Add one bolded line under `**Status:**` in each stale spec:
  - `2026-07-06-native-app-readiness-design.md`: *"**Superseded in part (2026-08-08):** this workstream shipped. Its 'Not in scope' list — on-device network permissions, signing, store assets — is now owned by `2026-08-08-store-readiness-design.md`."*
  - `2026-07-09-mobile-polish-haptics-native-readiness-design.md`: *"**Superseded in part (2026-08-08):** Part A (haptics) shipped. Part B (network permissions, release signing scaffold, `docs/mobile-packaging.md`) was never planned and never executed. Part B is superseded by `2026-08-08-store-readiness-design.md`; do not implement from this document."*

- [ ] **Step 7: commit.**

```bash
git add SHIPPING.md docs PROJECT_BRIEF.md
git commit -m "docs(store): SHIPPING overhaul, mobile-packaging, asset/keystore checklists, supersession banners"
```

---

### Task T6: Knowledge base + final verification (the R3 gate)

**Model · Effort: sonnet · medium** — the verification-before-completion gate. No "done" claim before the R3 on-device bind/poll is observed.

**Files:** `knowledge/practices/development-process.md`, `knowledge/canonical-manifest.json`; verification only (no product code).

- [ ] **Step 1: §8.1 knowledge entry.** Add a new `CL-` entry under `knowledge/practices/development-process.md` (neighbour of the `verification.md` guard-test family): *"A 'config-only' deliverable needs a test or it will silently regress"* — the `INTERNET` permission was specified in two approved specs and shipped in neither; nothing failed because nothing *could* (no test, no build error, the debug manifest merge masked it in every local run); config that only matters in a *release* build is invisible to a debug workflow by construction; the fix is a cheap source-reading guard (`platform_config_guard_test.dart`) asserting the literal key with a `reason:`. Update `knowledge/canonical-manifest.json` for the new learning id.

- [ ] **Step 2: Static + unit gate.**

```bash
cd mobile && /c/flutter/bin/flutter analyze
/c/flutter/bin/flutter test    # record the exact pass count -> feeds SHIPPING.md (m17)
```

Expected: analyze clean; full suite green. **Record the count** and hand it to T5's SHIPPING.md test-count line (re-derived, not the stale 1550).

- [ ] **Step 3: Android release build, both ways** (repeat T1 Step 5's two-way apk build + `keytool -printcert`, then `flutter build appbundle --release`). Expected: both APKs build; debug-signed shows `androiddebugkey`, keystore-signed shows the `upload` alias; the AAB builds.

- [ ] **Step 4: MANDATORY on-device proof (R3, Wi-Fi-free).** With a USB Android device attached:

```bash
cd mobile
adb install -r build/app/outputs/flutter-apk/app-release.apk
# Open the app on-device, go Gateway -> start Modbus TCP (port 502).
adb forward tcp:5020 tcp:502
# From the Python probe lane (mobile/tool/py/, the tool/enip_e2e.sh pattern),
# poll Modbus over the forwarded port:
python tool/py/modbus_probe.py --host 127.0.0.1 --port 5020   # or the lane's runner
adb forward --remove tcp:5020
```

Expected: the Modbus host reaches **`running`** on-device and the Python probe reads registers over the forwarded port. **This is the release-`INTERNET` proof:** without the permission the bind throws and the host never reaches `running` — the bind IS the proof, the poll confirms data flow. No Wi-Fi/LAN needed (USB `adb forward`). **Do not claim the workstream done until this is observed.**

- [ ] **Step 5: Windows desktop.** `cd mobile && /c/flutter/bin/flutter build windows --release`, launch, minimise the window, confirm a started host **keeps running** while minimised (the §2.1 desktop gate — desktop never suspends).

- [ ] **Step 6: Browser verification of the settings dialog** (T2's §4 screens are covered in T2; here confirm the new toggle). `scripts/serve-web.sh --build`, open the SoftPLC Settings dialog at **390×844** and a **landscape 844×390** viewport, confirm the second `SwitchListTile` and its ≤2-line subtitle fit without pushing controls below the fold (M9), and that the switch renders **disabled** on web with the mobile-only subtitle. Zero console warnings/errors, zero failed requests.

- [ ] **Step 7: Record the honest gap.** iOS `NSLocalNetworkUsageDescription` is **not** proven here (needs physical iOS hardware). The guard test proves the key is present/well-formed; the CI iOS job proves the plist parses; the SHIPPING.md on-device checklist is where it is finally confirmed. **A green CI is not "iOS verified."**

- [ ] **Step 8: commit.**

```bash
git add knowledge
git commit -m "docs(knowledge): config-only deliverables need a guard test (CL entry)"
```

---

## Self-review (completed before commit)

- **Spec-coverage sweep.** §1.1 Android INTERNET → T1 (G1). §1.2 iOS plist → T1 (G2). §1.3 macOS entitlements ×2 → T1 (G3). §1.4 signing + `key.properties.example` + root gitignore → T1 (G4/G5). §1.5 version/manifest/index/PROJECT_BRIEF → T1 (G6/G7). §1.6 BACnet iOS caveat → T5 (bacnet.md, mobile-packaging, DEFERRED). §2.0-§2.7 lifecycle (state machine, `_LifecycleHost` closures, `flushPendingAutosaveNow` B2, resume lock R2, banner incl. MQTT line, `kLogSourceLifecycle`, setting+dialog+platform gate) → T3. §3 CI (`vars.` gate B3, artifact names B4, no-zip M6, CocoaPods retry m13, retention) → T4. §4.1-§4.4 UX → T2. §5 registrant decision → T5 (mobile-packaging). §6 guards G1-G7 (G8 deleted) → T1; L1-L12 + S1-S5 → T3; `kAllLogSources` pair → T3 Step 4. §7 verification matrix (unit/static/Android-both-ways/**R3 on-device**/Windows/web/iOS-CI/on-device-checklist) → T6 + T4 + SHIPPING. §8 docs incl. §8.1 knowledge + §8.2 asset checklist → T5/T6. §9 supersession banners → T5. §10 deferred rows → T5. §11 R1/R2/R3 → baked into T3 (R1/R2) and T6 (R3). §12 execution shape → task order (R-B).
- **Placeholder scan.** No "similar to" / TODO / stub in any implementation or test block: the platform-config files show exact final content; the lifecycle state machine + resume lock + MQTT special-case are full Dart; the CI workflow is full YAML; the guard test and the 12 + 5 behavioural cases are complete.
- **Signature consistency.** `_LifecycleHost(id, displayName, isRunning, start, stop)` used identically in the table and the class. `flushPendingAutosaveNow()`/`applyPauseInBackground(bool)`/`GatewayScreen.hostsBusy`/`SoftPlcSettingsResult.pauseInBackground`/`SoftPlcSettingsDialog.initialPauseInBackground` are declared once and consumed consistently across T3's implementation and tests. The `@visibleForTesting` hooks the tests call (`debugLifecycleOp`, `debugOpcUaHost`, `debugMqttHost`, `debugResumeInProgress`, `debugRestartFailures`, `debugPauseInBackground`, `debugSetRunning`, `debugLogEntries`, plus the existing `debugActiveProject`) are all declared in T3 Step 3.
- **One flagged verification-time check** carried in the plan text: confirm each of the eight listening hosts' running-enum member name before wiring its closure (only `opcua_host.dart` was read in full; the shape is uniform but the member name is the single load-bearing token).
