import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/ld_exec.dart';
import 'package:soft_plc_mobile/models/ld_monitor.dart';

/// The online element highlight (`nodeTrue`) reflects an element's OWN true
/// state, decoupled from upstream power flow (`nodePower`) which drives wires.
void main() {
  test('an enabled-but-not-done timer is true (lit) while its output power is false', () {
    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [
        PlcTag(name: 'A', path: 'A', dataType: 'BOOL', value: true, ioType: 'Internal'),
        PlcTag(
          name: 'T1', path: 'T1', dataType: 'TIMER', ioType: 'Internal',
          value: {'ACC': 0, 'PRE': 3000, 'EN': false, 'DN': false, 'TT': false},
        ),
      ],
      structDefs: [], programs: [], tasks: [], hmis: [],
    );
    // L -- [A(true)] -- [TON T1, PT 3000] -- R
    final rung = LdRung(rungIndex: 0, comment: '', nodes: [
      LdNode(id: 'L', kind: LdKind.leftRail),
      LdNode(id: 'a', kind: LdKind.contact, variable: 'A'),
      LdNode(id: 'b', kind: LdKind.block, blockType: 'TON', variable: 'T1', presetMs: 3000),
      LdNode(id: 'R', kind: LdKind.rightRail),
    ], wires: [
      LdWire(fromId: 'L', toId: 'a'),
      LdWire(fromId: 'a', toId: 'b'),
      LdWire(fromId: 'b', toId: 'R'),
    ]);
    proj.programs.add(PlcProgram(name: 'Main', language: 'LadderLogic', rungs: [rung]));

    final rt = LdExecRuntime();
    final mon = LdMonitor();
    executeLdPrograms(proj, 100, rt, monitor: mon); // one 100ms scan: timer counting

    final bKey = mon.keyFor('Main', 0, 'b');
    // The timer is enabled and counting (not done): its output does not pass
    // power (wire stays dim) but the block itself is active (face lit).
    expect(mon.nodePower[bKey], isFalse, reason: 'TON output (DN) is still false while counting');
    expect(mon.nodeTrue[bKey], isTrue, reason: 'TON is enabled/active, so the block lights');
  });

  test('a conducting contact downstream of an open contact is true (lit) with no power', () {
    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [
        PlcTag(name: 'A', path: 'A', dataType: 'BOOL', value: false, ioType: 'Internal'),
        PlcTag(name: 'B', path: 'B', dataType: 'BOOL', value: true, ioType: 'Internal'),
      ],
      structDefs: [], programs: [], tasks: [], hmis: [],
    );
    // L -- [A(false)] -- [B(true)] -- R : A open breaks power to B, but B's bit is true.
    final rung = LdRung(rungIndex: 0, comment: '', nodes: [
      LdNode(id: 'L', kind: LdKind.leftRail),
      LdNode(id: 'a', kind: LdKind.contact, variable: 'A'),
      LdNode(id: 'b', kind: LdKind.contact, variable: 'B'),
      LdNode(id: 'R', kind: LdKind.rightRail),
    ], wires: [
      LdWire(fromId: 'L', toId: 'a'),
      LdWire(fromId: 'a', toId: 'b'),
      LdWire(fromId: 'b', toId: 'R'),
    ]);
    proj.programs.add(PlcProgram(name: 'Main', language: 'LadderLogic', rungs: [rung]));

    final rt = LdExecRuntime();
    final mon = LdMonitor();
    executeLdPrograms(proj, 100, rt, monitor: mon);

    final bKey = mon.keyFor('Main', 0, 'b');
    expect(mon.nodePower[bKey], isFalse, reason: 'no power reaches B past the open A');
    expect(mon.nodeTrue[bKey], isTrue, reason: 'B is conducting (its bit is true), so it lights');
  });
}
