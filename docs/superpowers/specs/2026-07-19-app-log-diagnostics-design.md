# In-App Log / Diagnostics Window — Design Spec

**Date:** 2026-07-19
**Status:** Approved (design)

## Goal

Give the app a **source-tagged, filterable in-app log** so failures that are
currently invisible become diagnosable without a debugger, a packet capture, or
the other end's log file.

## Why now (the motivating failure)

An Ignition Siemens driver failed to connect to the shipped S7comm host. From
the app there was **no signal at all**: the Outbound Protocols card showed
`Running, Clients: 1` — technically true, since TCP connected — while every
request was being dropped. The cause (`s7_host.dart:213` drops any non-Job
ROSCTR, `:241` drops any unsupported function, both silently, with no reply and
no record) took a code read plus the *client's* log to identify.

That is a general defect in the product, not an S7 defect. **Six protocol hosts
can each fail silently in the same way.**

## Current state (verified, as-found)

- **There is no logging infrastructure of any kind.** No logger, no
  `debugPrint`, no `dart:developer`. A grep across `mobile/lib` returns nothing.
  This is a clean slate, not a retrofit.
- Hosts expose a **single `String? lastError`** slot each
  (`dnp3_host.dart:246`, `enip_host.dart:432`, `modbus_host.dart:216`,
  `mqtt_host.dart:291`, and the same in the OPC UA and S7 hosts). One string,
  overwritten, no history, no per-event record.
- Two established patterns this must follow:
  - **`services/tag_historian.dart`** — the bounded in-memory ring-buffer
    precedent. Note `sample(..., int nowMs)` takes time **as a parameter**; the
    model never reads a clock itself.
  - **`widgets/live_tick.dart`** — `LiveTick`/`LiveTickScope`, the throttled
    repaint pulse. Its doc comment is explicit that `of()` is a deliberate
    non-dependency lookup so only the value leaf repaints. **A live-tailing log
    view must use this or it will fight the scan loop.**

## Decisions taken (user-approved)

1. **App-wide, source-tagged.** Not protocols only: the six hosts, the scan
   engine, project load/save/import, the simulation engine, the historian, and
   the task scheduler each log under their own source tag.
2. **Memory-only bounded ring buffer.** Never written to disk, matching the tag
   historian. No storage growth, no rotation, no migration, and no file that
   could accumulate tag values.
3. **Per-source verbosity, off by default.** Normal operation logs lifecycle
   events, errors and refusals. A per-source DEBUG/TRACE toggle additionally
   logs frame-level detail, enabled only while diagnosing.

## Non-goals / YAGNI

- **No export in v1.** Deliberate, per decision 2. Easy to add later; recorded
  so its absence reads as a decision.
- **No disk persistence, no log rotation, no remote/syslog shipping.**
- **No crash reporting or telemetry.** Nothing leaves the device.
- **No per-entry user annotation, no bookmarks.**

## Global Constraints

- Pure Dart (no Flutter, no `dart:io`) in `mobile/lib/models/app_log.dart`.
- **Deterministic core:** the log model never reads a clock. Timestamps are
  passed in, exactly as `TagHistorian.sample(..., int nowMs)` does, so filtering
  and eviction are unit-testable without faking time.
- Additive: no existing serialized form changes. The log is runtime-only state
  and appears in **no** project JSON.
- Dark theme; `withValues(alpha:)` never `withOpacity`; braces on all control
  flow; zero `flutter analyze` warnings; no overflow at 320/360/1400.
- No competitor-tooling branding; no reverse-engineering wording.

## Component 1 — Pure log core (`mobile/lib/models/app_log.dart`)

```dart
enum LogLevel { trace, debug, info, warn, error }

class LogEntry {
  final int seq;          // monotonic, assigned by the buffer
  final int tMs;          // caller-supplied timestamp
  final LogLevel level;
  final String source;    // one of the kLogSource* constants
  final String message;   // one line
  final String? detail;   // optional multi-line payload (frame dump etc.)
}

class LogRingBuffer {
  LogRingBuffer({int capacity = kLogDefaultCapacity});
  void add(LogEntry e);           // evicts oldest at capacity
  List<LogEntry> get entries;     // oldest-first
  void clear();
}

/// PURE filter — the whole point of the window, and the part most likely to
/// harbour a bug, so it is testable without pumping a widget.
List<LogEntry> filterLogEntries(
  List<LogEntry> entries, {
  LogLevel minLevel = LogLevel.trace,
  Set<String>? sources,        // null/empty = all
  String textFilter = '',      // case-insensitive, matches message OR detail
});
```

