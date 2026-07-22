# FBD Editor Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the flat single-canvas FBD editor into an IEC 61131-3 multi-network editor — a top-to-bottom stack of numbered networks that execute in sequence (data-flow within each) — with every block nameable and a live-value/logic overlay like the LD/SFC editors.

**Architecture:** Additive `network` index on `FbdBlock` + a per-program `fbdNetworks` header list; the executor iterates networks in order and runs the existing topological pass scoped to each; the editor becomes a vertical stack of network lanes; a new `FbdMonitor` (mirroring `LdMonitor`) captures the per-block pin values the executor already computes, surfaced via the existing `LiveTick` overlay.

**Tech Stack:** Dart/Flutter. Reuses `fbd_exec.dart`, `fbd_pins.dart`, `fbd_layout.dart`, `live_tick.dart`, and mirrors `ld_monitor.dart` / the LD editor's online overlay.

## Global Constraints

- Pure Dart, in-app (ADR-010). Deterministic execution (no clock/RNG beyond existing per-block state). Zero `flutter analyze` warnings. Run flutter from `mobile/`.
- **Additive / backward-compatible:** new serialization keys only (`network` on a block, `fbd_networks` on a program); every existing FBD program and all default demos load and execute **identically** (migrate to one network). No change to LD/SFC/ST behavior or the scan contract beyond a new optional `monitor` param.
- **Wires are intra-network only.** Blocks in different networks are never wired; cross-network data flows through tags (`TAG_OUTPUT` → `TAG_INPUT`). The editor offers wiring only within a lane; reassigning a block's network or deleting a network prunes now-cross-network wires.
- **Execution order = network list order** (index 0 first). Reordering lanes reorders execution; no separate order field.
- Responsive: no overflow at 320 / 360 / 1400; dark theme; live widgets use `LiveTick`/`LiveTickScope` throttled repaint (no shell-wide setState per scan).
- Commit trailer on every commit: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Deferred items are tracked in `docs/DEFERRED.md` — do not re-scope them in.

## File Structure

- Modify `mobile/lib/models/project_model.dart` — `FbdBlock.network`, new `FbdNetwork` class, `PlcProgram.fbdNetworks` + serialization (Task 1).
- Create `mobile/lib/models/fbd_networks.dart` — pure network-editing helpers (Task 3).
- Create `mobile/lib/models/fbd_monitor.dart` — the live-value tap (Task 2).
- Modify `mobile/lib/models/fbd_exec.dart` — network-aware execution + monitor (Task 2).
- Modify `mobile/lib/screens/scan_tick.dart` — hold + clear + pass `fbdMonitor` (Task 2).
- Modify `mobile/lib/screens/fbd_editor_screen.dart` — lanes (Task 4), naming (Task 5), overlay (Task 6).
- Modify `mobile/lib/screens/workspace_shell.dart` — pass `monitor` + `scanRunning` to the FBD editor (Task 6).
- Modify `mobile/lib/data/default_projects.dart` + `docs/` — a multi-network demo + docs (Task 7).

---

### Task 1: Data model — `network` field, `FbdNetwork`, migration, serialization

**Files:**
- Modify: `mobile/lib/models/project_model.dart` (`FbdBlock` ~279-319; `PlcProgram` ~432-489)
- Test: `mobile/test/models/fbd_networks_model_test.dart`

**Interfaces — Produces:**
- `FbdBlock` gains `int network` (default `0`); serialized key `network`.
- `class FbdNetwork { String comment; FbdNetwork({this.comment = ''}); factory FbdNetwork.fromJson(...); Map<String,dynamic> toJson(); }`.
- `PlcProgram` gains `List<FbdNetwork> fbdNetworks` (default `[]`); serialized key `fbd_networks`.
- `PlcProgram.fromJson` normalizes: an FBD program with blocks but empty `fbdNetworks` gets `[FbdNetwork()]`, and `fbdNetworks` is extended so its length ≥ `maxBlockNetwork + 1`.

- [ ] **Step 1: Write the failing test** (`mobile/test/models/fbd_networks_model_test.dart`)

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

