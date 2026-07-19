# In-App Log / Diagnostics Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a source-tagged, filterable in-app log so failures that are currently invisible — like a protocol host silently dropping every request while its card reads "Running" — become diagnosable from the app alone.

**Architecture:** A pure ring-buffer + filter core (`models/app_log.dart`), a level-gating logger service holding it (`services/app_logger.dart`), instrumentation across the six protocol hosts and the other subsystems, and a Logs screen that repaints through the existing throttled `LiveTick` rather than per entry.

**Tech Stack:** Flutter/Dart. `flutter test`, `flutter analyze`, `flutter build web --release`.

## Global Constraints

- Pure Dart (no Flutter, no `dart:io`) in `mobile/lib/models/app_log.dart`.
- **Deterministic core:** the log model NEVER reads a clock. Timestamps are passed in, exactly as `TagHistorian.sample(..., int nowMs)` does (`mobile/lib/services/tag_historian.dart:40`), so eviction and filtering are unit-testable without faking time.
- **Additive:** the log is runtime-only. It appears in **no** project JSON; no existing serialized form changes; default-projects round-trip and scan-equivalence stay green.
- **The logger must never throw and never break a caller.** A logging failure must not take down a protocol host or the scan. Log calls are best-effort.
- Dark theme; `withValues(alpha:)` NEVER `withOpacity`; braces on all control flow; zero `flutter analyze` warnings; no RenderFlex overflow at 320/360/1400.
- No competitor-tooling branding; no reverse-engineering wording.

> ### THE TWO CONTRACTS THAT MAKE OR BREAK THIS FEATURE
>
> **1. Level check BEFORE message construction.** Protocol hosts call the logger **per frame**. A disabled TRACE must not cost a string interpolation. The trap: `log(src, level, 'raw=${hex(bytes)}')` formats the string **at the call site, before the function runs**, so it pays full cost even when logging is off. The frame-detail API therefore takes a **lazy** `String Function()`, and Task 2 has a test asserting the builder is **never invoked** when the level is disabled. This is a tested contract, not a convention — it regresses the instant someone adds a convenient eager overload.
>
> **2. NEVER `notifyListeners()` per entry.** The Logs view repaints on the throttled `LiveTick` pulse. A per-entry notify would thrash the widget tree harder than the per-scan `setState` that `LiveTick` was introduced to eliminate. See `mobile/lib/widgets/live_tick.dart` — its doc comment explains why `LiveTickScope.of()` is a deliberate **non-dependency** lookup so only the value leaf repaints.

> ### BINDING SECURITY RULE
> **No credential may ever reach a log call.** MQTT passwords and OPC UA user tokens pass through code that becomes log-adjacent in Task 3. Authentication paths log **outcomes** ("username auth rejected"), never the secret, and never a whole request/response object that might contain one. Task 3 carries an explicit test for this.

## Key facts (verified — do not re-derive)

- **There is no logging infrastructure in the app.** No logger, no `debugPrint`, no `dart:developer`. A grep across `mobile/lib` returns nothing. Clean slate.
- Each host exposes a single `String? lastError` with no history: `dnp3_host.dart:246`, `enip_host.dart:432`, `modbus_host.dart:216`, `mqtt_host.dart:291`, plus the OPC UA and S7 hosts.
- **`LiveTick`** (`mobile/lib/widgets/live_tick.dart`): `class LiveTick extends ChangeNotifier { void pulse(); }` and `LiveTickScope extends InheritedNotifier<LiveTick>` with `static LiveTick of(BuildContext)`. Consumers wrap their leaf in `ListenableBuilder(listenable: LiveTickScope.of(context), …)`.
- **Ring-buffer precedent**: `mobile/lib/services/tag_historian.dart` — `sample(..., int nowMs)` takes time as a parameter; `clear()` at `:83`.
- **Shell** (`mobile/lib/screens/workspace_shell.dart`):
  - Hosts owned as fields at `:109-114` (`_opcuaHost`, `_modbusHost`, `_mqttHost`, `_dnpHost`, `_enipHost`, `_s7Host`).
  - `final LiveTick _liveTick = LiveTick();` at `:122`; test hook `debugLiveTick` at `:402`; `LiveTickScope` provided at `:1442`.
  - Navigation is **string dispatch on `_activeViewId`**. Left-dock entry pattern at `:2173-2185` (a `Container` whose colour keys off `_activeViewId == 'GATEWAY'`, a `ListTile` with `leading: Icon(...)`, and `onTap: () => _selectView(context, 'GATEWAY')`).
  - Screen dispatch in `_buildCenterWorkspace()` — the `GATEWAY` branch is at `:2777-2788`, ending in a fallback `Center(child: Text('Select an HMI, Memory, or Program from the Left Dock'))`.
  - **`:841` carries a comment "MEMORY / SIMIO:rules / GATEWAY are always valid views."** — there is a view-validity check there that a new `'LOGS'` id must be added to, or the view will be silently reset on project switch.
