# Bulk Simulated Test Tags

This document covers the bulk simulated test-tag generator — folders for
organizing tags, the always-on signal generators that drive them, how they
interact with program writes and the outbound protocol servers, and the
per-protocol auto-map/delete-set affordances in the Memory Manager.

Implementation: `mobile/lib/models/signal_gen.dart` (the `SignalGen` model),
`mobile/lib/models/signal_engine.dart` (the waveform math + per-scan driver),
`mobile/lib/models/test_tag_set.dart` (the bulk builder + protocol-map
appenders), `mobile/lib/screens/memory_manager_screen.dart` (the Generate
Test Set dialog, folder grouping, and folder delete), and
`mobile/lib/screens/gateway_screen.dart` (protocol-map folder grouping).

## Folders

`PlcTag.folder` is a flat string label (no nested paths, no separators) used
purely to group tags for display. A tag with an empty `folder` (`''`) is
considered to live at the **root** and is never shown inside a collapsible
group — it renders directly alongside the project's other ungrouped tags,
both in the Memory Manager's tag list and in each protocol's map editor
(`groupEntriesByFolder` in `gateway_screen.dart`). Any non-empty `folder`
value groups its tags under a collapsible, named section, sorted
alphabetically after the root tags.

Folders are not a separate first-class object — there is no `Folder` model,
no folder rename cascade, and no per-folder settings. A folder exists only
as long as at least one tag references its name; it disappears once its last
tag is deleted or reassigned.

## Signal generators

A `SignalGen` is a small, always-on record that drives one tag's value every
scan:

```dart
class SignalGen {
  String id;
  String targetPath;   // the tag name the generator writes
  String type;         // ramp | sine | square | triangle | random | counter | toggle
  double minValue;
  double maxValue;
  int periodMs;
  double phase;        // 0..1 fraction of the period, for staggering
  bool enabled;
}
```

`PlcProject.signalGens` holds every generator in the project (additive,
alongside the pre-existing `simRules`); `applySignalGens` (in
`signal_engine.dart`) runs once per scan tick, after the sim-rules step and
before task scheduling (see `runScanTick` in `mobile/lib/screens/
scan_tick.dart`), writing every enabled generator's current value straight
into the tag database via the same force-aware `writePath` every other
engine uses.

### The seven signal types

Let `span = maxValue - minValue` and let `frac` be the generator's position
within its current period, `0 ≤ frac < 1`:

```
frac = (( elapsedMs / periodMs + phase ) mod 1 + 1) mod 1
```

(the double-mod keeps `frac` positive even if a caller ever passes a
negative `phase`). `elapsedMs` is a per-run-session clock (`SignalRuntime`)
that resets to `0` at the start of each run session, exactly like the other
scan-tick runtimes.

| Type | Value | Notes |
|---|---|---|
| `ramp` | `minValue + span * frac` | Linear sawtooth: rises for the whole period, then snaps back to `minValue`. |
| `sine` | `minValue + span * (0.5 + 0.5 * sin(2π * frac))` | Full sine cycle mapped onto `[minValue, maxValue]`. |
| `square` | `frac < 0.5 ? minValue : maxValue` | 50% duty cycle. |
| `triangle` | `minValue + span * (1 - \|2*frac - 1\|)` | Rises for the first half of the period, falls for the second half. |
| `counter` | `(minValue.round() + n).clamp(minValue.round(), maxValue.round())`, `n = ⌊elapsedMs/periodMs + phase⌋` | Integer step count, one increment per elapsed period, clamped at the range (does not wrap). |
| `toggle` | `n.isOdd`, `n = ⌊elapsedMs/periodMs + phase⌋` | `BOOL` flip once per period. |
| `random` | `minValue + (maxValue - minValue) * u`, `u` from a per-period xorshift32 draw | Deterministic, not `Math.random()` — see below. |

