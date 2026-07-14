# UI Repaint Decoupling + Gateway Panel Perf — Design

**Date:** 2026-07-14
**Status:** Approved by user (chat, 2026-07-14).
**Builds on:** the scan loop (`workspace_shell.dart` `_executeScan`), the gateway/Outbound-Protocols screen (`gateway_screen.dart`), the live-value surfaces (`tag_inspector_dock.dart`, `memory_manager_screen.dart`, the HMI dashboard, the LD/FBD/SFC editor run overlays), the `NotifyThrottle` (`services/notify_throttle.dart`), and the app's SharedPreferences prefs.

## Problem

With ~100 continuously-changing tags, the app becomes laggy — but the diagnosis matters. An A/B test disproved the first guess: **OPC UA server active + 100 tags + 500 ms scan is smooth; the same setup becomes laggy the moment the MQTT panel is open and transmitting.** Two concrete causes, both about excessive widget rebuilds, not compute:

1. **Gateway panel over-rebuild (the reported bug).** The gateway screen's *entire* body — all four protocol cards, including the MQTT card's 100+ map rows — is wrapped in one `ListenableBuilder` merged on all four hosts (`gateway_screen.dart:815`). Each tab is a `SingleChildScrollView`→`Column` of rows built **eagerly** (`_groupedMapRows` returns a `List<Widget>`, from the folder-grouping work — no virtualization). So every MQTT publish notification (the MQTT host is a `ChangeNotifier`, throttled to ~4 Hz) rebuilds all 100+ non-virtualized config rows. OPC UA's *server* host is passive (notifies rarely), so the same panel stays static — hence smooth with OPC UA, laggy with MQTT.

2. **Whole-shell repaint on every scan (latent, general).** `_executeScan` calls `setState` on the whole `WorkspaceShell` every tick (`workspace_shell.dart:404`), rebuilding the entire tree — nav, center screen, live-value rows. It's tolerable when the visible screen is light, but it needlessly couples every UI surface to the scan rate.

## Goal

- **Fix the reported lag** with a targeted gateway change (scope the host listener; virtualize the map lists).
- **Decouple UI repaint from the scan** generally: introduce a throttled `LiveTick` so only on-screen live-value widgets repaint (≤ a configurable rate, default 10 Hz), and stop the per-scan whole-shell `setState`.
- Add a **global SoftPLC Settings** home for the configurable refresh rate.
- Give the **Tag Inspector collapsible folders** (grouped by `PlcTag.folder`).

## Decisions (locked with the user)

- Both the targeted gateway fix AND the full `LiveTick` workstream, as one effort.
- `LiveTick` exposed via an **`InheritedNotifier`** (`LiveTickScope.of(context)`) — no constructor threading.
- Repaint cap **default 10 Hz**, **configurable** and stored as a **global app preference** (SharedPreferences), surfaced in a new lightweight **SoftPLC Settings** dialog.
- Tag Inspector rows grouped into **collapsible folder sections** (root first), matching the Memory Manager / protocol-map grouping.

## Architecture

### Part 1 — Targeted gateway fix (`gateway_screen.dart`)

- **Scope the host `ListenableBuilder`.** The merged-host `ListenableBuilder` wrapping the whole `TabBarView` is replaced: only the small **status/publish-count widgets** inside each card (the "connected / running / publish count" chips) listen to their host; the static map-config rows are outside any host listener. A host notification then repaints only the chips, never the 100+ rows.
- **Virtualize the map lists.** `_groupedMapRows` (currently a `List<Widget>` placed in a `Column`) becomes a lazy list: a `ListView.builder`/sliver whose item list is a flattened `[folder-header, row, row, …, folder-header, …]` sequence (folder grouping preserved), so only on-screen items build. Applied to all four protocol map editors (OPC UA / Modbus / DNP3 / MQTT). The card's outer `SingleChildScrollView` gives way to a bounded, scrollable virtualized list for the map section (the rest of the card stays as-is).

This alone removes the reported lag: an MQTT publish no longer rebuilds the map, and even a full rebuild only builds visible rows.

### Part 2 — `LiveTick` decoupling

- **`LiveTick`** — a `ChangeNotifier` owned by the shell, exposed via `LiveTickScope` (an `InheritedNotifier<LiveTick>`) at the top of the tree. It carries no data; it is a "repaint now" pulse. Its firing is **coalesced through a `NotifyThrottle`** to the configured cap (default 100 ms / 10 Hz) regardless of scan rate.
- **Scan loop** — `_executeScan` still runs `runScanTick` (model update) + writes System status, but **stops calling `setState` on the whole shell**. Instead it calls `liveTick.request()` (throttled). Fault transitions keep an immediate targeted `setState` (rare) so the fault banner appears at once.
- **Live-value widgets** — every widget that displays a live tag value wraps just its **value leaf** in `ListenableBuilder(listenable: LiveTickScope.of(context), …)` and re-reads via `readPath`/`tag.value`. A tick repaints only those leaves.

