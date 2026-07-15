import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/ld_monitor.dart';
import 'package:soft_plc_mobile/screens/ld_editor_screen.dart';
import 'package:soft_plc_mobile/widgets/live_tick.dart';

void main() {
  testWidgets('a TON block shows live ACC/PT when online', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [], structDefs: [], programs: [], tasks: [], hmis: [],
    );
    // A TIMER-typed tag 'T1' with ACC=1400, PRE=3000 (use the project's TIMER
    // composite; set the members via the struct value map).
    proj.tags.add(PlcTag(
      name: 'T1', path: 'T1', dataType: 'TIMER', ioType: 'Internal',
      value: {'ACC': 1400, 'PRE': 3000, 'EN': true, 'DN': false, 'TT': true},
    ));
    final rung = LdRung(rungIndex: 0, comment: '', nodes: [
      LdNode(id: 'L', kind: LdKind.leftRail),
      LdNode(id: 'b', kind: LdKind.block, blockType: 'TON', variable: 'T1', presetMs: 3000),
      LdNode(id: 'R', kind: LdKind.rightRail),
    ], wires: [
      LdWire(fromId: 'L', toId: 'b'),
      LdWire(fromId: 'b', toId: 'R'),
    ]);
    final prog = PlcProgram(name: 'Main', language: 'LadderLogic', rungs: [rung]);
    proj.programs.add(prog);

    final mon = LdMonitor();

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

    // Static: shows the preset line 'PT 3000ms'.
    expect(find.textContaining('3000'), findsWidgets);

    // Turn online; the live ACC/PT readout appears.
    await tester.tap(find.byTooltip('Go Online (live monitor)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1400'), findsOneWidget);
  });
}