`periodMs <= 0` is treated as "frozen": `ramp`/`sine`/`square`/`triangle`
hold at `minValue`, `counter` holds at `minValue.round()`, `toggle` holds
`false`, and `random` holds `minValue`. This is a defensive guard (a `0`
period would otherwise divide by zero), not a documented feature to author
deliberately.

`counter` and `toggle` produce `INT32`/`BOOL` tags respectively; every other
type produces `FLOAT64` (see `_dataTypeForType` in `test_tag_set.dart`).

#### Deterministic randomness

`random`'s draw is reproducible, not truly random: for period index `n`, the
generator hashes `"<gen.id>#<n>"` with an FNV-1a 32-bit hash, feeds that
through one xorshift32 step, and maps the result to `[0,1]` before scaling
into `[minValue, maxValue]`. The same project, the same generator `id`, and
the same period index always produce the same value — so a serialized
project's round-trip and re-run reproduce byte-identical `random` sequences
(the same guarantee the pre-existing measurement-noise simulation behaviour
makes), and the value only changes when the period index advances, not on
every scan tick.

### Phase-staggering

`phase` (a fraction `0..1` of one period) shifts a generator's `frac`/period
index without changing its type, range, or period — it lets many tags share
identical waveform parameters while reading distinct live values at any
given instant. The bulk test-set builder (`buildTestSet`, below) spaces
`count` generators evenly across a period by setting generator `i`'s
`phase = i / count`, so, e.g., a set of 4 `ramp` tags is staggered a quarter
period apart from its neighbors.

## Read-only enforcement

A tag driven by an enabled `SignalGen` is deliberately **read-only from
everywhere except the generator itself** — both from program logic and over
the wire.

### Read-only in programs

`generatedPaths(gens)` (`signal_engine.dart`) collects the `targetPath` of
every *enabled* generator into a `Set<String>`. `runScanTick` computes this
set once per tick and passes it as the `readOnly` parameter into every
language executor (`executeLdPrograms`/`executeFbdPrograms`/
`executeSfcPrograms`/`executeStPrograms`). Each executor's write callback
checks the set before applying a write:

```dart
if (readOnly == null || !readOnly.contains(path)) {
  _forceAwareWrite(p, path, v);
}
```

A coil, `MOVE` block, ST assignment, or SFC action attempting to write a
generated tag's path is silently dropped — no fault, no exception, just a
no-op — exactly the same shape as a write to a `SimulatedOutput` tag from
program logic already was before signal generators existed. The generator
itself writes through `applySignalGens`'s own direct call into `writePath`,
which runs before the executors and isn't subject to this guard.

### Read-only on the wire (`SimulatedOutput`)

Tags built by the bulk generator always carry `ioType: 'SimulatedOutput'`
(mirroring how manually-created simulated outputs already behave), and every
`appendTo*Map` function (below) always maps them as read-only regardless of
the protocol: Modbus entries land in the `discrete`/`input` tables with
`access: 'ReadOnly'`, OPC UA nodes get `access: 'ReadOnly'`, and MQTT entries
get `writable: false` (DNP3 point types are inherently read/write by point
type — `binaryInput`/`analogInput` for a `SimulatedOutput`'s data, never the
`*Output` point types). A SCADA/master write attempt against one of these
points is refused the same way any other `SimulatedOutput` tag's write is
refused by that protocol's existing server-side handling.

## Bulk generation: `buildTestSet`

`TestSetSpec` describes one batch:

```dart
class TestSetSpec {
  String folder;
  String baseName;
  int count;
  String type;      // ramp | sine | square | triangle | random | counter | toggle
  double minValue;
  double maxValue;
  int periodMs;
}
```

`buildTestSet(spec)` returns `count` `PlcTag`s named `baseName` + a 1-based,
zero-left-padded index sized to `count`'s digit width (`count: 3` →
`R1..R3`; `count: 100` → `S001..S100`), each tagged with `folder: spec.folder`
and `ioType: 'SimulatedOutput'`, plus one matching `SignalGen` per tag with
`phase = i / count` for even staggering. A tag's `path` is
`"<folder>/<name>"` (the existing folder/name display convention); the
generator's `targetPath` — and the value the sim/protocol engines actually
resolve against — is the bare tag `name`, matching how every other path
resolution in this codebase keys by name, not by display path.

