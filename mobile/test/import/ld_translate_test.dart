import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/ld_translate.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

IrGraphNode _n(int id, String type, {double x = 0, double y = 0, Map<String, String>? a}) =>
    IrGraphNode(localId: id, elementType: type, x: x, y: y, attributes: a ?? const {});
IrConnection _c(int to, int from, {String? toPin}) =>
    IrConnection(toLocalId: to, fromLocalId: from, toPin: toPin);

void mainTask2() {
  group('segmentRungs', () {
    test('two independent rungs -> two components, ordered by y', () {
      // Rung A (y=10): L -> contact1 -> coil2 -> R ; Rung B (y=50): L -> contact3 -> coil4 -> R
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(3, 'contact', y: 50, a: {'variable': 'B'}), _n(4, 'coil', y: 50, a: {'variable': 'D'}),
        _n(1, 'contact', y: 10, a: {'variable': 'A'}), _n(2, 'coil', y: 10, a: {'variable': 'C'}),
      ], connections: [
        _c(1, 100), _c(2, 1), _c(200, 2),
        _c(3, 100), _c(4, 3), _c(200, 4),
      ]);
      final comps = segmentRungs(body);
      expect(comps, hasLength(2));
      // Ordered by min y: the A/C rung (y=10) first.
      expect(comps[0].nodes.map((n) => n.localId).toSet(), {1, 2});
      expect(comps[1].nodes.map((n) => n.localId).toSet(), {3, 4});
      expect(comps[0].leftRailNodeIds, contains(1));
      expect(comps[0].rightRailNodeIds, contains(2));
    });

    test('shared series path feeding two coils -> one component', () {
      // L -> A -> B -> {C, D}
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'contact', a: {'variable': 'A'}), _n(2, 'contact', a: {'variable': 'B'}),
        _n(3, 'coil', a: {'variable': 'C'}), _n(4, 'coil', a: {'variable': 'D'}),
      ], connections: [
        _c(1, 100), _c(2, 1), _c(3, 2), _c(4, 2), _c(200, 3), _c(200, 4),
      ]);
      final comps = segmentRungs(body);
      expect(comps, hasLength(1));
      expect(comps[0].nodes.map((n) => n.localId).toSet(), {1, 2, 3, 4});
    });
  });
}

