# Composite/System Tag Exposure + Outbound MQTT Performance — Design

**Date:** 2026-07-14
**Status:** Approved by user (chat, 2026-07-14).
**Builds on:** the four protocol map models + their `autoGenerate` (`opcua_map.dart`, `modbus_map.dart`, `dnp3_map.dart`, `mqtt_map.dart`), the OPC UA address-space builder (`opcua_address_space.dart`), the MQTT publisher + host (`protocols/mqtt/mqtt_publisher.dart`, `services/mqtt_host.dart`), the reserved `System` UDT (`system_tags.dart`), and the tag resolver (`tag_resolver.dart` — `readPath`/`writePath`/`dataTypeOfPath`/`leafAndNodePaths`/`childrenOf`).

## Problem

**Part A — composites aren't exposable.** Every map's `autoGenerate` skips composite/array tags (`value is Map || value is List`), so the reserved `System` UDT (a SYSTEM composite) and user DUTs (e.g. `DB_Motor1`), timers, and counters never reach the outbound protocols. The user wants `System`'s fields transmitted.

**Part B — 100 tags over MQTT is laggy.** All four protocol hosts, the scan loop, the signal engine, and the Flutter UI share one Dart isolate (event loop) — there is no per-protocol thread. The MQTT host ticks every **50 ms (20 Hz)** and its report-by-exception uses **exact-equality** diffing with **no deadband**, so 100 continuously-changing FLOAT64 ramps publish ~100 metrics every tick (~2000 PUBLISH/sec), each encoded + socket-written synchronously, and `notifyListeners()` fires up to 20×/sec, rebuilding the (100-row, folder-grouped) gateway UI. The result is event-loop saturation and UI-rebuild churn — laggy at low CPU.

## Goal

- **A:** Auto-generate expands any composite/array tag into its scalar **leaf** entries (keyed by dotted path), so `System.Fault`, `System.ScanTimeMs`, `DB_Motor1.Setpoint`, etc. are transmitted on the protocols each supports.
- **B:** Cut the MQTT event-loop load with main-isolate tuning — a configurable publish interval, an optional analog deadband, and throttled UI notifications — with no threading rewrite.

## Decisions (locked with the user)

- Perf approach: **tune on the main isolate** (no background isolate).
- Composite expansion: **any composite/array tag** (System + DUTs + timers + counters), not a System-only carve-out.
- Deadband **defaults to `0.0` (off)** — behavior only changes when the operator sets one. Publish interval **defaults to 250 ms**.
- Perf scope: **MQTT publish interval + deadband + a shared notify-throttle** (applied to the MQTT host). OPC UA subscriptions (already have a configurable publishing interval) and DNP3 are unchanged.

## Architecture

### Part A — composite leaf expansion

**Shared leaf enumeration.** A pure helper (in `tag_resolver.dart` or a small `map_leaves.dart`) yields, for a project, the list of **scalar leaf** `(path, dataType)` pairs across all tags: a scalar tag → itself; a composite/array tag → its scalar leaves via `leafAndNodePaths` + `dataTypeOfPath` (recursively through struct members and array elements; integers are leaves — bits are NOT expanded). Each map's `autoGenerate` iterates these leaves instead of only top-level scalar tags.

| Map | Change to `autoGenerate` |
|---|---|
| `mqtt_map.dart` | One `MqttMapEntry` per scalar leaf: `tag: <leafPath>`, `metric: <folderPrefixed leafPath>` (root folder → bare leaf path), `writable` from the ROOT tag's `ioType`. STRING allowed. |
| `modbus_map.dart` | One entry per numeric/BOOL leaf; **skip STRING** (and TIMER/COUNTER composite roots are now expanded to their scalar members, which ARE mappable). Table + address by leaf dataType, as today. |
| `dnp3_map.dart` | One point per BOOL/numeric leaf; **skip STRING**. |
| `opcua_map.dart` | One `OpcuaNode` per scalar leaf: `nodeId: 'ns=1;s=<leafPath>'`, `tag: <leafPath>`, `access` from the ROOT tag's ioType. STRING allowed. |

- **Access/folder inheritance:** a leaf's access derives from its ROOT tag's `ioType` (`SimulatedOutput` → ReadOnly, else ReadWrite) — so all `System.*` leaves are ReadOnly on the wire (incl. `System.AlarmReset`; fault reset stays via the app/HMI). A leaf's folder = its ROOT tag's `folder` (for MQTT metric prefixing / OPC UA grouping).
- **Dedup / skip rules preserved:** each map keeps its existing per-type skip set; a leaf already present isn't duplicated (the appenders' dedup is unaffected — they still handle scalar generated sets).

**OPC UA address-space builder** (`opcua_address_space.dart`). `OpcUaAddressSpace.build` currently resolves each node via `_findTag(project, node.tag)` (exact root-name match) to get dataType/browseName/folder — this fails for a dotted leaf path. Change: resolve a node's `tag` string as a **path** — dataType via `dataTypeOfPath(project, node.tag)` (skip the node if it returns null), live value already read via `readPath(project, tagName)` in `readVariant` (works for dotted paths unchanged), `browseName` = the dotted path (unique; avoids `System.Fault` vs `DB_Motor1.Fault` collisions), `folder` = the ROOT tag's folder (first path segment resolved to a `PlcTag`). Root-name nodes (scalar tags) still resolve identically (a bare name is a valid `dataTypeOfPath`).