void main() {
  test('FbdBlock.network defaults to 0 and round-trips', () {
    final b = FbdBlock(id: 'b1', type: 'ADD', title: 'Sum', network: 2);
    expect(b.network, 2);
    expect(FbdBlock.fromJson(b.toJson()).network, 2);
    // default
    expect(FbdBlock(id: 'b2', type: 'AND', title: '').network, 0);
  });

  test('legacy FBD program (no network keys) migrates to one network', () {
    final legacy = {
      'name': 'Old', 'language': 'FunctionBlockDiagram',
      'fbd_blocks': [
        {'id': 'b1', 'type': 'TAG_INPUT', 'title': 'A'},
        {'id': 'b2', 'type': 'AND', 'title': ''},
      ],
      'fbd_wires': [],
    };
    final p = PlcProgram.fromJson(legacy);
    expect(p.fbdBlocks.every((b) => b.network == 0), isTrue);
    expect(p.fbdNetworks.length, 1);
    expect(p.fbdNetworks.first.comment, '');
  });

  test('fbdNetworks is extended to cover the highest block network index', () {
    final json = {
      'name': 'Multi', 'language': 'FunctionBlockDiagram',
      'fbd_blocks': [
        {'id': 'b1', 'type': 'AND', 'title': '', 'network': 0},
        {'id': 'b2', 'type': 'OR', 'title': '', 'network': 2},
      ],
      'fbd_wires': [],
      'fbd_networks': [{'comment': 'first'}],
    };
    final p = PlcProgram.fromJson(json);
    expect(p.fbdNetworks.length, 3); // indices 0,1,2 all exist
    expect(p.fbdNetworks[0].comment, 'first');
    // round-trip preserves networks
    final rt = PlcProgram.fromJson(p.toJson());
    expect(rt.fbdNetworks.length, 3);
    expect(rt.fbdBlocks.firstWhere((b) => b.id == 'b2').network, 2);
  });
}
```

- [ ] **Step 2: Run — expect FAIL** (`cd mobile && flutter test test/models/fbd_networks_model_test.dart`): `network`/`FbdNetwork`/`fbdNetworks` undefined.

- [ ] **Step 3: Implement.** In `FbdBlock`: add `int network;`, constructor `this.network = 0`, `fromJson` `network: json['network'] ?? 0`, `toJson` `'network': network`. Add the `FbdNetwork` class after `FbdWire`:

```dart
class FbdNetwork {
  String comment;
  FbdNetwork({this.comment = ''});
  factory FbdNetwork.fromJson(Map<String, dynamic> json) =>
      FbdNetwork(comment: json['comment'] ?? '');
  Map<String, dynamic> toJson() => {'comment': comment};
}
```

In `PlcProgram`: add `List<FbdNetwork> fbdNetworks;`, constructor `List<FbdNetwork>? fbdNetworks` → `fbdNetworks = fbdNetworks ?? []`. In `toJson` add `'fbd_networks': fbdNetworks.map((n) => n.toJson()).toList()`. In `fromJson`, after building `fbdBlocks`, normalize:

```dart
final loadedNetworks = (json['fbd_networks'] as List? ?? [])
    .map((n) => FbdNetwork.fromJson(n)).toList();
// Normalize so every block's network index has a header, and an FBD program
// with blocks always has at least one network (legacy migration).
final maxNet = fbdBlocksList.fold<int>(-1, (m, b) => b.network > m ? b.network : m);
final needed = (json['language'] == 'FunctionBlockDiagram' && fbdBlocksList.isNotEmpty)
    ? (maxNet + 1).clamp(1, 1 << 30)
    : maxNet + 1;
while (loadedNetworks.length < needed) {
  loadedNetworks.add(FbdNetwork());
}
```

(Assign `fbdNetworks: loadedNetworks` in the constructor call. Use whatever the local variable for the parsed blocks list is named — adapt `fbdBlocksList` to the real local.)

- [ ] **Step 4: Run — expect PASS.** Then `cd mobile && flutter analyze` (zero). Full suite (baseline 2521) — record count; existing serialization/persistence tests must stay green (additive keys).

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/models/project_model.dart mobile/test/models/fbd_networks_model_test.dart
git commit -m "feat(fbd): FbdBlock.network + FbdNetwork + fbdNetworks with legacy migration"
```