void mainTask3() {
  LdTranslation t(GraphBody b) => translateLdBody(b, pouName: 'P');

  group('translateLdBody boolean', () {
    test('single series rung: L-[A]-[B]-(C)-R', () {
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'contact', a: {'variable': 'A'}),
        _n(2, 'contact', a: {'variable': 'B', 'negated': 'true'}),
        _n(3, 'coil', a: {'variable': 'C'}),
      ], connections: [_c(1, 100), _c(2, 1), _c(3, 2), _c(200, 3)]);
      final r = t(body);
      expect(r.translatedRungCount, 1);
      expect(r.stubbedRungCount, 0);
      final rung = r.rungs.single;
      // main line has A, B, C (plus rails L/R added by buildRung).
      final contacts = rung.nodes.where((n) => n.kind == LdKind.contact).toList();
      expect(contacts.map((n) => n.variable), containsAll(['A', 'B']));
      expect(contacts.firstWhere((n) => n.variable == 'B').modifier, 'negated');
      expect(rung.nodes.where((n) => n.kind == LdKind.coil).single.variable, 'C');
      expect(rung.nodes.any((n) => n.kind == LdKind.leftRail), isTrue);
    });

    test('parallel contacts A||B feeding one coil -> one branch lane', () {
      // L->A->C(coil); L->B->C : A and B are parallel into the coil.
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'contact', y: 0, a: {'variable': 'A'}),
        _n(2, 'contact', y: 20, a: {'variable': 'B'}),
        _n(3, 'coil', a: {'variable': 'C'}),
      ], connections: [_c(1, 100), _c(2, 100), _c(3, 1), _c(3, 2), _c(200, 3)]);
      final r = t(body);
      expect(r.translatedRungCount, 1);
      final rung = r.rungs.single;
      // One node on a branch lane (row > 0).
      expect(rung.nodes.where((n) => n.row > 0).length, 1);
      expect(rung.nodes.where((n) => n.kind == LdKind.contact).map((n) => n.variable),
          containsAll(['A', 'B']));
    });

    test('a contact in series with a supported block now translates (Task 4)', () {
      // L-[A]-[TON]-(C)-R. Task 4 translates function blocks, so this rung is
      // no longer stubbed: the TON sits on the main line after contact A.
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'contact', a: {'variable': 'A'}),
        _n(2, 'block', a: {'typeName': 'TON'}),
        _n(3, 'coil', a: {'variable': 'C'}),
      ], connections: [_c(1, 100), _c(2, 1), _c(3, 2), _c(200, 3)]);
      final r = t(body);
      expect(r.translatedRungCount, 1);
      expect(r.stubbedRungCount, 0);
      final rung = r.rungs.single;
      expect(rung.nodes.firstWhere((n) => n.kind == LdKind.block).blockType, 'TON');
      expect(rung.nodes.any((n) => n.kind == LdKind.contact && n.variable == 'A'), isTrue);
    });

    test('component with no coil stubs', () {
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'contact', a: {'variable': 'A'}),
      ], connections: [_c(1, 100)]);
      final r = t(body);
      expect(r.stubbedRungCount, 1);
      expect(r.stubReasons['no-coil'], 1);
    });

    test('unsupported negated+edge modifier combo stubs', () {
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'contact', a: {'variable': 'A', 'negated': 'true', 'edge': 'rising'}),
        _n(2, 'coil', a: {'variable': 'C'}),
      ], connections: [_c(1, 100), _c(2, 1), _c(200, 2)]);
      final r = t(body);
      expect(r.stubbedRungCount, 1);
      expect(r.stubReasons['unsupported-modifier-combo'], 1);
    });

    test('bypass-short topology (A->OUT jumper) stubs, not mis-translated', () {
      // L-[A]-[B]-(OUT) plus a bypass jumper A->OUT. Faithful: OUT = A.
      // A greedy pure-series emit would drop A->OUT and compute OUT = A AND B.
      // The edge-coverage gate must reject this as complex-topology.
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'contact', a: {'variable': 'A'}),
        _n(2, 'contact', a: {'variable': 'B'}),
        _n(3, 'coil', a: {'variable': 'OUT'}),
      ], connections: [
        _c(1, 100), _c(2, 1), _c(3, 2), _c(200, 3),
        _c(3, 1), // bypass jumper A -> OUT
      ]);
      final r = t(body);
      expect(r.translatedRungCount, 0);
      expect(r.stubbedRungCount, 1);
      expect(r.stubReasons['complex-topology'], 1);
    });

    test('bridge (non-series-parallel) topology stubs, not mis-translated', () {
      // Edges A->B, A->Z, B->Z, B->OUT, Z->OUT. Faithful: OUT = A AND (B OR Z).
      // Greedy pure-series A-B-Z-OUT would compute OUT = A AND B AND Z.
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'contact', a: {'variable': 'A'}),
        _n(2, 'contact', a: {'variable': 'B'}),
        _n(3, 'contact', a: {'variable': 'Z'}),
        _n(4, 'coil', a: {'variable': 'OUT'}),
      ], connections: [
        _c(1, 100), // L -> A
        _c(2, 1), // A -> B
        _c(3, 1), // A -> Z
        _c(3, 2), // B -> Z
        _c(4, 2), // B -> OUT
        _c(4, 3), // Z -> OUT
        _c(200, 4), // OUT -> R
      ]);
      final r = t(body);
      expect(r.translatedRungCount, 0);
      expect(r.stubbedRungCount, 1);
      expect(r.stubReasons['complex-topology'], 1);
    });

    test('legit series + single-level parallel still translates (gate does not over-stub)', () {
      // L-[A]-([B] || [D])-(C): C = A AND (B OR D). A valid series-parallel
      // ladder the edge-coverage gate must NOT stub.
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'contact', a: {'variable': 'A'}),
        _n(2, 'contact', y: 0, a: {'variable': 'B'}),
        _n(3, 'contact', y: 20, a: {'variable': 'D'}),
        _n(4, 'coil', a: {'variable': 'C'}),
      ], connections: [
        _c(1, 100), // L -> A
        _c(2, 1), // A -> B
        _c(3, 1), // A -> D
        _c(4, 2), // B -> C
        _c(4, 3), // D -> C
        _c(200, 4), // C -> R
      ]);
      final r = t(body);
      expect(r.translatedRungCount, 1);
      expect(r.stubbedRungCount, 0);
      // One node on a branch lane (row > 0): the parallel D.
      final rung = r.rungs.single;
      expect(rung.nodes.where((n) => n.row > 0).length, 1);
    });
  });
}

