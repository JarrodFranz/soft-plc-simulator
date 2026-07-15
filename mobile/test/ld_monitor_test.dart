import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/ld_monitor.dart';

PlcProject _projWithSeries({required bool aVal}) {
  final proj = PlcProject(
    id: 'p', name: 'P', controllerName: 'C',
    tags: [], structDefs: [], programs: [], tasks: [], hmis: [],
  );
  proj.tags.add(PlcTag(name: 'A', path: 'A', dataType: 'BOOL', value: aVal, ioType: 'Internal'));
  proj.tags.add(PlcTag(name: 'Y', path: 'Y', dataType: 'BOOL', value: false, ioType: 'Internal'));
  // Rung: L1 -- [A] -- (Y). A single series contact into a coil.
  final rung = LdRung(rungIndex: 0, comment: '', nodes: [
    LdNode(id: 'L', kind: LdKind.leftRail),
    LdNode(id: 'a', kind: LdKind.contact, variable: 'A'),
    LdNode(id: 'y', kind: LdKind.coil, variable: 'Y'),
    LdNode(id: 'R', kind: LdKind.rightRail),
  ], wires: [
    LdWire(fromId: 'L', toId: 'a'),
    LdWire(fromId: 'a', toId: 'y'),
    LdWire(fromId: 'y', toId: 'R'),
  ]);
  proj.programs.add(PlcProgram(name: 'Main', language: 'LadderLogic', rungs: [rung]));
  return proj;
}

void main() {
  test('monitor records energized nodes on a true series path', () {
    final proj = _projWithSeries(aVal: true);
    final rt = LdExecRuntime();
    final mon = LdMonitor();
    executeLdPrograms(proj, 100, rt, monitor: mon);
    expect(mon.nodePower[mon.keyFor('Main', 0, 'a')], isTrue);
    expect(mon.nodePower[mon.keyFor('Main', 0, 'y')], isTrue);
  });

  test('monitor records de-energized downstream when a series contact is false', () {
    final proj = _projWithSeries(aVal: false);
    final rt = LdExecRuntime();
    final mon = LdMonitor();
    executeLdPrograms(proj, 100, rt, monitor: mon);
    expect(mon.nodePower[mon.keyFor('Main', 0, 'a')], isFalse);
    expect(mon.nodePower[mon.keyFor('Main', 0, 'y')], isFalse);
  });

  test('executeLdPrograms without a monitor is unaffected (no throw)', () {
    final proj = _projWithSeries(aVal: true);
    final rt = LdExecRuntime();
    executeLdPrograms(proj, 100, rt); // monitor omitted
    expect(readPathBool(proj, 'Y'), isTrue);
  });
}

// Local helper mirroring the tag read used by the app.
bool readPathBool(PlcProject p, String path) =>
    p.tags.firstWhere((t) => t.name == path).value == true;