---

### Task 2: Network-aware executor + `FbdMonitor` + scan wiring

**Files:**
- Create: `mobile/lib/models/fbd_monitor.dart`
- Modify: `mobile/lib/models/fbd_exec.dart` (`executeFbdPrograms` ~495-589)
- Modify: `mobile/lib/screens/scan_tick.dart` (runtime fields ~16-17, clear ~30-31, FBD call ~74)
- Test: `mobile/test/fbd_networks_exec_test.dart`

**Interfaces:**
- Consumes: `PlcProgram.fbdNetworks` / `FbdBlock.network` (Task 1); `fbdInputPins`/`_evalBlock` (existing).
- Produces: `class FbdMonitor { final Map<String,dynamic> pinValue = {}; String keyFor(String prog, String blockId, String pin) => '$prog|$blockId|$pin'; void clear() => pinValue.clear(); }`; `executeFbdPrograms(..., {Set<String>? only, Set<String>? readOnly, FbdMonitor? monitor})`.

**Context:** Today `executeFbdPrograms` runs one topological worklist over all of a program's `fbdBlocks`. Make it iterate networks in ascending index order and run that same worklist scoped to each network's blocks. Wires are intra-network, so a block's deps are always in its own network; scoping is just filtering `prog.fbdBlocks` by `network`. Cross-network tag writes already land immediately (`_evalBlock` force-aware TAG_OUTPUT), so a later network reads updated tags in the same scan.

- [ ] **Step 1: Write the failing test** (`mobile/test/fbd_networks_exec_test.dart`)

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/fbd_monitor.dart';

PlcProject _proj(List<FbdBlock> blocks, List<FbdWire> wires, int networks) {
  final prog = PlcProgram(
    name: 'F', language: 'FunctionBlockDiagram', rungs: [],
    fbdBlocks: blocks, fbdWires: wires,
    fbdNetworks: [for (var i = 0; i < networks; i++) FbdNetwork()],
  );
  return PlcProject(
    id: 'p', name: 'P', controllerName: 'C',
    tags: [
      PlcTag(name: 'Src', path: 'Src', dataType: 'FLOAT64', value: 10.0),
      PlcTag(name: 'Mid', path: 'Mid', dataType: 'FLOAT64', value: 0.0),
      PlcTag(name: 'Out', path: 'Out', dataType: 'FLOAT64', value: 0.0),
    ],
    structDefs: [], programs: [prog], tasks: [], hmis: [],
  );
}