void mainTask4() {
  LdTranslation t(GraphBody b) => translateLdBody(b, pouName: 'P');

  group('translateLdBody function blocks', () {
    test('TON block: PT inVariable folds to presetMs, instance tag TIMER, sits on main', () {
      // L-[TON]-(Q)-R with PT <- inVariable T#5s.
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'block', a: {'typeName': 'TON', 'instanceName': 'MyTimer'}),
        _n(2, 'coil', a: {'variable': 'Q'}),
        _n(3, 'inVariable', a: {'variable': 'T#5s'}),
      ], connections: [
        _c(1, 100), // L -> TON (IN power)
        _c(2, 1), // TON -> coil
        _c(200, 2), // coil -> R
        _c(1, 3, toPin: 'PT'), // inVar -> TON.PT (data, folded)
      ]);
      final r = t(body);
      expect(r.translatedRungCount, 1);
      expect(r.stubbedRungCount, 0);
      final blk = r.rungs.single.nodes.firstWhere((n) => n.kind == LdKind.block);
      expect(blk.blockType, 'TON');
      expect(blk.presetMs, 5000);
      expect(blk.variable, 'MyTimer');
      final tag = r.instanceTags.single;
      expect(tag.dataType, 'TIMER');
      expect(tag.name, 'MyTimer');
    });

    test('CTU block: PV literal folds to presetMs, instance tag COUNTER', () {
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'block', a: {'typeName': 'CTU', 'instanceName': 'Cnt'}),
        _n(2, 'coil', a: {'variable': 'Done'}),
        _n(3, 'inVariable', a: {'variable': '10'}),
      ], connections: [
        _c(1, 100), _c(2, 1), _c(200, 2), _c(1, 3, toPin: 'PV'),
      ]);
      final r = t(body);
      expect(r.translatedRungCount, 1);
      final blk = r.rungs.single.nodes.firstWhere((n) => n.kind == LdKind.block);
      expect(blk.blockType, 'CTU');
      expect(blk.presetMs, 10);
      expect(r.instanceTags.single.dataType, 'COUNTER');
    });

    test('GT compare block: IN1/IN2 inVariables fold to operandA/operandB', () {
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'block', a: {'typeName': 'GT'}),
        _n(2, 'coil', a: {'variable': 'Fast'}),
        _n(3, 'inVariable', a: {'variable': 'Speed'}),
        _n(4, 'inVariable', a: {'variable': '100'}),
      ], connections: [
        _c(1, 100), _c(2, 1), _c(200, 2),
        _c(1, 3, toPin: 'IN1'), _c(1, 4, toPin: 'IN2'),
      ]);
      final r = t(body);
      expect(r.translatedRungCount, 1);
      final blk = r.rungs.single.nodes.firstWhere((n) => n.kind == LdKind.block);
      expect(blk.blockType, 'GT');
      expect(blk.operandA, 'Speed');
      expect(blk.operandB, '100');
      expect(r.instanceTags, isEmpty);
    });

    test('MOVE block: IN source folds to operandA, outVariable to destination variable', () {
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'block', a: {'typeName': 'MOVE'}),
        _n(2, 'inVariable', a: {'variable': 'Src'}),
        _n(3, 'outVariable', a: {'variable': 'Dst'}),
      ], connections: [
        _c(1, 100), // L -> MOVE (EN power)
        _c(200, 1), // MOVE -> R (ENO power)
        _c(1, 2, toPin: 'IN'), // inVar -> MOVE.IN (data)
        _c(3, 1), // MOVE -> outVar (destination, folded)
      ]);
      final r = t(body);
      expect(r.translatedRungCount, 1);
      final blk = r.rungs.single.nodes.firstWhere((n) => n.kind == LdKind.block);
      expect(blk.blockType, 'MOVE');
      expect(blk.operandA, 'Src');
      expect(blk.variable, 'Dst');
    });

    test('unsupported block type stubs and is recorded in unsupportedBlockTypes', () {
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'contact', a: {'variable': 'A'}),
        _n(2, 'block', a: {'typeName': 'FANCYFB'}),
        _n(3, 'coil', a: {'variable': 'C'}),
      ], connections: [_c(1, 100), _c(2, 1), _c(3, 2), _c(200, 3)]);
      final r = t(body);
      expect(r.translatedRungCount, 0);
      expect(r.stubbedRungCount, 1);
      expect(r.stubReasons['unsupported-block'], 1);
      expect(r.unsupportedBlockTypes, contains('FANCYFB'));
    });

    test('unparseable timer preset stubs as unresolved-operand', () {
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'block', a: {'typeName': 'TON', 'instanceName': 'Bad'}),
        _n(2, 'coil', a: {'variable': 'Q'}),
        _n(3, 'inVariable', a: {'variable': 'notaduration'}),
      ], connections: [
        _c(1, 100), _c(2, 1), _c(200, 2), _c(1, 3, toPin: 'PT'),
      ]);
      final r = t(body);
      expect(r.translatedRungCount, 0);
      expect(r.stubReasons['unresolved-operand'], 1);
    });

    test('block rung that stubs at the faithfulness gate leaks no instance tag', () {
      // L-[A]-[TON]-(C)-R PLUS a power bridge A->C. The TON maps (appending its
      // TIMER instance tag) but the bridge edge makes the reduced power wiring
      // non-series-parallel, so the faithfulness gate stubs the rung. The
      // instance tag must NOT leak: it backs no translated block.
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'contact', a: {'variable': 'A'}),
        _n(2, 'block', a: {'typeName': 'TON', 'instanceName': 'Leak'}),
        _n(3, 'coil', a: {'variable': 'C'}),
      ], connections: [
        _c(1, 100), // L -> A
        _c(2, 1), // A -> TON
        _c(3, 2), // TON -> C
        _c(200, 3), // C -> R
        _c(3, 1), // bridge A -> C
      ]);
      final r = t(body);
      expect(r.translatedRungCount, 0);
      expect(r.stubbedRungCount, 1);
      expect(r.stubReasons['complex-topology'], 1);
      expect(r.instanceTags, isEmpty); // no orphan TIMER tag
    });

    test('ADD block: IN1/IN2 inVariables fold to operands, outVariable to variable', () {
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'block', a: {'typeName': 'ADD'}),
        _n(2, 'inVariable', a: {'variable': 'X'}),
        _n(3, 'inVariable', a: {'variable': '5'}),
        _n(4, 'outVariable', a: {'variable': 'Sum'}),
      ], connections: [
        _c(1, 100), // L -> ADD (EN power)
        _c(200, 1), // ADD -> R (ENO power)
        _c(1, 2, toPin: 'IN1'), // X -> ADD.IN1 (data)
        _c(1, 3, toPin: 'IN2'), // 5 -> ADD.IN2 (data)
        _c(4, 1), // ADD -> outVar Sum (destination, folded)
      ]);
      final r = t(body);
      expect(r.translatedRungCount, 1);
      final blk = r.rungs.single.nodes.firstWhere((n) => n.kind == LdKind.block);
      expect(blk.blockType, 'ADD');
      expect(blk.operandA, 'X');
      expect(blk.operandB, '5');
      expect(blk.variable, 'Sum');
    });
  });
}

