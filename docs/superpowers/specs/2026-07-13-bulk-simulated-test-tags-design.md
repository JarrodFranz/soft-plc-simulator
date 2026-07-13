# Bulk Simulated Test Tags — Design

**Date:** 2026-07-13
**Status:** Approved by user (chat, 2026-07-13).
**Builds on:** the tag/value model (`project_model.dart`, `tag_resolver.dart`), the always-on sim pass (`sim_engine.dart` / `applySimRules`, run each scan in `scan_tick.dart`), the four auto-allocating protocol maps (`opcua_map.dart`, `modbus_map.dart`, `dnp3_map.dart`, `mqtt_map.dart` — each already assigns addresses sequentially and treats `ioType == 'SimulatedOutput'` as read-only on the wire), the Memory Manager (`memory_manager_screen.dart`), and the outbound-protocol map editors (`gateway_screen.dart`).

## Problem

There is no fast way to stand up many moving values to exercise the four hosted protocol servers (OPC UA / Modbus TCP / MQTT+Sparkplug B / DNP3). Today a value that changes over time must be built one `SimRule` at a time and mapped by hand. An engineer testing a SCADA/historian connection wants to bulk-create hundreds of tags that continuously move (ramp, sine, …), organized into named groups, automatically exposed on the chosen protocols, and safe to also read from logic without a program accidentally clobbering them.

## Goal

Let an operator **generate a set of simulated "test tags"** in one action: pick a **folder**, a **signal type**, a **count**, min/max/period, and which **protocols** to expose them on. The tags then continuously produce values (phase-staggered so every tag in the set reads differently and the set forms a moving wave), appear under their folder in the Memory Manager and in each selected protocol's map, and are **read-only in programs** (usable in conditions, never assignable). Normal read-write program tags live in the **root** folder (or any folder the operator picks).

## Decisions (locked with the user)

- **Folder model:** a flat `folder` label on every tag (default `''` = root). One level of named groups; tag names stay globally unique.
- **Signal types:** `ramp` (sawtooth), `sine`, `square`, `triangle`, `random`, `counter` (monotonic INT32), `toggle` (BOOL). Analog types produce FLOAT64.
- **Per-tag spread:** phase-staggered — each tag `i` of `count` gets `phase = i / count`; all tags in a set share type/min/max/period.
- **Protocol mapping:** the create dialog offers a checkbox per protocol; only ticked protocols get the set's tags appended to their map.
- **Read-only in programs:** hard — the logic write path refuses assignments to a generated tag.
- **Reuse `ioType='SimulatedOutput'`** for on-the-wire read-only (no protocol-map changes). One `SignalGen` per tag (the "set" is shared folder + creation params). Deleting a folder deletes its tags, generators, and protocol-map entries together.

## Architecture

### Unit map

| Unit | File | Responsibility |
|---|---|---|
| Tag folder (additive) | `mobile/lib/models/project_model.dart` (`PlcTag`) | Add `folder` (String, `''`). Serialize (additive). |
| Signal generator model (new) | `mobile/lib/models/signal_gen.dart` | `class SignalGen { String id; String targetPath; String type; double minValue; double maxValue; int periodMs; double phase; bool enabled; }` + `fromJson`/`toJson`. |
| Project list (additive) | `mobile/lib/models/project_model.dart` (`PlcProject`) | Add `List<SignalGen> signalGens` (default `[]`); serialize under key `signal_gens` (additive). |
| **Signal engine (pure, new)** | `mobile/lib/models/signal_engine.dart` | `applySignalGens(PlcProject p, List<SignalGen> gens, int dtMs, SignalRuntime rt)` — writes each enabled gen's target tag directly each scan; `SignalRuntime` holds a per-session clock + per-gen counter state; `generatedPaths(gens) -> Set<String>`. Pure — no `dart:io`/Flutter/`DateTime`/`Random`. |
| Bulk-create + allocators (new) | `mobile/lib/models/test_tag_set.dart` | Pure builders: `buildTestSet(...)` → `(List<PlcTag>, List<SignalGen>)`; and `appendToOpcuaMap`/`appendToModbusMap`/`appendToDnpMap`/`appendToMqttMap` that add entries for given tags at the next free address/index/node/metric, leaving existing entries untouched. |
| Scan integration | `mobile/lib/screens/scan_tick.dart` | Run `applySignalGens` each tick (beside `applySimRules`, before logic). Own a `SignalRuntime` in `ScanTickRuntime`; reset it in `resetSession()`. |
| Hard read-only | `mobile/lib/models/{ld,fbd,sfc,st}_exec.dart` | The executors' write path refuses assignments to a path in the generated-paths set (passed in, built once per scan from `signalGens`). |
| Bulk-create UI (new dialog) | `mobile/lib/screens/memory_manager_screen.dart` | "Generate Test Set" dialog (folder, base name, count, type, min/max/period, protocol checkboxes) → builds tags+gens, appends to ticked maps, adds to project. |
| Folder grouping | `mobile/lib/screens/memory_manager_screen.dart` | Group the tag list by `folder` (collapsible; root first). Delete-folder removes its tags + gens + map entries. |
| Map-view grouping | `mobile/lib/screens/gateway_screen.dart` | Group each protocol's map rows by the mapped tag's `folder`. |

