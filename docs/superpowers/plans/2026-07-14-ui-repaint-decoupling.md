# UI Repaint Decoupling + Gateway Panel Perf Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the MQTT-panel lag (scope the gateway host listener + virtualize the map lists) and decouple UI repaint from the scan (a throttled `LiveTick` so only on-screen live-value widgets repaint), plus a configurable refresh-rate setting and collapsible Tag-Inspector folders.

**Architecture:** A `LiveTick` (`ChangeNotifier`, exposed via an `InheritedNotifier`) is pulsed by the scan loop through the existing `NotifyThrottle` at a configurable cap (default 10 Hz). Live-value widgets repaint from the tick instead of a per-scan whole-shell `setState`. The gateway panel stops rebuilding its 100+ config rows on every publish notify and virtualizes them.

**Tech Stack:** Flutter (`ChangeNotifier`/`InheritedNotifier`/`ListenableBuilder`/`ListView.builder`), `dart:async`, SharedPreferences, existing `NotifyThrottle` + `groupEntriesByFolder`, `flutter_test`.

## Global Constraints

- No vendor branding. Dark theme; zero `flutter analyze` warnings; `withValues(alpha:)` not `withOpacity`; braces on all control flow; prefer `const`. No RenderFlex overflow at 320/360/1400.
- `LiveTick`/throttle use only `dart:async` + `package:flutter/foundation` (`ChangeNotifier`) — no `dart:io`. `mobile/lib/models/**` + `mobile/lib/protocols/**` stay pure Dart.
- **Behavior-preserving:** every live surface must keep updating while running. The safe-ordering rule is binding — LiveTick is added and all surfaces converted to it BEFORE the per-scan whole-shell `setState` is removed, so nothing freezes mid-refactor. The fault banner still appears immediately on a watchdog trip.
- Refresh-rate is a GLOBAL device pref (SharedPreferences), not a persisted project field — the WS6 round-trip is unaffected.
- Reuse the existing `NotifyThrottle` (`services/notify_throttle.dart`: `NotifyThrottle(void Function() onFire, {Duration window}); request(); immediate(); dispose();`) and `groupEntriesByFolder` (`gateway_screen.dart`).

**Commands** (from `mobile/`): `flutter test test/<path>_test.dart`; full `flutter test`; `flutter analyze` (expect **No issues found!**).

---

## Phase A — Gateway panel fix (the reported bug)

### Task 1: Scope the host listener + virtualize the map lists

**Files:**
- Modify: `mobile/lib/screens/gateway_screen.dart`
- Test: `mobile/test/widgets/gateway_panel_perf_test.dart` (create)

**Interfaces:**
- Consumes: the four hosts (`widget.host`/`modbusHost`/`mqttHost`/`dnpHost`), `_groupedMapRows`, `groupEntriesByFolder`, the per-protocol `rowBuilder`s (`_nodeRow`/`_modbusRow`/`_dnpRow`/`_mqttRow`) and status widgets.
- Produces: a gateway body where a host `notifyListeners()` repaints ONLY the status/connection/publish-count widgets, not the map rows; and each protocol map list renders lazily (only on-screen rows built).

- [ ] **Step 1: Write the failing test**

