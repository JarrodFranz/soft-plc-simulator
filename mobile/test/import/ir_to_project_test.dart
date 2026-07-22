import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/import/ir_to_project.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

/// Builds a representative [ImportedProject] in-code so this test exercises
/// the mapper in isolation, independent of the parser/fixture.
ImportedProject _buildIr() {
  final motorType = ImportedType(name: 'MotorType', fields: [
    ImportedField(name: 'Running', baseType: 'BOOL'),
    ImportedField(name: 'Rpm', baseType: 'INT', initialValue: '1500'),
  ]);

  final tempPv = ImportedVar(
      name: 'Temp_PV', baseType: 'REAL', initialValue: '20.0', scope: VarScope.global);
  final enable = ImportedVar(
      name: 'Enable', baseType: 'BOOL', initialValue: 'TRUE', scope: VarScope.global);
  final retained = ImportedVar(
      name: 'Retained', baseType: 'LINT', scope: VarScope.global, retain: true);
  final inputVar = ImportedVar(name: 'In1', baseType: 'BOOL', scope: VarScope.input);
  final outputVar = ImportedVar(name: 'Out1', baseType: 'BOOL', scope: VarScope.output);
  final systemVar = ImportedVar(name: 'System', baseType: 'BOOL', scope: VarScope.global);
  final spaceVar = ImportedVar(name: 'My Tag', baseType: 'BOOL', scope: VarScope.global);

  final mainPou = ImportedPou(
    name: 'Main',
    kind: PouKind.program,
    lang: PouLanguage.st,
    localVars: const [],
    body: TextBody('Count := Count + 1;'),
  );
  final rung1Pou = ImportedPou(
    name: 'Rung1',
    kind: PouKind.program,
    lang: PouLanguage.ld,
    localVars: const [],
    body: GraphBody(
      nodes: [IrGraphNode(localId: 1, elementType: 'contact')],
      connections: const [],
    ),
  );

  return ImportedProject(
    name: 'Imported',
    types: [motorType],
    globalVars: [tempPv, enable, retained, inputVar, outputVar, systemVar, spaceVar],
    pous: [mainPou, rung1Pou],
    warnings: const [],
  );
}

/// Builds an IR proving nested-DUT default resolution: `Outer` (declared
/// BEFORE its dependency `Inner` in `ir.types`, forcing `_orderTypes` to
/// reorder) has a struct-typed field `Sub: Inner` and `ArrOuter` has an
/// array-of-DUT field `Items: Inner[2]`. A global var typed `Outer` exercises
/// the var->tag path too.
ImportedProject _buildNestedIr() {
  final inner = ImportedType(name: 'Inner', fields: [
    ImportedField(name: 'Flag', baseType: 'BOOL'),
    ImportedField(name: 'Speed', baseType: 'INT', initialValue: '1500'),
  ]);
  final outer = ImportedType(name: 'Outer', fields: [
    ImportedField(name: 'Sub', baseType: 'Inner'),
    ImportedField(name: 'Count', baseType: 'INT'),
  ]);
  final arrOuter = ImportedType(name: 'ArrOuter', fields: [
    ImportedField(name: 'Items', baseType: 'Inner', arrayLength: 2),
  ]);
  final outerVar =
      ImportedVar(name: 'OuterVar', baseType: 'Outer', scope: VarScope.global);

  return ImportedProject(
    name: 'Imported',
    types: [outer, inner, arrOuter], // Outer BEFORE Inner: forces reordering.
    globalVars: [outerVar],
    pous: const [],
    warnings: const [],
  );
}

IrGraphNode _ldNode(int id, String type, {double x = 0, double y = 0, Map<String, String>? a}) =>
    IrGraphNode(localId: id, elementType: type, x: x, y: y, attributes: a ?? const {});
IrConnection _ldConn(int to, int from, {String? toPin}) =>
    IrConnection(toLocalId: to, fromLocalId: from, toPin: toPin);