### Signal engine semantics (pure)

`SignalRuntime` holds a session clock `elapsedMs` (accumulates `dtMs` each tick) and a per-gen `counter` map (for `counter`/`toggle`). `reset()` zeroes them (run-session boundary).

For each enabled gen, let `T = periodMs` (guard `T <= 0` → hold at `minValue`), `frac = ((elapsedMs / T) + phase) mod 1` in `[0,1)`, and `span = maxValue - minValue`:

- **ramp** (sawtooth): `minValue + span * frac`.
- **sine**: `minValue + span * (0.5 + 0.5 * sin(2π * frac))`.
- **triangle**: `minValue + span * (1 - |2*frac - 1|)` … i.e. up 0→1 over the first half, down over the second.
- **square**: `frac < 0.5 ? minValue : maxValue`.
- **random**: a value in `[minValue, maxValue]` chosen from a deterministic PRNG seeded by (`gen.id`, floor(`elapsedMs/T`) + phase bucket) — changes once per period, reproducible.
- **counter**: INT32 that increments by 1 each period (`floor((elapsedMs/T) + phase)`), wrapping/clamping into `[minValue, maxValue]` as integers.
- **toggle**: BOOL, `((floor((elapsedMs/T) + phase)) is even) ? false : true` — flips each period.

Writes go **directly** to `p` via the resolver (bypassing the logic read-only guard). Determinism: all time is `dtMs`-derived; the PRNG mirrors the existing WS14 noise engine's seeded generator (no `Math.random`).

### Hard read-only enforcement

`generatedPaths(gens)` returns the set of enabled gens' `targetPath`s. The scan tick passes this set to each executor; each executor's write helper (the `(path, v)` writer used by `executeRung` / FBD / SFC / ST) skips the write when `path` is in the set (reads are unaffected). The signal engine and protocol/HMI/force paths are separate and still write. Generated tags are also created with `ioType = 'SimulatedOutput'`, so the four protocol maps already publish them read-only to external clients.

### Protocol map appenders (pure, next-free allocation)

Each appender computes the next free slot from the map's existing entries and appends one entry per new tag, reusing the existing per-protocol rules:
- **Modbus**: per-table (`coil`/`discrete`/`holding`/`input`) next address = max(existing end) ; BOOL → `discrete` (read-only), numeric → `input` (read-only); advance by `regsForType`.
- **DNP3**: per-point-type next index = max(existing)+1; BOOL → `binaryInput`, numeric → `analogInput`.
- **OPC UA**: node `ns=1;s=<path>`, access `ReadOnly` (derived from `SimulatedOutput`); node id is path-derived so uniqueness follows tag-name uniqueness.
- **MQTT**: metric = tag name (or path); read-only.

Skips a tag a map can't represent (matching each map's existing auto-generate skip rules), and never duplicates a tag already present in the map.

### Bulk-create flow