- Baseline before this branch: `flutter test` **1803 passing / 0 failing**; `flutter analyze` zero issues.

---

### Task 1: Pure log core

**Files:**
- Create: `mobile/lib/models/app_log.dart`
- Test: `mobile/test/app_log_test.dart`

**Interfaces:**
- Produces: `enum LogLevel { trace, debug, info, warn, error }`; `class LogEntry { final int seq; final int tMs; final LogLevel level; final String source; final String message; final String? detail; }`; `class LogRingBuffer { LogRingBuffer({int capacity = kLogDefaultCapacity}); void add(LogEntry e); List<LogEntry> get entries; void clear(); }`; `List<LogEntry> filterLogEntries(List<LogEntry> entries, {LogLevel minLevel, Set<String>? sources, String textFilter})`; `const int kLogDefaultCapacity = 2000;`; `const int kLogMaxDetailChars = 4096;`; and the source constants.

**Context:**
- Pure: no Flutter, no `dart:io`, no clock. `tMs` is supplied by the caller.
- Source constants, so every subsystem names itself identically: `kLogSourceOpcUa`, `kLogSourceModbus`, `kLogSourceMqtt`, `kLogSourceDnp3`, `kLogSourceEnip`, `kLogSourceS7`, `kLogSourceScan`, `kLogSourceProject`, `kLogSourceSim`, `kLogSourceHistorian`, `kLogSourceScheduler`.
- `seq` is assigned by the buffer, monotonic, and **keeps increasing across eviction** (it identifies an entry; it is not an index).
- `filterLogEntries` is pure and is the whole point of the window — it is where a filter bug would hide, so it is testable without pumping a widget. `sources` null or empty means all. `textFilter` is case-insensitive and matches `message` **or** `detail`.
- A `detail` longer than `kLogMaxDetailChars` is truncated (with a visible marker) so one frame dump cannot dominate the buffer.

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/app_log_test.dart` covering:
- `LogRingBuffer` holds entries oldest-first and evicts the oldest at capacity — build with a small capacity (e.g. 3), add 5, assert exactly the last 3 remain **in order**.
- `seq` is monotonic and **continues increasing after eviction** (the 5th entry's `seq` is 5, not 3).
- `clear()` empties it; adding after `clear()` still yields monotonic `seq`.
- `filterLogEntries` by `minLevel` (a `warn` filter excludes `info`/`debug`/`trace` and includes `warn`/`error`).
- Filter by `sources` — one source, two sources, and `null`/empty meaning all.
- Filter by `textFilter` — case-insensitive, and a case matching only `detail` (not `message`) is still returned.
- Combined filter (level AND source AND text) returns only entries satisfying all three.
- Empty buffer and a no-match filter each return an empty list without throwing.
- A `detail` longer than `kLogMaxDetailChars` is truncated to the cap.

- [ ] **Step 2: Run — expect FAIL.** `cd mobile && flutter test test/app_log_test.dart`

- [ ] **Step 3: Implement** `app_log.dart`.

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: analyze + commit**

```bash
cd mobile && flutter analyze lib/models/app_log.dart test/app_log_test.dart
git add mobile/lib/models/app_log.dart mobile/test/app_log_test.dart
git commit -m "feat(logs): pure log entry, ring buffer, and filter core"
```

---

### Task 2: Logger service + level gating + the lazy-message contract

**Files:**
- Create: `mobile/lib/services/app_logger.dart`
- Test: `mobile/test/app_logger_test.dart`

**Interfaces:**
- Produces: `class AppLogger { AppLogger({int capacity}); bool isEnabled(String source, LogLevel level); void log(String source, LogLevel level, String message, {String? detail, int? tMs}); void logLazy(String source, LogLevel level, String Function() build, {String Function()? detail, int? tMs}); void setSourceLevel(String source, LogLevel min); LogLevel sourceLevel(String source); List<LogEntry> get entries; void clear(); }`

**Context:**
- Holds a `LogRingBuffer` and a per-source minimum-level map. Default minimum is `LogLevel.info` (so DEBUG/TRACE frame detail is **off by default**, per the approved decision).
- **`logLazy` is the hot-path API.** It checks the level FIRST and returns without calling `build()` when disabled. `log` (eager) exists for lifecycle events where the message is a constant or already-cheap string.
- `tMs` defaults to the current time when omitted; the parameter exists so tests supply a fixed clock. **The pure model still never reads a clock** — the service does.
- **Never throws.** Wrap the `build()` invocation so a throwing message builder is swallowed (recorded as an internal error entry at most, never rethrown) — a logging bug must not take down a protocol host.
- Does **NOT** extend `ChangeNotifier` and does **NOT** notify per entry. The Logs screen repaints on `LiveTick`.
- Not cleared on project switch — a deliberate divergence from `TagHistorian`, which does clear. Document why in the file header: the historian's samples belong to a project's tags, but log entries are app-level, and "it broke when I switched projects" is undiagnosable without the before-side.

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/app_logger_test.dart` covering:
- An entry at or above the source's level is recorded; one below is not.
- **THE PERFORMANCE CONTRACT:** `logLazy` with a disabled level **does not invoke the builder** — pass a builder that flips a captured `bool` (or increments a counter) and assert it was never called. Then assert it IS called when the level is enabled. This is the test that stops the contract silently regressing.
- Per-source levels are independent: raising `kLogSourceS7` to `debug` does not make `kLogSourceModbus` verbose.
- `setSourceLevel`/`sourceLevel` round-trip; an unconfigured source reports the default (`info`).
- **A throwing message builder does not escape** `logLazy` — `expect(() => …, returnsNormally)` — and does not corrupt the buffer (subsequent entries still record).
- A supplied `tMs` lands on the entry verbatim (deterministic-time hook).
- `clear()` empties the buffer.
- Capacity is respected end to end through the service.