/// An IR with two LD POUs: `GoodRung` (L -> [Start] -> [TON] -> (Motor) -> R)
/// translates fully (a real series rung with a timer block, producing a
/// backing TIMER instance tag), and `BadRung` (an unsupported PID block)
/// stubs entirely. Exercises Task 5's wiring end to end.
ImportedProject _buildLdIr() {
  final goodPou = ImportedPou(
    name: 'GoodRung',
    kind: PouKind.program,
    lang: PouLanguage.ld,
    localVars: const [],
    body: GraphBody(nodes: [
      _ldNode(100, 'leftPowerRail'), _ldNode(200, 'rightPowerRail'),
      _ldNode(1, 'contact', a: {'variable': 'Start'}),
      _ldNode(2, 'block', a: {'typeName': 'TON'}),
      _ldNode(3, 'coil', a: {'variable': 'Motor'}),
    ], connections: [
      _ldConn(1, 100), _ldConn(2, 1), _ldConn(3, 2), _ldConn(200, 3),
    ]),
  );
  final badPou = ImportedPou(
    name: 'BadRung',
    kind: PouKind.program,
    lang: PouLanguage.ld,
    localVars: const [],
    body: GraphBody(nodes: [
      _ldNode(100, 'leftPowerRail'), _ldNode(200, 'rightPowerRail'),
      _ldNode(1, 'block', a: {'typeName': 'PID'}),
      _ldNode(2, 'coil', a: {'variable': 'Out'}),
    ], connections: [
      _ldConn(1, 100), _ldConn(2, 1), _ldConn(200, 2),
    ]),
  );
  return ImportedProject(
    name: 'LdImport', types: const [], globalVars: const [],
    pous: [goodPou, badPou], warnings: const [],
  );
}

/// An IR proving the instance-rename-sync path (Task 5 follow-up): a global
/// var `Timer1` collides with an LD POU's TON instance also named `Timer1`
/// (forcing the instance tag to be renamed to `Timer1_1`), AND the same POU
/// has a second rung with a MOVE block whose destination is the timer's
/// ORIGINAL name `Timer1`. The rename must reach the TON block's `variable`
/// (so the running ladder still finds its backing TIMER tag) but must NOT
/// bleed onto the MOVE block's destination, which is a genuinely different
/// tag reference that happens to share the pre-rename name.
ImportedProject _buildRenameCollisionIr() {
  final timer1Var =
      ImportedVar(name: 'Timer1', baseType: 'BOOL', scope: VarScope.global);

  final tonRung = GraphBody(nodes: [
    _ldNode(100, 'leftPowerRail'), _ldNode(200, 'rightPowerRail'),
    _ldNode(1, 'contact', a: {'variable': 'Start'}),
    _ldNode(2, 'block', a: {'typeName': 'TON', 'instanceName': 'Timer1'}),
    _ldNode(3, 'coil', a: {'variable': 'Motor'}),
  ], connections: [
    _ldConn(1, 100), _ldConn(2, 1), _ldConn(3, 2), _ldConn(200, 3),
  ]);
  final moveRung = GraphBody(nodes: [
    _ldNode(300, 'leftPowerRail'), _ldNode(400, 'rightPowerRail'),
    _ldNode(4, 'block', a: {'typeName': 'MOVE'}),
    _ldNode(5, 'inVariable', a: {'variable': 'Src'}),
    _ldNode(6, 'outVariable', a: {'variable': 'Timer1'}),
  ], connections: [
    _ldConn(4, 300), // L -> MOVE (EN power)
    _ldConn(400, 4), // MOVE -> R (ENO power)
    _ldConn(4, 5, toPin: 'IN'), // inVar -> MOVE.IN (data)
    _ldConn(6, 4), // MOVE -> outVar (destination, folded)
  ]);
  final mixedPou = ImportedPou(
    name: 'MixedRung',
    kind: PouKind.program,
    lang: PouLanguage.ld,
    localVars: const [],
    body: GraphBody(
      nodes: [...tonRung.nodes, ...moveRung.nodes],
      connections: [...tonRung.connections, ...moveRung.connections],
    ),
  );

  return ImportedProject(
    name: 'RenameCollision',
    types: const [],
    globalVars: [timer1Var],
    pous: [mixedPou],
    warnings: const [],
  );
}

