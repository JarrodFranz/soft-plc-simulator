import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/st_exec.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

PlcProject _p() {
  final p = PlcProject(id: 'x', name: 'x', controllerName: 'c',
      tags: [], structDefs: [], programs: [], tasks: [], hmis: []);
  p.tags.add(PlcTag(name: 'Gen', path: 'Gen', dataType: 'FLOAT64', value: 5.0, ioType: 'SimulatedOutput'));
  p.tags.add(PlcTag(name: 'Out', path: 'Out', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'));
  // Reads Gen (a generated tag) into Out, and tries to overwrite Gen.
  p.programs.add(PlcProgram(name: 'P', language: 'StructuredText',
      stSource: 'Out := Gen;\nGen := 999.0;'));
  return p;
}

void main() {
  test('logic write to a read-only (generated) path is refused; read works', () {
    final p = _p();
    executeStPrograms(p, 100, StRuntime(), readOnly: {'Gen'});
    expect(readPath(p, 'Out'), 5.0);   // read succeeded
    expect(readPath(p, 'Gen'), 5.0);   // write refused (not 999)
  });

  test('without readOnly, the write goes through (unchanged behavior)', () {
    final p = _p();
    executeStPrograms(p, 100, StRuntime());
    expect(readPath(p, 'Gen'), 999.0);
  });
}