### Part B — MQTT performance

**Config model** (`protocol_settings.dart` `MqttProtocolConfig`, additive):
- `publishIntervalMs` (int, default **250**) — the report-by-exception sampling/publish period.
- `deadband` (double, default **0.0** = off) — the minimum absolute change for a NUMERIC metric to republish.

**Publisher** (`mqtt_publisher.dart` `changedPublishes`): report-by-exception gains a deadband gate — a numeric leaf republishes only when `(value - lastPublished).abs() > deadband` (deadband `0.0` → any change, today's behavior); BOOL/STRING always publish on any change. `_lastPublished` baseline update unchanged.

**Host** (`mqtt_host.dart`): `_startTickTimer` uses `Duration(milliseconds: cfg.publishIntervalMs)` (clamped to a sane floor, e.g. ≥ 20 ms) instead of the hardcoded 50 ms; re-arm the tick when the interval changes (on (re)connect / config change).

**Notify-throttle** (shared, small unit e.g. `services/notify_throttle.dart`): coalesces `notifyListeners()` to at most a few Hz. State-change notifications (connect / disconnect / error / publish-count crossing) fire immediately; the high-frequency per-tick publish-count bump is throttled to ~4 Hz (a trailing timer). The MQTT host routes its per-tick `notifyListeners()` through the throttle; immediate calls (connect/disconnect/error) bypass it. `dispose()` cancels the throttle timer.

## Testing

**Part A (pure):**
- Leaf enumeration: a SYSTEM tag expands to its scalar leaves (Fault BOOL, ScanTimeMs FLOAT64, Hour INT32, DateTime STRING, …) with correct dotted paths + dataTypes; a DUT expands to its members; an array expands to elements; a scalar tag stays one leaf; integer leaves are not bit-expanded.
- Each `autoGenerate`: composite → per-leaf entries keyed by dotted path; Modbus/DNP3 **skip STRING** leaves (System.DateTime absent) while OPC UA/MQTT include them; access/folder inherited from the root tag; a scalar-only project's map is unchanged (regression).
- OPC UA address space: a node `ns=1;s=System.Fault` resolves dataType (Boolean), reads the live value, BrowseName == `System.Fault`, folder == root's folder; an unresolvable dotted path is skipped.

**Part A (E2E):** extend the Rust `opcua` probe to map `System` and read `System.Fault` / `System.ScanTimeMs` over the wire (honest fallback preserved; report live vs fallback truthfully).

**Part B:**
- Publisher deadband: a numeric metric whose change ≤ deadband is suppressed; > deadband publishes; deadband `0.0` = every change (today's behavior); BOOL/STRING always publish regardless of deadband.
- Config round-trip: `publishIntervalMs` + `deadband` survive `toJson`/`fromJson`, default 250 / 0.0 when absent (WS6 guard).
- Host interval: the tick timer uses `publishIntervalMs` (clamped ≥ 20 ms); a config change re-arms it. (A widget/host-level test with an injected clock, mirroring existing mqtt_host tests.)
- Notify-throttle: N rapid `request()` calls within the window produce ≤ 1 trailing notify; an `immediate()` fires at once; dispose cancels the timer.

**Regression:** full `flutter test`; `flutter analyze` zero; `flutter build web --release` compiles; existing MQTT/OPC UA/map tests pass (scalar-only maps + default MQTT behavior unchanged when interval=250/deadband=0 — note existing tests that assumed the 50 ms tick must move to the config value or an injected interval).

## Global constraints

- No vendor branding ("OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix"); OPC UA/IEC/industrial terms fine.
- `mobile/lib/models/**` and `mobile/lib/protocols/**` stay **pure Dart** (no `dart:io`, no Flutter); only `services/*_host.dart` use `dart:io`. The notify-throttle unit uses only `dart:async` (Timer) — no Flutter.
- Additive persistence: `MqttProtocolConfig.publishIntervalMs` (250) + `deadband` (0.0) are additive; the WS6 lossless round-trip stays green; a project without them behaves as before. Composite expansion changes only generated maps (regenerated on demand), not a persisted-model field.
- Zero `flutter analyze` warnings; braces on all control flow; prefer `const`. No RenderFlex overflow at 320/360/1400 for any config-field UI added.
- Leaf paths use the existing resolver (dotted `.` for struct members, `[i]` for array elements); `readPath`/`writePath` remain the single access path (forcing stays authoritative).
- Reserved `System` stays read-only on the wire (all leaves inherit its `SimulatedOutput` access); `System.AlarmReset` is not remotely writable in this workstream.

## Phasing (one spec → phased plan)

- **Phase A — Composite leaf expansion.** Shared leaf enumeration; expand all four `autoGenerate`s; OPC UA address-space dotted-path resolution. Unit tests (+ scalar-only regression).
- **Phase B — MQTT interval + deadband.** `MqttProtocolConfig.publishIntervalMs`/`deadband` (additive + round-trip); publisher deadband gate; host uses the configured interval; a small config UI field (interval + deadband) in the MQTT card. Tests.
- **Phase C — Notify-throttle.** Shared throttle unit; route the MQTT host's per-tick notify through it (immediate on state change). Tests.
- **Phase D — Validation, E2E, docs, final review.** Full gates; OPC UA E2E reading `System.Fault`; round-trip; update `docs/` (System exposure + MQTT tuning); whole-branch review; merge.