void main() {
  group('mapImportedProject: instance-rename sync (renamed timer + MOVE non-corruption)', () {
    test('a TON instance colliding with an existing tag gets renamed, and the '
        'rename is synced onto its own block node', () {
      final result =
          mapImportedProject(_buildRenameCollisionIr(), projectName: 'P', projectId: 'p1');
      final timerTags = result.project.tags.where((t) => t.dataType == 'TIMER').toList();
      expect(timerTags, hasLength(1));
      final renamedName = timerTags.single.name;
      expect(renamedName, 'Timer1_1'); // renamed away from the colliding 'Timer1'

      final program = result.project.programs.singleWhere((p) => p.name == 'MixedRung');
      final tonNode = program.rungs
          .expand((r) => r.nodes)
          .singleWhere((n) => n.kind == LdKind.block && n.blockType == 'TON');
      expect(tonNode.variable, renamedName);
    });

    test('Finding 1 fix: a MOVE block destination equal to the timer\'s ORIGINAL '
        'instance name is NOT rewritten by the rename-sync loop', () {
      final result =
          mapImportedProject(_buildRenameCollisionIr(), projectName: 'P', projectId: 'p1');
      final program = result.project.programs.singleWhere((p) => p.name == 'MixedRung');
      final moveNode = program.rungs
          .expand((r) => r.nodes)
          .singleWhere((n) => n.kind == LdKind.block && n.blockType == 'MOVE');
      // Must stay the original destination tag name — the timer's rename to
      // 'Timer1_1' must not bleed onto this unrelated MOVE destination.
      expect(moveNode.variable, 'Timer1');
    });
  });

  group('mapImportedProject: LD translation wiring (Task 5)', () {
    test('a translatable LD POU becomes a real LadderLogic program with rungs', () {
      final result = mapImportedProject(_buildLdIr(), projectName: 'P', projectId: 'p1');
      final good = result.project.programs.singleWhere((p) => p.name == 'GoodRung');
      expect(good.language, 'LadderLogic');
      expect(good.rungs, isNotEmpty);
      expect(
        good.rungs.single.nodes.any((n) => n.kind == LdKind.contact && n.variable == 'Start'),
        isTrue,
      );
      expect(
        good.rungs.single.nodes.any((n) => n.kind == LdKind.coil && n.variable == 'Motor'),
        isTrue,
      );
    });

    test('report aggregates translated/stubbed rung counts and unsupported block types', () {
      final result = mapImportedProject(_buildLdIr(), projectName: 'P', projectId: 'p1');
      expect(result.report.translatedRungCount, greaterThanOrEqualTo(1));
      expect(result.report.stubbedRungCount, greaterThanOrEqualTo(1));
      expect(result.report.unsupportedLdBlockTypes, contains('PID'));
      expect(result.report.ldStubReasons['unsupported-block'], greaterThanOrEqualTo(1));
    });

    test('a TON instance tag from the translated POU appears in project.tags', () {
      final result = mapImportedProject(_buildLdIr(), projectName: 'P', projectId: 'p1');
      final timerTags = result.project.tags.where((t) => t.dataType == 'TIMER').toList();
      expect(timerTags, isNotEmpty);
    });

    test('a fully-untranslatable LD POU still counts toward graphicalStubCount and stubs', () {
      final result = mapImportedProject(_buildLdIr(), projectName: 'P', projectId: 'p1');
      final bad = result.project.programs.singleWhere((p) => p.name == 'BadRung');
      expect(bad.language, 'LadderLogic');
      expect(bad.rungs, isEmpty);
      // Only BadRung stubs (GoodRung is a real program) -> exactly 1.
      expect(result.report.graphicalStubCount, 1);
    });
  });

  group('mapImportedProject: nested DUT defaults (incremental struct build)', () {
    test('struct-in-struct field defaults to a nested Map, not scalar 0', () {
      final result = mapImportedProject(_buildNestedIr(), projectName: 'P', projectId: 'p1');
      final outer = result.project.structDefs.singleWhere((s) => s.name == 'Outer');
      final sub = outer.fields.singleWhere((f) => f.name == 'Sub');
      expect(sub.dataType, 'Inner');
      expect(sub.defaultValue, {'Flag': false, 'Speed': 1500});
    });

    test('array-of-DUT field defaults to a List of proper nested Maps', () {
      final result = mapImportedProject(_buildNestedIr(), projectName: 'P', projectId: 'p1');
      final arrOuter = result.project.structDefs.singleWhere((s) => s.name == 'ArrOuter');
      final items = arrOuter.fields.singleWhere((f) => f.name == 'Items');
      expect(items.defaultValue, isA<List>());
      final list = items.defaultValue as List;
      expect(list.length, 2);
      for (final el in list) {
        expect(el, {'Flag': false, 'Speed': 1500});
      }
    });

    test('a global var typed as a nested-containing struct gets the correct nested value', () {
      final result = mapImportedProject(_buildNestedIr(), projectName: 'P', projectId: 'p1');
      final tag = result.project.tags.singleWhere((t) => t.name == 'OuterVar');
      expect(tag.value, isA<Map>());
      final value = tag.value as Map;
      expect(value['Sub'], isA<Map>());
      expect((value['Sub'] as Map)['Speed'], 1500);
      expect((value['Sub'] as Map)['Flag'], false);
      expect(value['Count'], 0);
    });
  });

  group('mapImportedProject: negative arrayLength scalar guard', () {
    test('a malformed negative arrayLength on a scalar var still gets a defaultValue', () {
      final v = ImportedVar(
          name: 'Weird', baseType: 'BOOL', arrayLength: -1,
          initialValue: 'TRUE', scope: VarScope.global);
      final ir = ImportedProject(
        name: 'Imported', types: const [], globalVars: [v], pous: const [],
        warnings: const [],
      );
      final result = mapImportedProject(ir, projectName: 'P', projectId: 'p1');
      final tag = result.project.tags.singleWhere((t) => t.name == 'Weird');
      expect(tag.value, true);
      expect(tag.defaultValue, true);
    });
  });

  group('mapImportedProject', () {
    late ImportedProject ir;
    setUp(() {
      ir = _buildIr();
    });

    test('maps structs with fields normalized + defaulted', () {
      final result = mapImportedProject(ir, projectName: 'MyProj', projectId: 'proj_1');
      expect(result.report.structCount, 1);
      final motor = result.project.structDefs.singleWhere((s) => s.name == 'MotorType');
      final running = motor.fields.singleWhere((f) => f.name == 'Running');
      expect(running.dataType, 'BOOL');
      expect(running.defaultValue, false);
      final rpm = motor.fields.singleWhere((f) => f.name == 'Rpm');
      expect(rpm.dataType, 'INT16');
      expect(rpm.defaultValue, 1500);
    });

    test('maps global vars to tags with type/scope/retain/default', () {
      final result = mapImportedProject(ir, projectName: 'MyProj', projectId: 'proj_1');
      final tags = result.project.tags;

      final tempPv = tags.singleWhere((t) => t.name == 'Temp_PV');
      expect(tempPv.dataType, 'FLOAT64');
      expect(tempPv.defaultValue, 20.0);
      expect(tempPv.value, tempPv.defaultValue);
      expect(tempPv.ioType, 'Internal');

      final enable = tags.singleWhere((t) => t.name == 'Enable');
      expect(enable.dataType, 'BOOL');
      expect(enable.defaultValue, true);
      expect(enable.value, enable.defaultValue);

      final retained = tags.singleWhere((t) => t.name == 'Retained');
      expect(retained.dataType, 'INT64');
      expect(retained.retentive, true);
      expect(retained.value, retained.defaultValue);
    });

    test('scope input/output maps to SimulatedInput/SimulatedOutput ioType', () {
      final result = mapImportedProject(ir, projectName: 'MyProj', projectId: 'proj_1');
      final tags = result.project.tags;
      expect(tags.singleWhere((t) => t.name == 'In1').ioType, 'SimulatedInput');
      expect(tags.singleWhere((t) => t.name == 'Out1').ioType, 'SimulatedOutput');
    });

    test('ST POU maps to a StructuredText PlcProgram', () {
      final result = mapImportedProject(ir, projectName: 'MyProj', projectId: 'proj_1');
      final main = result.project.programs.singleWhere((p) => p.name == 'Main');
      expect(main.language, 'StructuredText');
      expect(main.stSource, contains('Count := Count + 1;'));
    });

    test('graphical POU maps to a language-tagged stub with a warning', () {
      final result = mapImportedProject(ir, projectName: 'MyProj', projectId: 'proj_1');
      final rung1 = result.project.programs.singleWhere((p) => p.name == 'Rung1');
      expect(rung1.language, 'LadderLogic');
      expect(rung1.rungs, isEmpty);
      expect(rung1.description, contains('not yet translated'));
      expect(result.report.graphicalStubCount, 1);
      expect(
        result.report.warnings.any((w) => w.message.contains('Rung1')),
        isTrue,
      );
    });

    test('report counts', () {
      final result = mapImportedProject(ir, projectName: 'MyProj', projectId: 'proj_1');
      // Temp_PV, Enable, Retained, In1, Out1, System(renamed), My Tag(renamed) = 7
      expect(result.report.tagCount, 7);
      expect(result.report.structCount, 1);
      expect(result.report.stProgramCount, 1);
      expect(result.report.graphicalStubCount, 1);
    });

    test('reserved name "System" is sanitized + warned', () {
      final result = mapImportedProject(ir, projectName: 'MyProj', projectId: 'proj_1');
      final tags = result.project.tags;
      expect(tags.any((t) => t.name == 'System'), isFalse);
      expect(tags.any((t) => t.name == 'System_1'), isTrue);
      expect(
        result.report.warnings.any((w) => w.message.contains('System')),
        isTrue,
      );
    });

    test('name with space is sanitized to underscore + warned', () {
      final result = mapImportedProject(ir, projectName: 'MyProj', projectId: 'proj_1');
      final tags = result.project.tags;
      expect(tags.any((t) => t.name == 'My_Tag'), isTrue);
      expect(
        result.report.warnings.any((w) => w.message.contains('My Tag')),
        isTrue,
      );
    });

    test('duplicate names within the import are suffixed', () {
      final dupIr = ImportedProject(
        name: 'Imported',
        types: const [],
        globalVars: [
          ImportedVar(name: 'Dup', baseType: 'BOOL', scope: VarScope.global),
          ImportedVar(name: 'Dup', baseType: 'BOOL', scope: VarScope.global),
        ],
        pous: const [],
        warnings: const [],
      );
      final result = mapImportedProject(dupIr, projectName: 'MyProj', projectId: 'proj_1');
      final names = result.project.tags.map((t) => t.name).toList();
      expect(names, containsAll(['Dup', 'Dup_1']));
    });

    test('project uses the supplied id/name', () {
      final result = mapImportedProject(ir, projectName: 'MyProj', projectId: 'proj_1');
      expect(result.project.id, 'proj_1');
      expect(result.project.name, 'MyProj');
    });

    test('never throws on odd/empty input', () {
      final empty = ImportedProject(
          name: '', types: const [], globalVars: const [], pous: const [], warnings: const []);
      expect(
        () => mapImportedProject(empty, projectName: '', projectId: ''),
        returnsNormally,
      );
    });
  });
}