void main() {
  test('networks execute in order: producer(net0) feeds consumer(net1) via tags',
      () {
    // net0: Src(+5 via ADD const) -> Mid ; net1: Mid(+5) -> Out. Out should be 20.
    final blocks = [
      FbdBlock(id: 'in0', type: 'TAG_INPUT', title: '', tagBinding: 'Src', network: 0),
      FbdBlock(id: 'c0', type: 'CONST', title: '', tagBinding: '5', network: 0),
      FbdBlock(id: 'add0', type: 'ADD', title: '', network: 0),
      FbdBlock(id: 'out0', type: 'TAG_OUTPUT', title: '', tagBinding: 'Mid', network: 0),
      FbdBlock(id: 'in1', type: 'TAG_INPUT', title: '', tagBinding: 'Mid', network: 1),
      FbdBlock(id: 'c1', type: 'CONST', title: '', tagBinding: '5', network: 1),
      FbdBlock(id: 'add1', type: 'ADD', title: '', network: 1),
      FbdBlock(id: 'out1', type: 'TAG_OUTPUT', title: '', tagBinding: 'Out', network: 1),
    ];
    final wires = [
      FbdWire(fromBlockId: 'in0', toBlockId: 'add0', toPin: 'IN1'),
      FbdWire(fromBlockId: 'c0', toBlockId: 'add0', toPin: 'IN2'),
      FbdWire(fromBlockId: 'add0', toBlockId: 'out0'),
      FbdWire(fromBlockId: 'in1', toBlockId: 'add1', toPin: 'IN1'),
      FbdWire(fromBlockId: 'c1', toBlockId: 'add1', toPin: 'IN2'),
      FbdWire(fromBlockId: 'add1', toBlockId: 'out1'),
    ];
    final proj = _proj(blocks, wires, 2);
    final rt = FbdRuntime();
    final mon = FbdMonitor();
    executeFbdPrograms(proj, 100, rt, monitor: mon);
    expect(proj.tags.firstWhere((t) => t.name == 'Out').value, 20.0);
    // monitor captured the net0 ADD output pin
    expect(mon.pinValue[mon.keyFor('F', 'add0', 'OUT')], 15.0);
  });
}
```

(Verify exact pin names via `fbdInputPins('ADD')` / `fbdOutputPins('ADD')` and adjust `toPin`/expected keys to the real registry names; the test is the oracle.)

- [ ] **Step 2: Run — expect FAIL** (`FbdMonitor` undefined; and pre-change execution ignores networks / discards pin values).

- [ ] **Step 3: Implement.** Create `fbd_monitor.dart` (the class above). In `executeFbdPrograms`: add the `FbdMonitor? monitor` param. Inside the per-program body, wrap the existing `inputWireFor`/`depsOf`/worklist in a loop over networks in ascending order, scoping `prog.fbdBlocks` to the current network:

```dart
final netIndices = prog.fbdBlocks.map((b) => b.network).toSet().toList()..sort();
for (final net in netIndices) {
  final netBlocks = prog.fbdBlocks.where((b) => b.network == net).toList();
  // ... build byId/inputWireFor/depsOf/cache/done over netBlocks (and
  // prog.fbdWires whose endpoints are both in netBlocks) exactly as today,
  // then the same topological worklist, then the cycle-fallback pass ...
  for (final b in netBlocks) {
    // after cache[b.id] = _evalBlock(...):
    final out = cache[b.id];
    if (out != null && monitor != null) {
      out.forEach((pin, val) => monitor.pinValue[monitor.keyFor(prog.name, b.id, pin)] = val);
    }
  }
}
```

Keep the existing `_resolvedToPin`/`_resolvedFromPin`/`_evalBlock` untouched. A one-network program (all blocks `network == 0`) executes exactly as before (single pass). Provide the full rewritten `executeFbdPrograms` in this step.

Then in `scan_tick.dart`: add `final FbdMonitor fbdMonitor = FbdMonitor();` beside `fbd` (line ~17), add `fbdMonitor.clear();` beside `fbd.clear();` (line ~31), and change the FBD call (line ~74) to `executeFbdPrograms(p, dtMs, rt.fbd, only: only, readOnly: readOnly, monitor: rt.fbdMonitor);`. Import `fbd_monitor.dart`.

- [ ] **Step 4: Run — expect PASS.** Add a second test: reversing the two networks' indices (consumer in net0, producer in net1) yields the OLD/stale value on the first scan (proves ordering matters). `flutter analyze` zero. Full suite — record count; existing `fbd_exec_integration_test` must stay green (its programs are one network → identical).

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/models/fbd_monitor.dart mobile/lib/models/fbd_exec.dart mobile/lib/screens/scan_tick.dart mobile/test/fbd_networks_exec_test.dart
git commit -m "feat(fbd): network-ordered execution + FbdMonitor pin-value tap"
```

---

### Task 3: Pure network-editing helpers

**Files:**
- Create: `mobile/lib/models/fbd_networks.dart`
- Test: `mobile/test/models/fbd_networks_edit_test.dart`