- [ ] **Step 2: Run — expect FAIL.** `cd mobile && flutter test test/app_logger_test.dart`

- [ ] **Step 3: Implement.** **Step 4: Run — expect PASS.**

- [ ] **Step 5: analyze + commit**

```bash
git add mobile/lib/services/app_logger.dart mobile/test/app_logger_test.dart
git commit -m "feat(logs): logger service with per-source levels and lazy message gating"
```

---

### Task 3: Protocol-host instrumentation (closes the motivating gap)

**Files:**
- Modify: `mobile/lib/services/s7_host.dart`, `enip_host.dart`, `modbus_host.dart`, `opcua_host.dart`, `mqtt_host.dart`, `dnp3_host.dart`
- Test: `mobile/test/host_logging_test.dart`

**Context:**

Each host takes an optional `AppLogger?` (nullable so every existing test constructing a bare host keeps compiling — **do not** make it required).

Log at **INFO/WARN** (always on): bind success, bind failure **including the port-102 privilege error**, client connect/disconnect, protocol-level errors, and **write refusals** (forced tag / read-only entry).

Log at **DEBUG** (off by default, via `logLazy`): per-request function/service codes and byte counts.

**THE SPECIFIC GAP THIS TASK EXISTS TO CLOSE.** `mobile/lib/services/s7_host.dart:213` drops any non-Job ROSCTR and `:241` drops any unsupported function — both silently, with no reply and no record. That is why an Ignition Siemens driver could fail to connect while the card read "Running, Clients: 1". **Every silent drop must become a logged drop carrying its reason and the offending code**, in S7 and at the equivalent drop sites in the other five hosts. Read each host and find them; they are the `return;` paths that discard a parsed-but-unhandled request.