Create `mobile/test/widgets/gateway_panel_perf_test.dart`. Pump the gateway screen (read the existing gateway widget test for the harness — how it constructs `GatewayScreen` with the four hosts + a project). Build a project with a large MQTT map (e.g. 60 entries). Assert:
1. Calling `mqttHost` `notifyListeners()` (or the test's `debug` trigger) does NOT increment a rebuild counter attached to a map row — only the status chip rebuilds. (Instrument a row with a `_RebuildCounter` sentinel widget, or count `_mqttRow` invocations via a wrapper.)
2. The map list is virtualized: a far-down row's tag text is NOT in the tree until scrolled (`find.text('<row 55 tag>')` → `findsNothing` before scroll, `findsOneWidget` after scrolling it into view).

> Read the existing gateway test(s) (`grep -rl "GatewayScreen" mobile/test`) to reuse the pump harness (hosts, project, `MaterialApp`). Keep these two assertions.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/widgets/gateway_panel_perf_test.dart`
Expected: FAIL — the whole body rebuilds on host notify; the eager `Column` builds all rows.

- [ ] **Step 3: Implement**

In `gateway_screen.dart`:
1. **Remove the body-wide merged-host `ListenableBuilder`** (line ~815) so the `TabBarView`/cards are NOT rebuilt by host notifications. Instead, wrap ONLY the status/connection/publish-count widgets inside each card in a per-host `ListenableBuilder(listenable: <thatHost>, builder: …)`. (Find each card's status display — e.g. the MQTT status chip using `_mqttStatusLabel`/`publishCount` — and wrap just that subtree.)
2. **Virtualize each map list.** Replace `_groupedMapRows` (which returns a `List<Widget>` placed in a `Column`) with a lazy builder. Add a helper that flattens the grouped map into a typed item list `[FolderHeaderItem(folder,count), RowItem(entry), …]` (root bucket first, no header; then each folder with a header item), and render it with a bounded `ListView.builder` (e.g. inside a `SizedBox`/`Flexible` with a sensible max height, or a sliver) whose `itemBuilder` emits `_folderSubheader(...)` for a header item and the protocol's `rowBuilder(entry)` for a row item. Preserve folder grouping + the existing row editing controls. Apply to all four map editors (OPC UA `_nodeRow`, Modbus `_modbusRow`, DNP `_dnpRow`, MQTT `_mqttRow`).
3. Keep the card's other controls (host/port fields, buttons, auto-generate) as-is; only the map-list section becomes virtualized, and only the status widgets listen to the host.

Ensure no RenderFlex/unbounded-height error from putting a `ListView` inside a `Column`/`SingleChildScrollView` — give the map list a bounded height (`SizedBox(height: …)` or `Flexible`/`Expanded` within a `Column` that itself has bounded constraints), and verify at 320/360/1400.

- [ ] **Step 4: Run tests**

Run: `flutter test test/widgets/gateway_panel_perf_test.dart` → PASS.
Run: `flutter test test/` (existing gateway tests) + `flutter analyze` → green / no issues. Verify the 320/360/1400 responsive suite still passes (no overflow from the virtualized list).

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/screens/gateway_screen.dart mobile/test/widgets/gateway_panel_perf_test.dart
git commit -m "perf(gateway): scope host listeners to status widgets + virtualize map lists"
```

---

## Phase B — LiveTick core (no behavior change yet)

### Task 2: `LiveTick` + `LiveTickScope` + shell wiring (redundant with setState)

**Files:**
- Create: `mobile/lib/widgets/live_tick.dart`
- Modify: `mobile/lib/screens/workspace_shell.dart`
- Test: `mobile/test/widgets/live_tick_test.dart` (create)

**Interfaces:**
- Consumes: `NotifyThrottle`.
- Produces:
  - `class LiveTick extends ChangeNotifier { void pulse(); }` — `pulse()` calls `notifyListeners()`.
  - `class LiveTickScope extends InheritedNotifier<LiveTick> { static LiveTick of(BuildContext) ; }`.
  - Shell owns a `LiveTick _liveTick` + a `NotifyThrottle _repaintThrottle` (window = `Duration(milliseconds: 1000 ~/ _refreshHz)`, default 10 Hz → 100 ms) whose `onFire` calls `_liveTick.pulse()`. `_executeScan` calls `_repaintThrottle.request()` **in addition to** the existing whole-shell `setState` (no behavior change this task). The shell's `build()` wraps its tree in `LiveTickScope(notifier: _liveTick, child: …)`. `dispose()` disposes both.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/widgets/live_tick_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/widgets/live_tick.dart';

void main() {
  testWidgets('LiveTickScope.of exposes the notifier; a pulse rebuilds a listening leaf only', (tester) async {
    final tick = LiveTick();
    var leafBuilds = 0;
    var rootBuilds = 0;
    await tester.pumpWidget(LiveTickScope(
      notifier: tick,
      child: Builder(builder: (context) {
        rootBuilds++;
        return MaterialApp(
          home: Center(
            child: ListenableBuilder(
              listenable: LiveTickScope.of(context),
              builder: (context, _) {
                leafBuilds++;
                return const Text('v');
              },
            ),
          ),
        );
      }),
    ));
    final rootAfterFirst = rootBuilds;
    final leafAfterFirst = leafBuilds;
    tick.pulse();
    await tester.pump();
    expect(leafBuilds, leafAfterFirst + 1); // leaf repainted
    expect(rootBuilds, rootAfterFirst);     // root did NOT rebuild
    tick.dispose();
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/widgets/live_tick_test.dart`
Expected: FAIL — `live_tick.dart` missing.

- [ ] **Step 3: Implement `live_tick.dart`**

```dart
import 'package:flutter/widgets.dart';

/// A dataless "repaint now" pulse. Widgets that display live tag values listen
/// to it (via [LiveTickScope]) and re-read their value on each pulse, so the
/// scan loop can refresh only on-screen values without rebuilding the whole
/// widget tree. Pulsing is expected to be throttled by the owner (the shell
/// coalesces scan ticks through a NotifyThrottle to a configurable cap).
class LiveTick extends ChangeNotifier {
  void pulse() {
    notifyListeners();
  }
}

/// Exposes a [LiveTick] to the subtree. A descendant obtains it with
/// `LiveTickScope.of(context)` and wraps its value leaf in a
/// `ListenableBuilder(listenable: LiveTickScope.of(context), …)`.
class LiveTickScope extends InheritedNotifier<LiveTick> {
  const LiveTickScope({super.key, required LiveTick notifier, required super.child})
      : super(notifier: notifier);

  static LiveTick of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<LiveTickScope>();
    assert(scope?.notifier != null, 'No LiveTickScope found in context');
    return scope!.notifier!;
  }
}
```

- [ ] **Step 4: Wire into the shell (no behavior change)**

In `workspace_shell.dart`:
- Add `final LiveTick _liveTick = LiveTick();` and `int _refreshHz = 10;` and `late NotifyThrottle _repaintThrottle;`. In `initState`, `_repaintThrottle = NotifyThrottle(_liveTick.pulse, window: Duration(milliseconds: (1000 / _refreshHz).round()));`.
- In `_executeScan`, after the existing `setState(...)`, add `_repaintThrottle.request();` (redundant this task — the setState still drives the UI; the tick just also fires).
- In `build()`, wrap the returned tree in `LiveTickScope(notifier: _liveTick, child: <existing tree>)`.
- In `dispose()`, `_repaintThrottle.dispose(); _liveTick.dispose();`.

- [ ] **Step 5: Run tests + commit**

Run: `flutter test test/widgets/live_tick_test.dart` → PASS. Run `flutter test` + `flutter analyze` → green (no behavior change; the shell still setStates each scan).

```bash
git add mobile/lib/widgets/live_tick.dart mobile/lib/screens/workspace_shell.dart mobile/test/widgets/live_tick_test.dart
git commit -m "feat(perf): LiveTick + LiveTickScope; shell pulses it each scan (throttled)"
```

---

## Phase C — Convert live surfaces to LiveTick

> Each of these tasks wraps the surface's VALUE leaves in `ListenableBuilder(listenable: LiveTickScope.of(context), …)`. The shell still `setState`s each scan (removed in Phase D), so these are safe/redundant now and prevent any freeze when the setState is later removed.

### Task 3: Tag Inspector dock → LiveTick

**Files:**
- Modify: `mobile/lib/widgets/tag_inspector_dock.dart`
- Test: `mobile/test/widgets/tag_inspector_livetick_test.dart` (create)

**Interfaces:**
- Consumes: `LiveTickScope.of(context)`.
- Produces: each live-value cell in the dock repaints on a `LiveTick` pulse (re-reads via `readPath`).

- [ ] **Step 1: Write the failing test**

Create `mobile/test/widgets/tag_inspector_livetick_test.dart`: pump the `TagInspectorDock` inside a `LiveTickScope` with a project whose tag value changes between pulses (mutate `tag.value` directly, then `tick.pulse()`), and assert the displayed value updates after `pulse()`+`pump()` WITHOUT rebuilding a sentinel ancestor. Read the dock's constructor (project + callbacks) from `tag_inspector_dock.dart`.

- [ ] **Step 2: Run to fail** → the value cell doesn't update on a bare pulse (it currently updates only via ancestor setState).

- [ ] **Step 3: Implement**

Wrap each row's live-value `Text`/widget in `ListenableBuilder(listenable: LiveTickScope.of(context), builder: (_, __) => <value widget that re-reads readPath>)`. Keep the row structure/labels static (outside the builder). Confirm the dock has access to a `BuildContext` under the shell's `LiveTickScope` (it's built inside the shell tree).

- [ ] **Step 4: Run tests** → PASS; `flutter analyze` clean.

- [ ] **Step 5: Commit** `perf(inspector): live-value cells repaint via LiveTick`.

---

### Task 4: Memory Manager → LiveTick

**Files:**
- Modify: `mobile/lib/screens/memory_manager_screen.dart`
- Test: `mobile/test/widgets/memory_manager_livetick_test.dart` (create)

Same pattern: wrap the "Live Value" column cell (and any tag-value display) in a `LiveTickScope` `ListenableBuilder` that re-reads the value; keep row structure static. Test: a value cell updates on `pulse()` without an ancestor rebuild. Commit `perf(memory): live-value cells repaint via LiveTick`.

---

### Task 5: HMI dashboard + editor run-overlays + toolbar counters → LiveTick

**Files:**
- Modify: the HMI dashboard screen (find: `grep -rl "HmiDashboard" mobile/lib`), the LD/FBD/SFC editor run-state rendering (energized element / live block value), and the shell toolbar scan counters (`ScanCount`/`ScanTimeMs`/uptime display).
- Test: `mobile/test/widgets/livetick_surfaces_test.dart` (create)

For each: wrap the live-value/live-state leaf in a `LiveTickScope` `ListenableBuilder`. The toolbar counters read the `System` tag (`readPath(project, 'System.ScanCount')` etc.) inside the builder. Test at least one representative surface (HMI component value + toolbar counter) updating on `pulse()`. This is the broadest task — the implementer enumerates each live-state paint site in the editors' run overlays. Commit `perf(hmi,editors,toolbar): live surfaces repaint via LiveTick`.

> If the editor run-overlay conversion is large/risky, the implementer may report DONE_WITH_CONCERNS listing any run-overlay site not yet converted — those MUST be converted before Phase D removes the shell setState, else they freeze. The Phase D task re-checks this.

---

## Phase D — Flip the shell

### Task 6: Remove the per-scan whole-shell setState

**Files:**
- Modify: `mobile/lib/screens/workspace_shell.dart` (`_executeScan`)
- Test: `mobile/test/widgets/scan_no_shell_rebuild_test.dart` (create)

**Interfaces:**
- Consumes: the `LiveTick` (Phase B) + all converted surfaces (Phase C).
- Produces: `_executeScan` no longer calls `setState` on the whole shell each tick; it runs `runScanTick` + `updateSystemStatus` (plain model writes, no setState) + `_repaintThrottle.request()`. Fault transitions and `consumeAlarmReset`-driven clears keep a targeted `setState` (rare).

- [ ] **Step 1: Write the failing test**

Create `mobile/test/widgets/scan_no_shell_rebuild_test.dart`: pump the shell running a scan that changes a visible value; assert (a) the visible value updates over time (via the tick), and (b) a rebuild counter on a shell-level sentinel widget does NOT increment per scan (only on structural changes). Use a `debug` hook if needed to count shell builds.

- [ ] **Step 2: Run to fail** → currently the shell rebuilds every scan.

- [ ] **Step 3: Implement**

Rewrite `_executeScan`: keep the timing/stat computation and `runScanTick`, but move the model writes OUT of `setState` — call `updateSystemStatus(...)` and `consumeAlarmReset(...)` directly (they mutate the model). Only wrap in `setState` the RARE branches: a fault transition (`result.faulted` first becoming true) and an `AlarmReset`-driven `_clearFault()`. Always call `_repaintThrottle.request()` at the end. The scan-time stats (`_lastScanMs` etc.) are read by the toolbar counter via the `System` tag now, so they don't need `setState`.

- [ ] **Step 4: Run tests** → the new test passes; run the FULL suite — every live-surface test from Phase C still passes (proving nothing froze); `flutter analyze` clean.

- [ ] **Step 5: Commit** `perf(scan): stop per-scan whole-shell setState — repaint via LiveTick only`.

---

## Phase E — SoftPLC Settings + configurable refresh rate

### Task 7: Settings dialog + global refresh-rate pref

**Files:**
- Create: `mobile/lib/screens/softplc_settings_dialog.dart` (or a small dialog in the shell)
- Modify: `mobile/lib/screens/workspace_shell.dart` (load pref, overflow-menu entry, apply to throttle)
- Test: `mobile/test/widgets/refresh_rate_pref_test.dart` (create)

**Interfaces:**
- Produces: a global SharedPreferences key `ui_refresh_hz` (default 10, clamp 1–30); a SoftPLC Settings dialog with a refresh-rate field; the shell loads it at boot and re-tunes `_repaintThrottle`'s window (`1000 ~/ hz` ms) on change.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/widgets/refresh_rate_pref_test.dart` (use `SharedPreferences.setMockInitialValues`): assert the shell reads `ui_refresh_hz` (defaults to 10 when absent), and a helper `applyRefreshHz(int)` clamps to 1–30 and sets the throttle window to `Duration(milliseconds: 1000 ~/ hz)`. Extract a small pure/`@visibleForTesting` helper for the clamp+window math so it's testable without pumping the dialog.

- [ ] **Step 2: Run to fail** → helper/pref not present.

- [ ] **Step 3: Implement**

- Shell: at boot (after prefs load), read `ui_refresh_hz` (default 10), clamp 1–30, set `_refreshHz` and rebuild `_repaintThrottle` with the matching window.
- Add a **Settings** entry to the app-bar overflow menu (find the `PopupMenuButton`/overflow in `_buildAppBarActions`) that opens the SoftPLC Settings dialog.
- Dialog: a numeric field "UI refresh rate (Hz)" (1–30), Save persists to prefs and calls the shell to re-tune the throttle. Layout-guarded (vertical, no overflow).

- [ ] **Step 4: Run tests** → PASS; full suite + analyze green.

- [ ] **Step 5: Commit** `feat(settings): SoftPLC Settings dialog + configurable UI refresh rate (default 10Hz)`.

---

## Phase F — Tag Inspector collapsible folders

### Task 8: Group Tag Inspector rows by folder (collapsible)

**Files:**
- Modify: `mobile/lib/widgets/tag_inspector_dock.dart`
- Test: `mobile/test/widgets/tag_inspector_folders_test.dart` (create)

**Interfaces:**
- Consumes: `PlcTag.folder`; the folder-grouping pattern (`groupEntriesByFolder` or a local group-by-folder over the dock's tags).
- Produces: the dock lists tags grouped by folder (root `''` first, then folders alphabetically) as collapsible sections; live values inside still update via the LiveTick.

- [ ] **Step 1: Write the failing test**

Create `mobile/test/widgets/tag_inspector_folders_test.dart`: a project with root + foldered tags; assert the dock shows a collapsible folder header for each non-root folder (root tags first, no header), tapping it toggles its rows' visibility, and a live value in an expanded folder still updates on a `LiveTick` pulse.

- [ ] **Step 2: Run to fail** → no folder grouping in the dock.

- [ ] **Step 3: Implement**

Group the dock's tags by `folder` (root first, then alphabetical); render each non-root group under a collapsible header (reuse the folder-subheader style; track expanded state in the dock's `State`). Keep the Phase-3 LiveTick value cells inside. Guard layout at 320/360.

- [ ] **Step 4: Run tests** → PASS; full suite + analyze green; no overflow at 320/360/1400.

- [ ] **Step 5: Commit** `feat(inspector): collapsible folder sections grouped by tag folder`.

---

## Phase G — Validation, docs, final review

### Task 9: Whole-workstream validation + docs

- [ ] **Step 1: Full green gate** — from `mobile/`: `flutter test` (report count, all green); `flutter analyze` (**No issues found!**); `flutter build web --release` (compiles).
- [ ] **Step 2: Freeze check** — confirm EVERY live surface (inspector, memory manager, HMI, editor run overlays, toolbar counters) still updates while running after the Phase-D setState removal (the Phase C/D tests cover this; list them).
- [ ] **Step 3: Manual smoke** — 100 ramps + OPC UA + MQTT panel open + transmitting is smooth; values update on every surface; changing the refresh rate visibly re-paces updates; no overflow at 320/360/1400.
- [ ] **Step 4: Docs + ROADMAP** — a short `docs/` note on the UI-repaint architecture (LiveTick, throttled repaint, gateway virtualization) + the refresh-rate setting; ROADMAP entry. No vendor branding.
- [ ] **Step 5: Final whole-branch review** — dispatch the final code review (opus); fix Critical/Important; finish the branch (merge `--no-ff` + push) per finishing-a-development-branch.

---

## Self-Review notes (author)

- **Spec coverage:** gateway host-scope + virtualization (T1); LiveTick core (T2); convert inspector/memory/HMI/editors/toolbar (T3–T5); remove shell setState (T6); settings + refresh rate (T7); tag-inspector folders (T8); validation/docs/review (T9). All spec parts mapped.
- **Type consistency:** `LiveTick`/`LiveTickScope.of` defined in T2, consumed by T3–T8; `NotifyThrottle` reused from the prior workstream; `_repaintThrottle`/`_refreshHz` defined in T2 and re-tuned in T7.
- **Ordering (SAFETY-CRITICAL):** A(1) → B(2) → C(3,4,5) → D(6) → E(7) → F(8) → G(9). The per-scan whole-shell `setState` is removed (T6) ONLY after every live surface is converted to LiveTick (T3–T5); T6's test + T9's freeze check verify nothing froze. T5 explicitly flags any unconverted run-overlay site as a blocker for T6.