**Interfaces — Produces (all pure, mutate the passed `PlcProgram`, deterministic, never throw):**
- `List<FbdBlock> fbdBlocksInNetwork(PlcProgram p, int net)` — blocks with `network == net`.
- `int addFbdNetwork(PlcProgram p, {String comment = ''})` — appends a network, returns its index.
- `void moveFbdNetwork(PlcProgram p, int from, int to)` — reorders the `fbdNetworks` header AND every block's `network` index so membership follows the move (execution order changes).
- `void deleteFbdNetwork(PlcProgram p, int net)` — removes the network, its blocks, and every wire touching those blocks; renumbers remaining blocks/networks so indices stay contiguous 0..n-1.
- `void setBlockNetwork(PlcProgram p, String blockId, int net)` — reassigns a block; then **prunes any wire between that block and a block now in a different network** (`pruneCrossNetworkWires`).
- `void pruneCrossNetworkWires(PlcProgram p)` — removes every `FbdWire` whose two endpoints are in different networks (idempotent invariant enforcer).

- [ ] **Step 1: Write the failing tests** (`mobile/test/models/fbd_networks_edit_test.dart`) covering:
  - `addFbdNetwork` appends and returns the new index; `fbdBlocksInNetwork` filters correctly.
  - `deleteFbdNetwork(1)` on a 3-network program removes net-1's blocks + their wires and renumbers net-2 → net-1 (blocks and header), leaving contiguous indices.
  - `moveFbdNetwork(2, 0)` moves the header to the front and rewrites block network indices so the moved network's blocks are now network 0 and the others shift down.
  - `setBlockNetwork(p, 'b', 1)` where `b` (net 0) had a wire to `a` (net 0): after the move the a↔b wire is pruned (cross-network); a wire between two blocks moved together stays.
  - `pruneCrossNetworkWires` removes only cross-network wires, keeps intra-network ones; idempotent.

  Write concrete assertions with exact expected block/wire counts and indices.

- [ ] **Step 2: Run — expect FAIL.** **Step 3: Implement `fbd_networks.dart`** with the six functions above. Full, deterministic code (iterate lists in order; renumber via a stable index remap). Guard all against out-of-range `net` (no-op). Provide the complete implementation in this step.

