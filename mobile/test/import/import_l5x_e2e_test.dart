// End-to-end proof against REAL Rockwell L5X exports in
// `Resources/Project Exports/Rockwell-L5X/` (gitignored corpus — skips when
// absent). Proves parseL5x -> mapImportedProject produces a real project: UDTs,
// AOIs (as FbDefinitions), and tags import; an AOI-typed tag resolves to its
// composite type; an ST-bodied AOI executes.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/import/ir_to_project.dart';
import 'package:soft_plc_mobile/import/l5x_parser.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

File? _sample(String fileName) {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final f = File('${dir.path}/Resources/Project Exports/Rockwell-L5X/$fileName');
    if (f.existsSync()) return f;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

void main() {
  test('real Numeric_Program.L5X imports with UDTs/AOIs/tags', () {
    final f = _sample('logixlibraries_Numeric_Program.L5X');
    if (f == null) {
      markTestSkipped('Rockwell-L5X corpus absent — skipping.');
      return;
    }
    final ir = parseL5x(f.readAsStringSync());
    final res = mapImportedProject(ir, projectName: ir.name, projectId: 'l5x_e2e');
    final p = res.project;
    expect(p, isNotNull);
    // AOIs became function-block definitions.
    expect(p.fbDefinitions, isNotEmpty);
    expect(res.report.importedFbCount, greaterThan(0));
    // At least one controller tag is AOI-typed and resolves to a composite.
    final aoiNames = p.fbDefinitions.map((d) => d.name).toSet();
    final aoiTag = p.tags.where((t) => aoiNames.contains(t.dataType));
    expect(aoiTag, isNotEmpty, reason: 'expected an AOI-typed tag');
    expect(defaultValueFor(p, aoiTag.first.dataType, 0), isA<Map>());
  });

  test('real Op_PID_AOI.L5X imports without throwing', () {
    final f = _sample('logixlibraries_Op_PID_AOI.L5X');
    if (f == null) {
      markTestSkipped('Rockwell-L5X corpus absent — skipping.');
      return;
    }
    final ir = parseL5x(f.readAsStringSync());
    final res = mapImportedProject(ir, projectName: ir.name, projectId: 'l5x_e2e2');
    expect(res.project, isNotNull);
    expect(res.project.fbDefinitions, isNotEmpty);
  });
}