Each generated tag's initial (`t=0`) value is computed the same way the
engine would compute it on the very first tick: `counter` seeds at
`minValue.round()`, `toggle` starts `false`, everything else evaluates the
continuous waveform at `t=0`.

## Per-protocol auto-map (next-free allocation)

Four `appendTo*Map` functions place a freshly-built batch of tags onto an
existing protocol map, each finding the next unused address/index/slot
*after* every entry the map already has, so appending a batch never
duplicates or overlaps an existing entry:

- **`appendToModbusMap`** — `BOOL` tags go to the `discrete` (bit) table;
  every other mappable type goes to the `input` (register) table (both
  read-only tables, matching `SimulatedOutput`). Because a `ModbusMapEntry`
  doesn't record its bound tag's data type, the next-free register address
  is computed by conservatively assuming every *existing* register-table
  entry occupies the worst-case width (`FLOAT64`, 4 registers) — bit-table
  entries have no such ambiguity (always 1 bit) and advance by exactly 1.
  Newly-appended entries within the same call use their own tag's real
  (known) width for their own subsequent spacing.
- **`appendToDnpMap`** — `BOOL` tags go to `binaryInput`; everything else
  goes to `analogInput`. Each point type's next-free index is simply
  one past the highest existing index of that point type.
- **`appendToOpcuaMap`** — OPC UA has one flat, single-namespace address
  space, so there is no per-table slotting to compute; each tag becomes a
  `ReadOnly` node at `ns=1;s=<tag.path>`.
- **`appendToMqttMap`** — each tag becomes one non-writable metric entry
  keyed by tag name.

All four skip a tag that is already present in the map (matched by tag
name) and any tag the target protocol can't represent — a composite
(struct/array) value, or (for Modbus/DNP3/MQTT) a `TIMER`/`COUNTER`/`STRING`
data type. OPC UA is the only one of the four that doesn't additionally
filter by data type (matching its pre-existing `autoGenerate` behavior).

## The Generate Test Set dialog

The Memory Manager's **Generate Test Set** button opens a dialog collecting
a folder name, a base tag name, a count, a signal type, a min/max range, a
period, and one checkbox per protocol currently enabled on the project
(OPC UA / Modbus TCP / DNP3 / MQTT — an unconfigured protocol's checkbox is
hidden entirely, not just disabled). Generating:

1. Rejects (with a visible error) an empty folder name, a `minValue` that
   isn't strictly less than `maxValue`, or any generated tag name that
   collides with an existing project tag.
2. Builds the tags + generators via `buildTestSet` and adds both to the
   project.
3. Appends the tags onto every ticked, currently-configured protocol's map.

## Folder grouping (UI)

Both the Memory Manager's tag list and every protocol map editor group their
rows by folder using the same convention: root-folder (`''`) rows render
first with no header, and every other folder gets a collapsible section
labeled with the folder name and its tag/entry count. The Memory Manager's
folder sections are independently collapsible per folder (state kept in a
`Set<String>` of collapsed folder names); protocol map sections are grouped
for display only (no persisted collapse state).

## Delete-set

Deleting a folder (the delete affordance on a folder's header row, with a
confirmation dialog) removes, in one operation:

- every tag whose `folder` matches (by name),
- every `SignalGen` whose `targetPath` matches one of those tags' names, and
- every entry across all four protocol maps (OPC UA nodes, Modbus entries,
  DNP3 entries, MQTT entries) referencing one of those tag names.

This is the folder's full teardown — there is no partial/selective delete
within a folder from this affordance; deleting individual tags one at a time
still works as it always has for any tag, folder-tagged or not.
