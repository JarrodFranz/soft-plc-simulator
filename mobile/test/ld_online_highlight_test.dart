import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/ld_monitor.dart';
import 'package:soft_plc_mobile/screens/ld_editor_screen.dart';
import 'package:soft_plc_mobile/widgets/live_tick.dart';

void main() {
  testWidgets('Go-Online toggle appears and can be turned on', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [PlcTag(name: 'A', path: 'A', dataType: 'BOOL', value: true, ioType: 'Internal')],
      structDefs: [], programs: [], tasks: [], hmis: [],
    );
    final rung = LdRung(rungIndex: 0, comment: '', nodes: [
      LdNode(id: 'L', kind: LdKind.leftRail),
      LdNode(id: 'a', kind: LdKind.contact, variable: 'A'),
      LdNode(id: 'R', kind: LdKind.rightRail),
    ], wires: [
      LdWire(fromId: 'L', toId: 'a'),
      LdWire(fromId: 'a', toId: 'R'),
    ]);
    final prog = PlcProgram(name: 'Main', language: 'LadderLogic', rungs: [rung]);
    proj.programs.add(prog);

    final mon = LdMonitor();
    mon.nodePower[mon.keyFor('Main', 0, 'a')] = true;

    await tester.pumpWidget(MaterialApp(
      home: LiveTickScope(
        notifier: LiveTick(),
        child: LdEditorScreen(
          currentProject: proj,
          program: prog,
          onProgramUpdated: () {},
          monitor: mon,
          scanRunning: true,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // The Go-Online toggle is present.
    final toggle = find.byTooltip('Go Online (live monitor)');
    expect(toggle, findsOneWidget);

    // Turning it on does not throw and keeps the ladder rendered.
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('-| |-'), findsOneWidget);
  });
}