**Safe rollout ordering (critical):** add `LiveTick` and tick it each scan *while the whole-shell `setState` still runs* (redundant, zero behavior change); convert every live surface to also listen to `LiveTick`; **only then** remove the per-scan whole-shell `setState`. At removal time every surface already repaints from the tick, so nothing can freeze.

**Surfaces converted:** Tag Inspector dock value cells; Memory Manager "Live Value" column; HMI component values; LD/FBD/SFC editor run-state overlays (energized elements / live block values); the toolbar scan counters (`ScanCount`/`ScanTimeMs`/uptime → a small `ListenableBuilder` reading the `System` tag). The gateway map rows are *config* (no live value) and are handled by Part 1 — they do not need the tick.

### Part 3 — SoftPLC Settings + configurable refresh rate

- A new **SoftPLC Settings** dialog (reachable from the app-bar overflow menu) — a lightweight home for global, device-level preferences. First (and only) field this workstream adds: **UI refresh rate (Hz)** (default 10, sane clamp e.g. 1–30 Hz).
- Stored as a **global SharedPreferences** value (not per-project). On load and on change, the shell sets the `LiveTick` throttle window to `1000 / hz` ms and re-arms.

### Part 4 — Tag Inspector collapsible folders

- The Tag Inspector dock groups its rows by `PlcTag.folder` (root `''` first, then folders alphabetically) into **collapsible sections** (reuse the `groupEntriesByFolder`/folder-subheader pattern). Live values inside each section still update via the `LiveTick`. Collapse state is transient UI state (per dock instance).

## Testing

**Part 1:** a widget test that pumps the gateway MQTT tab with a 100+ entry map and asserts (a) a host `notifyListeners()` does NOT rebuild the map rows (a rebuild counter on a sentinel row stays flat) — only the status chip updates; (b) the map list is virtualized (offscreen rows are not built — assert via `find` that a far-down row isn't in the tree until scrolled). No overflow at 320/360/1400.

**Part 2:** `LiveTick`/throttle unit tests (coalesce to the cap; dispose-safe — reuse/extend `NotifyThrottle` tests); a widget test proving a live-value cell repaints on a `LiveTick` pulse **without** the `WorkspaceShell` rebuilding (a rebuild counter on a shell-level sentinel stays flat while the value cell updates); a regression test per converted surface that its live value still advances while running; a test that after the shell's per-scan `setState` is removed, running the scan still updates a visible value (via the tick).

**Part 3:** the refresh-rate pref round-trips through SharedPreferences (default 10 when absent), and changing it re-tunes the `LiveTick` throttle window; the Settings dialog renders without overflow.

**Part 4:** Tag Inspector folder grouping (root-first, collapse/expand toggles visibility) with live values still updating in an expanded section.

**Regression:** full `flutter test`; `flutter analyze` zero; `flutter build web --release` compiles; existing gateway/inspector/HMI/editor tests pass; manual smoke — 100 ramps + MQTT panel open + transmitting is smooth; values on every surface update while running.

## Global constraints

- No vendor branding. Dark theme; zero `flutter analyze` warnings; `withValues(alpha:)` not `withOpacity`; braces; no RenderFlex overflow at 320/360/1400.
- `mobile/lib/models/**` + `mobile/lib/protocols/**` stay pure Dart; `LiveTick`/throttle use only `dart:async`/`flutter foundation` (`ChangeNotifier`), no `dart:io`.
- Behavior-preserving: values on every live surface must still update while running (the safe-ordering rule guarantees no freeze); the fault banner still appears immediately on a watchdog trip; forcing/read semantics unchanged (`readPath`).
- The refresh-rate is a global device pref (SharedPreferences), not a persisted project field — the WS6 round-trip is unaffected.
- Reuse the existing `NotifyThrottle` for the `LiveTick` coalescing and the existing `groupEntriesByFolder` for the Tag Inspector folders (DRY).

## Phasing (one spec → phased plan)

- **Phase A — Gateway panel fix.** Scope the host `ListenableBuilder` to status widgets; virtualize the four map lists (folder grouping preserved). Directly fixes the reported lag. Widget tests.
- **Phase B — LiveTick core (no behavior change).** `LiveTick` + `LiveTickScope` `InheritedNotifier`; shell owns it and calls `liveTick.request()` (throttled) each scan, *alongside* the existing whole-shell `setState`. Unit tests.
- **Phase C — Convert live surfaces to LiveTick.** Tag Inspector dock, Memory Manager, HMI dashboard, editor run overlays, toolbar counters each wrap their value leaves in a `LiveTick` `ListenableBuilder` (still redundant with the shell `setState`). Per-surface tests.
- **Phase D — Flip the shell.** Remove the per-scan whole-shell `setState` (keep the immediate fault-transition `setState`); the scan now repaints only via the tick. Integration test (value updates without shell rebuild).
- **Phase E — SoftPLC Settings + refresh rate.** Settings dialog + global pref; wire to the throttle window. Tests.
- **Phase F — Tag Inspector collapsible folders.** Group + collapse, live values intact. Tests.
- **Phase G — Validation, docs, final review.** Full gates; manual smoke of the MQTT-panel scenario; docs; whole-branch review; merge.
