import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/st_exec.dart';
import 'package:soft_plc_mobile/models/tag_resolver.dart';

PlcProject _proj() {
  final p = PlcProject(
    id: 'x',
    name: 'x',
    controllerName: 'PLC_01',
    tags: [],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );
  p.tags.add(PlcTag(name: 'A', path: 'A', dataType: 'BOOL', value: false, ioType: 'Internal'));
  p.tags.add(PlcTag(name: 'B', path: 'B', dataType: 'BOOL', value: false, ioType: 'Internal'));
  p.programs.add(PlcProgram(name: 'ProgA', language: 'StructuredText', stSource: 'A := TRUE;'));
  p.programs.add(PlcProgram(name: 'ProgB', language: 'StructuredText', stSource: 'B := TRUE;'));
  return p;
}

void main() {
  test('only=null runs all programs (unchanged behavior)', () {
    final p = _proj();
    executeStPrograms(p, 100, StRuntime());
    expect(readPath(p, 'A'), true);
    expect(readPath(p, 'B'), true);
  });

  test('only={ProgA} runs just ProgA', () {
    final p = _proj();
    executeStPrograms(p, 100, StRuntime(), only: {'ProgA'});
    expect(readPath(p, 'A'), true);
    expect(readPath(p, 'B'), false);
  });

  test('only={} runs nothing', () {
    final p = _proj();
    executeStPrograms(p, 100, StRuntime(), only: <String>{});
    expect(readPath(p, 'A'), false);
    expect(readPath(p, 'B'), false);
  });
}
