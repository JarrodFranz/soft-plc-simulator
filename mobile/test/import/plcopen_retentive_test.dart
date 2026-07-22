// Spec-conformance test for RETAIN handling in the PLCopen TC6 importer.
//
// Per ISO/IEC 61131-10 / PLCopen TC6 (tc6_xml_v201.xsd), the retain/constant/
// nonretain qualifiers are attributes of the variable-LIST container element
// (`<globalVars retain="true">`, `<localVars retain="true">`), NOT of the
// individual `<variable>` — a `<variable>` cannot carry a `retain` attribute
// at all. The fixture retentive_vars.xml is authored to that spec, so this
// test catches an importer that (wrongly) looks for retain on the variable.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/import_ir.dart';
import 'package:soft_plc_mobile/import/ir_to_project.dart';
import 'package:soft_plc_mobile/import/plcopen_parser.dart';
import 'package:soft_plc_mobile/models/project_model.dart';

void main() {
  final xml =
      File('test/fixtures/plcopen/retentive_vars.xml').readAsStringSync();

  group('PLCopen RETAIN (container-level qualifier)', () {
    test('parser reads retain from the globalVars/localVars container', () {
      final ir = parsePlcOpen(xml);

      ImportedVar globalNamed(String n) =>
          ir.globalVars.firstWhere((v) => v.name == n);

      // <globalVars retain="true"> -> both members retained
      expect(globalNamed('TotalCount').retain, isTrue,
          reason: 'TotalCount is inside <globalVars retain="true">');
      expect(globalNamed('LastRecipe').retain, isTrue,
          reason: 'LastRecipe is inside <globalVars retain="true">');
      // plain <globalVars> -> not retained
      expect(globalNamed('Heartbeat').retain, isFalse);
      // <globalVars constant="true"> -> constant is NOT retain
      expect(globalNamed('MaxTemp').retain, isFalse,
          reason: 'constant must not be treated as retain');

      // POU-local VAR RETAIN block, also container-level
      final main = ir.pous.firstWhere((p) => p.name == 'Main');
      ImportedVar localNamed(String n) =>
          main.localVars.firstWhere((v) => v.name == n);
      expect(localNamed('Accumulator').retain, isTrue,
          reason: 'Accumulator is inside <localVars retain="true">');
      expect(localNamed('Scratch').retain, isFalse);
    });

    test('mapper carries retain through to tag.retentive', () {
      final ir = parsePlcOpen(xml);
      final result = mapImportedProject(ir,
          projectName: 'RetentiveDemo', projectId: 'retain_test');

      PlcTag tag(String n) =>
          result.project.tags.firstWhere((t) => t.name == n);

      expect(tag('TotalCount').retentive, isTrue);
      expect(tag('LastRecipe').retentive, isTrue);
      expect(tag('Heartbeat').retentive, isFalse);
      expect(tag('MaxTemp').retentive, isFalse);
    });
  });
}