- [ ] **Step 4: Run — expect PASS.** `flutter analyze` zero. Full suite — record count.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/models/fbd_networks.dart mobile/test/models/fbd_networks_edit_test.dart
git commit -m "feat(fbd): pure network-editing helpers (add/move/delete/reassign + wire pruning)"
```

---

### Task 4: Editor rework — stacked network lanes + network CRUD

**Files:**
- Modify: `mobile/lib/screens/fbd_editor_screen.dart`
- Test: `mobile/test/fbd_editor_networks_test.dart`

**Interfaces:**
- Consumes: `fbd_networks.dart` helpers (Task 3); existing `fbdInputPins`/`fbdOutputPins`, `autoArrangeFbd`, the block-card/wire-painter widgets already in the editor.
- Produces: a lane-based editor UI (no new public Dart API; verified by widget tests + keys).

**Deliverable contract (the implementer builds widgets to satisfy this; read the current `fbd_editor_screen.dart` first and preserve its block-card, pin, and wire-painter code — only the outer canvas structure changes):**
- The editor body is a **vertical scroll of network lanes** (one per `program.fbdNetworks` entry, in order). Each lane:
  - A header `Row` with `Key('fbd_network_header_$i')` showing `Network ${i+1}`, an editable comment `TextField` (`Key('fbd_network_comment_$i')`, commits via `onProgramUpdated`), and icon buttons: add-block (`Key('fbd_net_addblock_$i')`), auto-arrange (`Key('fbd_net_arrange_$i')`), move-up (`Key('fbd_net_up_$i')`), move-down (`Key('fbd_net_down_$i')`), delete (`Key('fbd_net_del_$i')`, confirms).
  - A bounded pan/zoom canvas (reuse the existing `InteractiveViewer` + `Stack` + `_WirePainter`) rendering only `fbdBlocksInNetwork(program, i)` and the wires among them.
- A **"+ Network"** button (`Key('fbd_add_network')`) calling `addFbdNetwork`.
- Network buttons call the Task-3 helpers, then `setState` + `onProgramUpdated`.
- **Wiring is confined to a lane** (both endpoints from the same lane's blocks).
- **Per-lane auto-arrange** lays out only that network's blocks — add `autoArrangeFbdNetwork(PlcProgram, int net)` to `fbd_layout.dart` (or filter the existing dependency-depth layout to one network) so each lane arranges independently.
- Adding a block from a lane's add-block button creates it with `network: i`.

- [ ] **Step 1: Write failing widget tests** (`mobile/test/fbd_editor_networks_test.dart`) at 1400×1200: pump `FbdEditorScreen` with a 2-network program; assert both lane headers render (`Network 1`, `Network 2`); tapping `fbd_add_network` adds a 3rd lane; `fbd_net_del_1` (confirm) removes lane 2 and renumbers; editing `fbd_network_comment_0` persists to `program.fbdNetworks[0].comment`; tapping `fbd_net_up_1` reorders (assert `program` block networks changed). Also a 320-width pump asserting no overflow. Run → FAIL.
- [ ] **Step 2: Implement** the lane rework consuming Task-3 helpers + the new `autoArrangeFbdNetwork`. Preserve all existing block-card/pin/wire widgets. Run tests → PASS.
- [ ] **Step 3:** `flutter analyze` zero; full suite — the existing `fbd_editor_test.dart` must still pass (update it only where it assumed a single flat canvas; keep its intent). Record count.
- [ ] **Step 4: Commit** (`fbd_editor_screen.dart`, `fbd_layout.dart`, the two test files) — `feat(fbd): stacked network-lane editor with network CRUD`.

---

### Task 5: Name all blocks (expose the edit affordance)

**Files:**
- Modify: `mobile/lib/screens/fbd_editor_screen.dart` (the block card + `_showConfigureBlockDialog`)
- Test: `mobile/test/fbd_editor_networks_test.dart` (add a case) or a small new test

**Context:** `_showConfigureBlockDialog` already has a "Block name" `TextFormField` for every block type; today only `TAG_*`/`CONST` cards expose a route to it (a pencil icon), so operator blocks (ADD/SUB/GT/LT/AND…) can't be named on desktop. Add a **"Network" dropdown** to that same dialog (calling `setBlockNetwork`) while you're here.

- [ ] **Step 1:** Add a failing widget test: pump the editor with an `ADD` block, open its config (tap the card / an always-present edit affordance), enter a name, confirm, assert `block.title` updated and the card shows it. Run → FAIL (no route today on desktop). 
- [ ] **Step 2: Implement** — make every block card open `_showConfigureBlockDialog` (a tap route or a pencil affordance shown for all types), and add the "Network" dropdown bound to `setBlockNetwork(program, block.id, value)` + `onProgramUpdated`. Run → PASS.
- [ ] **Step 3:** `flutter analyze` zero; full suite — record count.
- [ ] **Step 4: Commit** — `feat(fbd): name any block + change a block's network from its config`.

---

### Task 6: Live-value + logic overlay

**Files:**
- Modify: `mobile/lib/screens/fbd_editor_screen.dart`
- Modify: `mobile/lib/screens/workspace_shell.dart` (the `FbdEditorScreen(...)` construction ~3077)
- Test: `mobile/test/fbd_editor_online_test.dart`