// Power-pin fold/stub fix: the app's native LD block model drives a
// timer/counter from a SINGLE primary power input (count pin for counters, IN
// for timers). Separate CD/R/LD power pins — and value variables feeding a
// power pin — cannot be represented, so such rungs must STUB, never
// mistranslate.
void mainLdPowerPinFix() {
  LdTranslation t(GraphBody b) => translateLdBody(b, pouName: 'P');

  group('translateLdBody power-pin faithfulness', () {
    test('F1: CTU with R (reset) fed by an inVariable stubs (value var -> power pin)', () {
      // L-[Count]-[CTU]-(Done)-R, PV<-inVar 2, R<-inVar ResetSig. The R pin is a
      // POWER pin the block model cannot drive from a value variable; folding it
      // away would silently drop the reset -> stub instead.
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'block', a: {'typeName': 'CTU', 'instanceName': 'Cnt'}),
        _n(2, 'coil', a: {'variable': 'Done'}),
        _n(5, 'contact', a: {'variable': 'Count'}),
        _n(3, 'inVariable', a: {'variable': '2'}),
        _n(4, 'inVariable', a: {'variable': 'ResetSig'}),
      ], connections: [
        _c(5, 100), // L -> Count
        _c(1, 5), // Count -> CTU (CU primary power)
        _c(2, 1), // CTU -> Done
        _c(200, 2), // Done -> R rail
        _c(1, 3, toPin: 'PV'), // inVar 2 -> CTU.PV (data, folds)
        _c(1, 4, toPin: 'R'), // inVar ResetSig -> CTU.R (POWER pin!)
      ]);
      final r = t(body);
      expect(r.translatedRungCount, 0);
      expect(r.stubbedRungCount, 1);
      expect(r.stubReasons['complex-topology'], greaterThanOrEqualTo(1));
      expect(r.instanceTags, isEmpty); // no orphan COUNTER tag
    });

    test('T4a: CTUD with CD (down-count) fed by a contact stubs (unsupported power pin)', () {
      // L-[Up]-[CTUD]-(Q)-R, PV<-inVar 5, and L-[Down]->CTUD.CD. CD is a power
      // pin the block model cannot represent -> stub, not a silent operandA="".
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'block', a: {'typeName': 'CTUD', 'instanceName': 'Cud'}),
        _n(2, 'coil', a: {'variable': 'Q'}),
        _n(5, 'contact', a: {'variable': 'Up'}),
        _n(3, 'contact', a: {'variable': 'Down'}),
        _n(4, 'inVariable', a: {'variable': '5'}),
      ], connections: [
        _c(5, 100), // L -> Up
        _c(1, 5), // Up -> CTUD (CU primary power)
        _c(2, 1), // CTUD -> Q
        _c(200, 2), // Q -> R rail
        _c(3, 100), // L -> Down
        _c(1, 3, toPin: 'CD'), // Down -> CTUD.CD (POWER pin!)
        _c(1, 4, toPin: 'PV'), // inVar 5 -> CTUD.PV (data, folds)
      ]);
      final r = t(body);
      expect(r.translatedRungCount, 0);
      expect(r.stubbedRungCount, 1);
      expect(r.stubReasons['complex-topology'], greaterThanOrEqualTo(1));
      expect(r.instanceTags, isEmpty);
    });

    test('positive: plain CTU (single CU count + PV data + coil) still translates', () {
      // L-[Count]-[CTU]-(Done)-R, PV<-inVar 2. The count power is the single
      // supported primary pin, so this MUST still translate after the fix.
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        _n(1, 'block', a: {'typeName': 'CTU', 'instanceName': 'Cnt'}),
        _n(2, 'coil', a: {'variable': 'Done'}),
        _n(5, 'contact', a: {'variable': 'Count'}),
        _n(3, 'inVariable', a: {'variable': '2'}),
      ], connections: [
        _c(5, 100), _c(1, 5), _c(2, 1), _c(200, 2), _c(1, 3, toPin: 'PV'),
      ]);
      final r = t(body);
      expect(r.translatedRungCount, 1);
      expect(r.stubbedRungCount, 0);
      final blk = r.rungs.single.nodes.firstWhere((n) => n.kind == LdKind.block);
      expect(blk.blockType, 'CTU');
      expect(blk.presetMs, 2);
      expect(r.instanceTags.single.dataType, 'COUNTER');
    });

    test('T4b: a stubbed timer/counter instance name is reusable by a later translated rung', () {
      // Rung1 (y=0): L-[A]-[TON "Shared"]-(C)-R PLUS bridge A->C -> maps the
      // block (reserving "Shared" locally) then STUBS at the faithfulness gate,
      // so the name is discarded. Rung2 (y=100): plain TON "Shared" translates
      // and must get "Shared" (not "Shared_2") — dedup didn't permanently
      // consume the discarded name.
      final body = GraphBody(nodes: [
        _n(100, 'leftPowerRail'), _n(200, 'rightPowerRail'),
        // Rung 1 (stubs at the gate via the bridge)
        _n(1, 'contact', y: 0, a: {'variable': 'A'}),
        _n(2, 'block', y: 0, a: {'typeName': 'TON', 'instanceName': 'Shared'}),
        _n(3, 'coil', y: 0, a: {'variable': 'C'}),
        _n(4, 'inVariable', y: 0, a: {'variable': 'T#1s'}),
        // Rung 2 (translates)
        _n(11, 'block', y: 100, a: {'typeName': 'TON', 'instanceName': 'Shared'}),
        _n(12, 'coil', y: 100, a: {'variable': 'D'}),
        _n(13, 'inVariable', y: 100, a: {'variable': 'T#2s'}),
      ], connections: [
        // Rung 1: L->A->TON->C->R plus bridge A->C
        _c(1, 100), _c(2, 1), _c(3, 2), _c(200, 3), _c(3, 1),
        _c(2, 4, toPin: 'PT'),
        // Rung 2: L->TON->D->R
        _c(11, 100), _c(12, 11), _c(200, 12), _c(11, 13, toPin: 'PT'),
      ]);
      final r = t(body);
      expect(r.translatedRungCount, 1);
      expect(r.stubbedRungCount, 1);
      // The one translated instance tag reuses the discarded name.
      expect(r.instanceTags, hasLength(1));
      expect(r.instanceTags.single.name, 'Shared');
      final translatedBlock = r.rungs
          .expand((rung) => rung.nodes)
          .firstWhere((n) => n.kind == LdKind.block);
      expect(translatedBlock.variable, 'Shared');
    });
  });
}

void main() {
  group('parseIecDuration', () {
    test('parses seconds, ms, minutes, compound, and TIME# prefix', () {
      expect(parseIecDuration('T#5s'), 5000);
      expect(parseIecDuration('T#500ms'), 500);
      expect(parseIecDuration('T#2m'), 120000);
      expect(parseIecDuration('T#1m30s'), 90000);
      expect(parseIecDuration('T#1.5s'), 1500);
      expect(parseIecDuration('TIME#250ms'), 250);
      expect(parseIecDuration('t#3h'), 10800000);
    });
    test('returns null for non-durations', () {
      expect(parseIecDuration('hello'), isNull);
      expect(parseIecDuration('5'), isNull);
      expect(parseIecDuration(''), isNull);
    });
  });

  mainTask2();
  mainTask3();
  mainTask4();
  mainLdPowerPinFix();
}