`buildTestSet(folder, baseName, count, type, min, max, periodMs)` returns `count` `PlcTag`s (`name = baseName + zeroPadded(i)`, `folder`, `ioType='SimulatedOutput'`, dataType by type, initial value = the gen's value at `t=0`) and `count` `SignalGen`s (`phase = i / count`). The dialog then, for each ticked protocol, calls the matching appender with the new tags, and adds tags + gens (+ updated maps) to the project. Tag-name collisions across the whole project are rejected (reuse/mirror the task-name-uniqueness pattern) before creating the set.

## Config model

Additive. `PlcTag.folder` and `PlcProject.signalGens` are new and default to empty; a project with neither behaves exactly as today. The WS6 lossless round-trip must cover both.

## Testing

**Pure signal engine (`signal_engine_test.dart`):** each waveform's value at `t=0`, quarter, half, three-quarter period (ramp linear; sine 0.5→1→0.5→0; triangle 0→1→0; square min/max; toggle flips per period; counter increments per period and clamps; random reproducible for a fixed seed and in-range); `phase` offset shifts the waveform; `periodMs <= 0` holds at min; determinism (two runtimes, same inputs → same output); `generatedPaths` returns exactly the enabled targets.

**Allocators (`test_tag_set_test.dart`):** `buildTestSet` produces `count` tags with padded names, the folder, `SimulatedOutput`, correct dataType, and `phase = i/count`; each appender adds entries at the next free slot **after** pre-existing entries (no collision, no duplicate), skips unrepresentable tags, and leaves existing entries byte-identical.

**Hard read-only (`executor_readonly_test.dart`):** an LD/FBD/SFC/ST program that assigns a generated tag does not change it (write refused), but reading it in a condition works; a non-generated tag is still writable.

**Scan integration:** `runScanTick` advances generated tags each tick and they are readable by logic the same tick; `resetSession` restarts the signal clock.

**UI:** the Generate-Test-Set dialog creates N tags + gens in the folder and appends to only the ticked protocols; the Memory Manager groups tags by folder (root first, collapsible) and delete-folder removes tags + gens + map entries; the outbound-protocol map views group rows by folder. No RenderFlex overflow at 320/360/1400.

**Persistence:** `folder` + `signalGens` round-trip (WS6 lossless guard); a project loaded without them defaults to root/empty.

**Machine-proof E2E:** extend one protocol's existing Rust-client probe (e.g. Modbus or OPC UA) to read a generated set and assert the values move / are distinct — reusing the existing honest build+unit fallback.

**Regression:** full `flutter test`; `flutter analyze` zero; `flutter build web --release` compiles; existing projects (no folders/gens) behave identically.

## Global constraints

- No vendor branding ("OpenPLC"/"Beremiz"/"CODESYS"/"RSLogix"); IEC/industrial terms fine. Dark theme; zero `flutter analyze` warnings (`withValues(alpha:)`, not `withOpacity`); braces on all control flow; prefer `const`. No RenderFlex overflow at 320/360/1400.
- `mobile/lib/models/**` stays **pure Dart** (no `dart:io`, no Flutter): the signal engine and allocators take time/values as inputs; the PRNG is seeded/deterministic (no `Math.random`/`DateTime`).
- All tag writes go through the resolver (`writePath`); forcing stays authoritative for reads. The signal engine writes generated tags directly; logic writes to them are refused.
- Additive persistence: `folder` + `signalGens` are additive; the WS6 lossless round-trip stays green; the None/default path is byte-identical when no test sets exist.
- INT32 for `counter` values (dart2js-safe). Generated numeric analog tags are FLOAT64; `toggle` is BOOL.
- Reuse the task-name-uniqueness helper pattern for the tag-name collision check on bulk create (no duplicate tag names project-wide).

## Phasing (one spec → phased plan)

- **Phase A — Model + pure signal engine.** `PlcTag.folder`; `SignalGen` + `PlcProject.signalGens`; `signal_engine.dart` (`applySignalGens`/`SignalRuntime`/`generatedPaths`) with all seven waveforms; unit tests.
- **Phase B — Scan integration + hard read-only.** Run `applySignalGens` in `scan_tick.dart` (own+reset a `SignalRuntime`); refuse logic writes to generated paths across the four executors; tests.
- **Phase C — Bulk builder + protocol appenders.** `test_tag_set.dart` (`buildTestSet` + four appenders) with next-free allocation; tests.
- **Phase D — Generate-Test-Set dialog + Memory Manager folder grouping + delete-set.** Wire the builder/appenders into the UI; group tags by folder; folder delete removes tags/gens/map entries; widget tests.
- **Phase E — Outbound map-view folder grouping.** Group each protocol map's rows by the mapped tag's folder.
- **Phase F — Validation, docs, E2E, final review.** Full gates; round-trip; a `docs/simulated-test-tags.md`; one live protocol E2E over a generated set; whole-branch review; merge.