**Interfaces:**
- Consumes: `FbdMonitor` (Task 2, held at `scan_tick`'s runtime as `rt.fbdMonitor`), `LiveTick`/`LiveTickScope`.
- The `FbdEditorScreen` constructor gains `FbdMonitor? monitor` and `bool scanRunning` (mirror the LD editor's `monitor`/`scanRunning` params). The shell passes `monitor: _scan.fbdMonitor, scanRunning: isRunning && !_faulted` (compare the LD wiring at `workspace_shell.dart:3069-3075`).

**Deliverable contract (mirror the LD/SFC online overlay — read `ld_editor_screen.dart`'s `_online`/`LiveTickScope`/energized-coloring code):**
- An **online toggle** (`_online`, default false; `Key('fbd_online_toggle')`). Offline = today's static view, unchanged.
- While online, each wire shows the value it carries — read `monitor.pinValue[monitor.keyFor(program.name, wire.fromBlockId, resolvedFromPin)]` — as compact text (numbers ~2 dp, `TRUE`/`FALSE` for bool), and boolean-`true` wires/pins render green (energized), false dim.
- Stateful block outputs (`Q`,`ET`,`CV`,…) show their monitored values at the pins.
- Repaint via `LiveTickScope` (fallback to a local `LiveTick` when absent, as the SFC editor does) so only on-screen lanes rebuild per scan pulse.

- [ ] **Step 1:** Failing widget test (`fbd_editor_online_test.dart`): pump `FbdEditorScreen` with a `monitor` pre-populated with a known pin value + `scanRunning: true`; toggle online (`fbd_online_toggle`); assert the value text appears on the wire/pin and a boolean-true pin is styled energized (find by key/color). Run → FAIL.
- [ ] **Step 2: Implement** the overlay + add the two constructor params + wire the shell. Run → PASS.
- [ ] **Step 3:** `flutter analyze` zero; full suite — record count; existing `fbd_editor_test.dart` and shell tests green.
- [ ] **Step 4: Commit** (`fbd_editor_screen.dart`, `workspace_shell.dart`, the test) — `feat(fbd): live-value + energized overlay (online view) via FbdMonitor`.

---

### Task 7: Multi-network demo, validation & docs

**Files:**
- Modify: `mobile/lib/data/default_projects.dart` (split one existing FBD demo into ≥2 networks to showcase ordering)
- Modify: `docs/` (a short FBD-networks note; ensure `docs/DEFERRED.md`'s FBD section is accurate)
- Test: adjust any default-project-shape test that counts FBD structure

- [ ] **Step 1:** Pick one FBD demo (e.g. the HVAC or water-quality FBD) and split its blocks across 2 networks with comments, proving multi-network authoring + ordering in a shipped demo. Assign `network` indices + `fbdNetworks`. Keep its behavior equivalent (same tags/outputs).
- [ ] **Step 2:** Full validation: `cd mobile && flutter analyze` (zero), `cd mobile && flutter test` (ALL pass — record count), `cd mobile && flutter build web --release` (succeeds).
- [ ] **Step 3:** Update docs: a short "FBD networks" section (how lanes/ordering/online work) and confirm the `docs/DEFERRED.md` FBD rows (EN/ENO, jumps/returns, custom FBs, cross-network wiring) are still accurate; strike nothing (none shipped here).
- [ ] **Step 4: Commit** — `feat(fbd): multi-network demo + docs; validation`.

---

## Self-Review

**Spec coverage:** §1 model+migration → Task 1. §2 execution semantics → Task 2. §3 editor UX (lanes + network CRUD) → Tasks 3 (logic) + 4 (UI); naming → Task 5; block network-reassignment + wire pruning → Tasks 3+5. §4 live overlay → Task 2 (monitor) + Task 6 (editor). §5 readability (lanes+naming+overlay) → emergent across 4-6; testing folded per task; backward-compat asserted in Tasks 1-2; demo+docs → Task 7. Deferred → `docs/DEFERRED.md` (Task 7 confirms). All spec sections map to a task.

**Placeholder scan:** Tasks 1-3 (model/exec/helpers) carry complete code + concrete tests. Tasks 4-6 (UI) specify an exact widget contract (keys, behaviors, responsive bounds), the Task-3 helpers they consume, the existing files/patterns to mirror (LD/SFC online overlay, existing block-card/wire widgets), and the exact widget tests as the oracle — the established approach for this repo's editor work, not vague hand-waving. No "TBD"/"add error handling" placeholders.

**Type consistency:** `FbdBlock.network` / `FbdNetwork` / `PlcProgram.fbdNetworks` (Task 1) are consumed unchanged in Tasks 2-6. `FbdMonitor` + `keyFor` (Task 2) match the editor's reads (Task 6) and the scan wiring. `fbd_networks.dart` helper names (`addFbdNetwork`/`moveFbdNetwork`/`deleteFbdNetwork`/`setBlockNetwork`/`fbdBlocksInNetwork`/`pruneCrossNetworkWires`, Task 3) match their call sites in Tasks 4-5. `executeFbdPrograms(..., monitor:)` matches the scan_tick call and the Task-2 test. `autoArrangeFbdNetwork` (Task 4) is introduced and consumed within Task 4.