`kLogDefaultCapacity` is a documented constant (proposed **2000** entries —
enough to hold a failed connection attempt with frame detail, bounded enough
that the buffer's own memory is negligible).

**Source constants** live here so every subsystem names itself the same way:
`kLogSourceOpcUa`, `kLogSourceModbus`, `kLogSourceMqtt`, `kLogSourceDnp3`,
`kLogSourceEnip`, `kLogSourceS7`, `kLogSourceScan`, `kLogSourceProject`,
`kLogSourceSim`, `kLogSourceHistorian`, `kLogSourceScheduler`.

## Component 2 — Logger service (`mobile/lib/services/app_logger.dart`)

Owns the ring buffer and a per-source minimum level. Two performance rules,
both load-bearing because protocol hosts will call this **per frame**:

- **The level check must precede message construction.** A disabled TRACE must
  not cost a string interpolation on every frame. The API therefore takes a
  lazy message (`String Function()`) for the frame-detail path, or checks
  `isEnabled(source, level)` before building. A naive
  `log(source, level, 'raw=${hex(bytes)}')` would format the string *before*
  the call and pay the cost even when disabled — that is the trap to avoid.
- **It does NOT `notifyListeners()` per entry.** The Logs view repaints on the
  throttled `LiveTick` pulse. Notifying per entry would thrash the widget tree
  far harder than the per-scan `setState` that `LiveTick` was introduced to
  eliminate.

The logger is **not** cleared on project switch — a deliberate divergence from
`TagHistorian`, which does clear. The historian's samples belong to a project's
tags; log entries are app-level, and "it broke when I switched projects" is
undiagnosable if the before-side is discarded. A project switch is itself logged
as an INFO entry under `kLogSourceProject`.

### Security rule (binding)

**No credential may ever reach a log call.** MQTT passwords and OPC UA user
tokens pass through code that becomes log-adjacent. Memory-only retention limits
the blast radius but does not remove the rule: authentication paths log
*outcomes* ("username auth rejected"), never the secret, and never a whole
request/response object that might contain one. This is an explicit review item,
not an aspiration.

## Component 3 — Source instrumentation

- **Six protocol hosts**: bind success/failure (including the port-102
  privilege error), client connect/disconnect, protocol-level errors, and
  **write refusals** (forced / read-only) at INFO-WARN. At DEBUG: per-request
  function/service codes and byte counts.
- **The closing of the motivating gap**: every silent drop becomes a logged
  drop **with its reason** — `s7_host.dart:213` (non-Job ROSCTR) and `:241`
  (unsupported function), and the equivalent drop sites in the other five hosts.
  These log at DEBUG with the offending code, so a mis-configured client is
  identifiable from the app alone.
- **Scan engine**: start/stop, watchdog trips, task overruns.
- **Project**: load, save, switch, import/export, backfill/migration.
- **Sim engine / historian / scheduler**: notable state changes only.

## Component 4 — Logs screen

A new nav section. Contents:

- A filter row: free-text field, **source multi-select**, minimum-level
  dropdown, live-tail toggle, and Clear.
- A **virtualized** list (`ListView.builder`) — the buffer holds up to
  `kLogDefaultCapacity` entries and must not build them all.
- Rows show time, level, source, message; a row with `detail` is **expandable**
  (the frame dump), matching the disclosure-chevron pattern in the reference UI.
- Level is colour-coded within the existing dark palette, using
  `withValues(alpha:)`.
- When live-tail is on, the list repaints on `LiveTick` and follows the tail;
  when off, the view is frozen and scroll position is preserved so a user can
  read without entries moving under them.
- Per-source verbosity toggles (decision 3) are reachable from this screen.
- No overflow at 320/360/1400.

## Data flow

Subsystem calls `AppLogger.log(source, level, …)` → level check → (if enabled)
`LogEntry` appended to the ring buffer, oldest evicted at capacity. The Logs
screen reads `entries`, applies `filterLogEntries`, and renders; it repaints on
`LiveTick` while live-tailing. Nothing is written to disk and nothing enters
project JSON.

## Error handling / edge cases

- **The logger must never throw and never break a caller.** A logging failure
  must not take down a protocol host or the scan. Log calls are best-effort.
- Buffer at capacity → oldest evicted; eviction is not itself logged (that would
  be self-amplifying).
- A very large `detail` is truncated at a documented cap so one frame dump
  cannot evict the whole buffer.
- Filtering an empty buffer, and a text filter matching nothing, both render an
  empty state rather than a broken list.
- Live-tail with a filter active follows the tail **of the filtered view**.

## Testing

- **Pure (`app_log_test.dart`)**: ring-buffer eviction at capacity and exact
  ordering; `seq` monotonic across eviction; `filterLogEntries` for each of
  minLevel / sources / text and their combination; case-insensitivity; text
  matching `detail` as well as `message`; empty-buffer and no-match cases.
- **Logger (`app_logger_test.dart`)**: a disabled level records nothing **and
  does not invoke the message builder** (assert via a callback that would flag
  if called — this is the performance contract, so it gets a real test); per-source
  levels are independent; a throwing message builder cannot escape the logger;
  the buffer survives a project switch.
- **Instrumentation**: the S7 host logs an unsupported-ROSCTR drop with its code
  (a direct regression test for the motivating failure).
- **Widget (`logs_screen_test.dart`)**: filters narrow the visible rows; a
  detail row expands; live-tail on/off; no overflow at 320/360/1400.
- **Security**: a test asserting no credential-bearing field reaches the buffer
  on the MQTT and OPC UA auth paths.
- Full gate: `flutter analyze`, `flutter test`, `flutter build web --release`.

## Files

- **Create:** `mobile/lib/models/app_log.dart`,
  `mobile/lib/services/app_logger.dart`, the Logs screen under
  `mobile/lib/screens/`, plus matching tests.
- **Modify:** the six `services/*_host.dart`, the scan engine, project
  repository, sim/historian/scheduler call sites, and the shell (nav entry +
  logger ownership/provision).
- **Docs:** a short `docs/diagnostics.md`; `README.md` feature bullet.

## Risks

- **Log volume at DEBUG on a busy poll cycle** could churn the buffer fast
  enough to lose context. Mitigated by per-source (not global) verbosity, so
  only the subsystem under investigation is verbose.
- **Performance of the log call on the hot path** — addressed by the
  level-check-before-construction rule, which is a tested contract rather than a
  convention.
- **Instrumentation sprawl**: touching every subsystem is the bulk of the work
  and the most likely place for an inconsistent source name or level. The shared
  source constants exist to contain that.

## Decomposition (plan-time)

**5 tasks**: (1) pure log core + filter; (2) logger service + level gating +
security rule; (3) protocol-host instrumentation incl. the silent-drop closure;
(4) remaining subsystems + shell wiring + nav; (5) Logs screen + widget tests +
full gate + docs.
