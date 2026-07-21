import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/import/ir_to_project.dart';

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

void main() {
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
