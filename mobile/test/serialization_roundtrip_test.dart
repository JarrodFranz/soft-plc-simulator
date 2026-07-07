import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/ld_graph.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/fbd_exec.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';
import 'package:soft_plc_mobile/models/st_exec.dart';

// One full scan tick, exactly as the shell runs it.
void _scan(PlcProject p, SimRuntime sim, LdExecRuntime ld, FbdRuntime fbd,
    SfcRuntime sfc, StRuntime st, [int dtMs = 500]) {
  applySimRules(p, p.simRules, dtMs, sim);
  executeLdPrograms(p, dtMs, ld);
  executeFbdPrograms(p, dtMs, fbd);
  executeSfcPrograms(p, dtMs, sfc);
  executeStPrograms(p, dtMs, st);
}

// A dependency-free snapshot of every tag's observable state.
String _snapshot(PlcProject p) => jsonEncode([
      for (final t in p.tags)
        {'n': t.name, 'v': t.value, 'f': t.isForced, 'fv': t.forcedValue}
    ]);

PlcProject _roundTrip(PlcProject p) =>
    PlcProject.fromJson(jsonDecode(jsonEncode(p.toJson())));

void main() {
  test('LdNode operand fields round-trip and are omitted when empty', () {
    final bare = LdNode(id: 'n1', kind: LdKind.contact, variable: 'A');
    expect(bare.toJson().containsKey('operand_a'), isFalse); // additive: absent when empty
    final data = LdNode(id: 'n2', kind: LdKind.block, blockType: 'GT', operandA: 'Level', operandB: '80');
    final j = data.toJson();
    expect(j['operand_a'], 'Level');
    expect(j['operand_b'], '80');
    final back = LdNode.fromJson(j);
    expect(back.operandA, 'Level');
    expect(back.operandB, '80');
    // legacy JSON without the keys still loads
    final legacy = LdNode.fromJson({'id': 'n3', 'kind': 'block', 'block_type': 'TON', 'preset_ms': 3000});
    expect(legacy.operandA, '');
  });

  test('a link (empty branch) round-trips', () {
    final rung = buildRung(index: 0, main: [
      LdNode(id: '', kind: LdKind.contact, variable: 'A'),
      LdNode(id: '', kind: LdKind.coil, variable: 'Q'),
    ]);
    addEmptyBranch(rung, kLeftRailId, 'm1');
    final prog = PlcProgram(name: 'P', language: 'LadderLogic', rungs: [rung]);
    final back = PlcProgram.fromJson(prog.toJson());
    final r = back.rungs.single;
    expect(r.nodes.any((n) => n.kind == LdKind.link), isTrue);
    expect(r.wires.length, rung.wires.length);
  });

  test('WS21: full-block round-trip — TP/CTU/CTD/CTUD/GT/ADD/MOVE + stacked coil', () {
    // Build a rung containing one node of each new block type, with
    // realistic operandA/operandB/variable/presetMs, via buildRung so the
    // main-line wiring (rail -> ... -> rail) matches what the editor emits.
    final rung = buildRung(
      index: 0,
      comment: 'WS21 block coverage',
      main: [
        LdNode(id: '', kind: LdKind.contact, variable: 'Start_PB'),
        LdNode(
          id: '',
          kind: LdKind.block,
          blockType: 'TP',
          variable: 'Pulse1',
          presetMs: 1500,
        ),
        LdNode(
          id: '',
          kind: LdKind.block,
          blockType: 'CTU',
          variable: 'Count1',
          presetMs: 10,
        ),
        LdNode(
          id: '',
          kind: LdKind.block,
          blockType: 'CTD',
          variable: 'Count2',
          presetMs: 5,
        ),
        LdNode(
          id: '',
          kind: LdKind.block,
          blockType: 'CTUD',
          variable: 'Count3',
          presetMs: 20,
        ),
        LdNode(
          id: '',
          kind: LdKind.block,
          blockType: 'GT',
          operandA: 'Level',
          operandB: '80',
        ),
        LdNode(
          id: '',
          kind: LdKind.block,
          blockType: 'ADD',
          operandA: 'Total',
          operandB: 'Increment',
        ),
        LdNode(
          id: '',
          kind: LdKind.block,
          blockType: 'MOVE',
          operandA: 'Source_Tag',
          operandB: 'Dest_Tag',
        ),
      ],
    );
    // Add a stacked output coil on its own lane, as the editor does via
    // the "+" affordance in ld_editor_screen.dart.
    final coil = addOutputCoil(rung);
    coil.variable = 'Run_Lamp';

    final program = PlcProgram(
      name: 'WS21_Coverage',
      language: 'LadderLogic',
      rungs: [rung],
    );
    final original = PlcProject(
      id: 'ws21_roundtrip',
      name: 'WS21 Round-Trip Fixture',
      controllerName: 'PLC_TEST',
      tags: [],
      structDefs: [],
      programs: [program],
      tasks: [],
      hmis: [],
    );

    final restored = _roundTrip(original);

    expect(restored.programs.length, 1);
    final rA = original.programs[0].rungs[0];
    final rB = restored.programs[0].rungs[0];

    // Lane structure: every node's row must survive, keyed by id (order is
    // stable but keying by id makes the assertion resilient to any future
    // reordering during (de)serialization).
    final nodesA = {for (final n in rA.nodes) n.id: n};
    final nodesB = {for (final n in rB.nodes) n.id: n};
    expect(nodesB.keys.toSet(), nodesA.keys.toSet(),
        reason: 'node ids must be preserved 1:1');

    for (final id in nodesA.keys) {
      final a = nodesA[id]!;
      final b = nodesB[id]!;
      expect(b.kind, a.kind, reason: 'node $id kind');
      expect(b.blockType, a.blockType, reason: 'node $id blockType');
      expect(b.variable, a.variable, reason: 'node $id variable');
      expect(b.presetMs, a.presetMs, reason: 'node $id presetMs');
      expect(b.operandA, a.operandA, reason: 'node $id operandA');
      expect(b.operandB, a.operandB, reason: 'node $id operandB');
      expect(b.row, a.row, reason: 'node $id row (lane)');
    }

    // Confirm every new block type actually made it through, so this
    // assertion isn't a tautology against an empty/degenerate rung.
    final blockTypesB =
        nodesB.values.map((n) => n.blockType).where((t) => t.isNotEmpty).toSet();
    expect(blockTypesB, {'TP', 'CTU', 'CTD', 'CTUD', 'GT', 'ADD', 'MOVE'});

    // Stacked coil landed on its own lane (> 0), separate from the main line.
    final coilB = nodesB.values.firstWhere((n) => n.variable == 'Run_Lamp');
    expect(coilB.kind, LdKind.coil);
    expect(coilB.row, greaterThan(0));
    expect(coilB.row, coil.row);

    // Wires: exact (fromId, toId) pair set must match, including the
    // stacked coil's left-rail -> coil -> right-rail wiring.
    String wireKey(LdWire w) => '${w.fromId}->${w.toId}';
    final wiresA = rA.wires.map(wireKey).toSet();
    final wiresB = rB.wires.map(wireKey).toSet();
    expect(wiresB, wiresA, reason: 'wire set must be preserved exactly');
    expect(rB.wires.length, rA.wires.length,
        reason: 'no wires duplicated or dropped');

    // Sanity: the coil's rail-to-rail wires are actually present.
    expect(wiresB.contains('$kLeftRailId->${coil.id}'), isTrue);
    expect(wiresB.contains('${coil.id}->$kRightRailId'), isTrue);
  });

  for (final original in DefaultProjects.all()) {
    group('round-trip ${original.id}', () {
      test('structural: collections and struct defs are preserved', () {
        final p2 = _roundTrip(original);
        expect(p2.id, original.id);
        expect(p2.tags.length, original.tags.length);
        expect(p2.structDefs.length, original.structDefs.length,
            reason: 'struct defs must survive serialization');
        expect(p2.programs.length, original.programs.length);
        expect(p2.tasks.length, original.tasks.length);
        expect(p2.hmis.length, original.hmis.length);
        expect(p2.simRules.length, original.simRules.length);
        for (var i = 0; i < original.programs.length; i++) {
          final a = original.programs[i], b = p2.programs[i];
          expect(b.rungs.length, a.rungs.length, reason: '${a.name} LD rungs');
          expect(b.fbdBlocks.length, a.fbdBlocks.length, reason: '${a.name} FBD blocks');
          expect(b.fbdWires.length, a.fbdWires.length, reason: '${a.name} FBD wires');
          expect(b.sfcSteps.length, a.sfcSteps.length, reason: '${a.name} SFC steps');
          expect(b.sfcTransitions.length, a.sfcTransitions.length, reason: '${a.name} SFC transitions');
          expect(b.stSource, a.stSource);
        }
      });

      test('idempotent: toJson == toJson after a round-trip', () {
        final p2 = _roundTrip(original);
        expect(jsonEncode(p2.toJson()), jsonEncode(original.toJson()));
      });

      test('scan-equivalence: 20 scans identical to a fresh copy', () {
        final a = original;
        final b = _roundTrip(original);
        final aRt = (SimRuntime(), LdExecRuntime(), FbdRuntime(), SfcRuntime(), StRuntime());
        final bRt = (SimRuntime(), LdExecRuntime(), FbdRuntime(), SfcRuntime(), StRuntime());
        expect(_snapshot(a), _snapshot(b), reason: 'initial state must match');
        for (var i = 0; i < 20; i++) {
          _scan(a, aRt.$1, aRt.$2, aRt.$3, aRt.$4, aRt.$5);
          _scan(b, bRt.$1, bRt.$2, bRt.$3, bRt.$4, bRt.$5);
          expect(_snapshot(b), _snapshot(a),
              reason: 'scan $i diverged — serialization is lossy for ${original.id}');
        }
      });
    });
  }
}