**SECURITY (binding):** MQTT passwords and OPC UA user tokens pass through this code. Log **outcomes only** — "username auth rejected", never the credential, and never a whole request object that might carry one. This gets a test.

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/host_logging_test.dart` covering:
- **The regression test for the motivating failure:** drive the S7 host (over a real `ServerSocket`, as `mobile/test/s7_host_test.dart` does — read it first) with a well-formed TPKT/COTP frame carrying an **unsupported ROSCTR**, with `kLogSourceS7` at `debug`. Assert an entry is recorded naming the offending code. Then assert that with the source at the default `info` level, no such entry appears (proving the verbosity gate actually gates).
- The same for an unsupported S7 **function** code.
- A bind failure on an unusable port records a WARN/ERROR entry.
- A client connect and disconnect each record an entry.
- **Security:** exercise the MQTT and/or OPC UA authentication path with a known password string and assert **no entry in the buffer contains that string** (scan `message` and `detail` of every entry).
- At least one other host records a write refusal (forced or read-only) — proving the instrumentation is not S7-only.

- [ ] **Step 2: Run — expect FAIL.** `cd mobile && flutter test test/host_logging_test.dart`

- [ ] **Step 3: Implement** across all six hosts.

- [ ] **Step 4: Run — expect PASS**, then the FULL suite (`cd mobile && flutter test`, baseline **1803 passing / 0 failing**) to confirm the optional-logger parameter broke no existing host test. Report the count.

- [ ] **Step 5: analyze + commit**

```bash
git add mobile/lib/services/ mobile/test/host_logging_test.dart
git commit -m "feat(logs): instrument the six protocol hosts, incl. silent-drop reasons"
```

---

### Task 4: Remaining subsystems + shell wiring + nav entry

**Files:**
- Modify: `mobile/lib/screens/workspace_shell.dart`, the scan-engine call sites, `mobile/lib/data/project_repository.dart`, and the sim/historian/scheduler call sites
- Test: additions to `mobile/test/workspace_shell_test.dart` (or a new `shell_logging_test.dart`)

**Context:**
- The shell **owns** the `AppLogger` as a field beside the hosts at `workspace_shell.dart:109-114`, and passes it to each host.
- **Scan engine**: start/stop, watchdog trips, task overruns. **Project**: load, save, **switch**, import/export, backfill/migration. **Sim/historian/scheduler**: notable state changes only. Keep these at INFO or above — they must not become chatty enough to churn the buffer.
- **Nav entry**: add a `'LOGS'` left-dock entry mirroring the `GATEWAY` block at `:2173-2185` (Container colour keyed to `_activeViewId == 'LOGS'`, `ListTile` with `leading: Icon(...)`, `onTap: () => _selectView(context, 'LOGS')`). Pick an icon consistent with the existing set.
- **CRITICAL — the easily-missed step:** `workspace_shell.dart:841` carries the comment *"MEMORY / SIMIO:rules / GATEWAY are always valid views."* and an accompanying validity check. **`'LOGS'` must be added there**, or the view will be silently reset when the project switches and the Logs screen will appear to "randomly close".
- Add the `'LOGS'` branch to `_buildCenterWorkspace()` (the `GATEWAY` branch at `:2777-2788` is the template) returning the Task 5 screen.
- The logger is **not** cleared on project switch; a project switch is itself logged under `kLogSourceProject`.

- [ ] **Step 1: Write the failing tests**
- Switching projects records a `kLogSourceProject` entry **and preserves entries logged before the switch** (the deliberate divergence from `TagHistorian` — assert both halves).
- Selecting the Logs nav entry sets `_activeViewId` to `'LOGS'` and renders the screen.
- A project switch while `'LOGS'` is the active view does **not** reset the view (the `:841` validity check).

- [ ] **Step 2: Run — expect FAIL.** **Step 3: Implement.** **Step 4: Run — expect PASS.**

- [ ] **Step 5: analyze + commit**

```bash
git add mobile/lib mobile/test
git commit -m "feat(logs): app-wide instrumentation, shell ownership, and Logs nav entry"
```

---

### Task 5: Logs screen + full gate + docs

**Files:**
- Create: `mobile/lib/screens/logs_screen.dart`
- Test: `mobile/test/logs_screen_test.dart`
- Docs: `docs/diagnostics.md`, `README.md`

**Context:**
- Filter row: free-text field, **source multi-select**, minimum-level dropdown, live-tail toggle, Clear.
- **Virtualized** `ListView.builder` — the buffer holds up to `kLogDefaultCapacity` (2000) entries and must not build them all.
- Rows: time, level, source, message. A row with `detail` is **expandable** to show it (frame dumps), matching the disclosure pattern in the reference UI.
- Level colour-coded within the existing dark palette using `withValues(alpha:)`.
- **Live-tail ON:** repaint on `LiveTick` via `ListenableBuilder(listenable: LiveTickScope.of(context), …)` and follow the tail. **Live-tail OFF:** frozen, scroll position preserved so a user can read without rows moving underneath.
- Live-tail with a filter active follows the tail **of the filtered view**.
- Per-source verbosity toggles (the DEBUG/TRACE switches) are reachable from this screen.
- Empty buffer and no-match filter each render a clear empty state, not a broken list.

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/logs_screen_test.dart` covering:
- Seeded entries render; the text filter narrows visible rows; the source filter narrows them; the level filter narrows them.
- A row with `detail` expands to reveal it and collapses again.
- Live-tail off then a new entry added → the view does not jump; live-tail on → the new entry appears (pulse `debugLiveTick`, per `workspace_shell.dart:402`).
- Empty state renders for an empty buffer and for a filter matching nothing.
- Changing a per-source verbosity toggle calls through to `setSourceLevel`.
- **No overflow at 320, 360 and 1400** — assert via `expect(tester.takeException(), isNull)`, the mechanism used elsewhere in this suite.

