import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/scan_tick.dart';

void main() {
  test('runScanTick populates the LD monitor for a running LD program', () {
    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [], structDefs: [], programs: [], tasks: [], hmis: [],
    );
    proj.tags.add(PlcTag(name: 'A', path: 'A', dataType: 'BOOL', value: true, ioType: 'Internal'));
    proj.tags.add(PlcTag(name: 'Y', path: 'Y', dataType: 'BOOL', value: false, ioType: 'Internal'));
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
    // A continuous task owning the program so it is due every scan.
    proj.tasks.add(PlcTask(
      name: 'T', type: 'Continuous', programNames: ['Main'],
      periodMs: 0, watchdogMs: 0));

    final rt = ScanTickRuntime();
    runScanTick(proj, 100, rt);

    expect(rt.ldMonitor.nodePower[rt.ldMonitor.keyFor('Main', 0, 'a')], isTrue);

    rt.resetSession();
    expect(rt.ldMonitor.nodePower, isEmpty);
  });
}