- [ ] **Step 2: Run — expect FAIL.** **Step 3: Implement.** **Step 4: Run — expect PASS.**

- [ ] **Step 5: Full gate**

```bash
cd mobile && flutter analyze          # zero warnings
cd mobile && flutter test             # ALL pass — record the count (baseline 1803)
cd mobile && flutter build web --release
```

- [ ] **Step 6: Docs**

- `docs/diagnostics.md`: what the Logs window shows; the source list; how per-source verbosity works and that DEBUG/TRACE is **off by default**; that the log is **memory-only and never written to disk** (and therefore lost on restart); that it is **not** cleared on project switch and why; the no-credentials rule; and a worked example — *diagnosing a protocol client that connects but sends nothing we serve*, which is the failure that motivated the feature.
- `README.md`: a feature bullet.

- [ ] **Step 7: Commit**

```bash
git add mobile/lib/screens/logs_screen.dart mobile/test/logs_screen_test.dart docs/diagnostics.md README.md
git commit -m "feat+docs(logs): Logs screen with source/level/text filters and live tail"
```

---

## Self-Review

**Spec coverage:** Component 1 (pure core) → Task 1 ✓; Component 2 (logger service) → Task 2 ✓; Component 3 (instrumentation) → Tasks 3 and 4 ✓; Component 4 (Logs screen) → Task 5 ✓. All three approved decisions are bound to tasks: app-wide source tagging (Tasks 3-4 + the source constants in Task 1), memory-only ring buffer (Task 1, with no persistence anywhere in the plan), per-source verbosity off by default (Task 2's default `info`, gate-tested in Task 3). Both performance contracts and the security rule have explicit tests (Tasks 2 and 3). The spec's stated risks each have a mitigation in a task: log volume → per-source verbosity; hot-path cost → the lazy-builder test; instrumentation sprawl → shared source constants.

**Placeholder scan:** No TBDs. The two values left to the implementer — the `'LOGS'` nav icon and the exact colour per level — are cosmetic, scoped to Tasks 4 and 5, and constrained to the existing dark palette.

**Type consistency:** `LogLevel`, `LogEntry`, `LogRingBuffer`, `filterLogEntries` and the `kLogSource*` constants (Task 1) are consumed by `AppLogger` (Task 2), which is consumed by the hosts (Task 3), the shell and remaining subsystems (Task 4), and the screen (Task 5). `AppLogger.entries`/`setSourceLevel`/`sourceLevel`/`clear` (Task 2) are exactly what Task 5's screen calls. `LiveTickScope.of(context)` (existing) is what Task 5 uses for repaint.

**Note for the executor:** the binding properties are (a) the pure core **never reads a clock**; (b) `logLazy` **never invokes its builder** when the level is disabled — tested, not assumed; (c) the logger **never notifies per entry** and **never throws**; (d) **no credential ever reaches the buffer** — tested; (e) every previously-silent request drop is logged **with its reason**; (f) the log **survives a project switch** while the historian does not; and (g) `'LOGS'` is added to the view-validity check at `workspace_shell.dart:841`, or the screen will appear to close itself on project switch. Tasks 1 and 2 are pure/near-pure and independently testable; Task 3 is the one that pays off the feature's motivating failure.
