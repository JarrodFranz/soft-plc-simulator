import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/fbd_monitor.dart';
import 'package:soft_plc_mobile/screens/fbd_editor_screen.dart';
import 'package:soft_plc_mobile/widgets/live_tick.dart';

PlcProject _buildProject() {
  return PlcProject(
    id: 'proj_test_fbd_online',
    name: 'Test FBD Online Project',
    controllerName: 'TestPLC',
    tags: [
      PlcTag(name: 'Motor_Run', path: 'Motor_Run', dataType: 'BOOL', value: false, ioType: 'Internal'),
    ],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );
}

PlcProgram _buildProgram() {
  final program = PlcProgram(name: 'FBD1', language: 'FunctionBlockDiagram');
  program.fbdBlocks.addAll([
    FbdBlock(id: 'c1', type: 'CONST', title: 'Const15', tagBinding: '15', x: 40, y: 40),
    FbdBlock(id: 'o1', type: 'TAG_OUTPUT', title: 'Out1', tagBinding: 'Motor_Run', x: 320, y: 40),
    FbdBlock(id: 'and1', type: 'AND', title: 'AndGate', x: 40, y: 220),
  ]);
  program.fbdWires.add(FbdWire(fromBlockId: 'c1', fromPin: 'OUT', toBlockId: 'o1', toPin: 'IN'));
  return program;
}

void main() {
  testWidgets(
      'offline hides monitored values; online shows wire/pin values and energizes bool-true pins',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final project = _buildProject();
    final program = _buildProgram();
    project.programs.add(program);

    final monitor = FbdMonitor();
    // A numeric value flowing across the c1 -> o1 wire.
    monitor.pinValue[monitor.keyFor(program.name, 'c1', 'OUT')] = 15.0;
    // A boolean-true output on an unwired block (still shown at its pin).
    monitor.pinValue[monitor.keyFor(program.name, 'and1', 'OUT')] = true;

    await tester.pumpWidget(MaterialApp(
      home: LiveTickScope(
        notifier: LiveTick(),
        child: FbdEditorScreen(
          currentProject: project,
          program: program,
          onProgramUpdated: () {},
          monitor: monitor,
          scanRunning: true,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Offline (default): no monitored value text is rendered anywhere, and
    // the AND gate's OUT dot uses its static (non-energized) color.
    expect(find.textContaining('15.00'), findsNothing);
    final offlineDot = tester.widget<Container>(find.byKey(const Key('fbdpin_and1_out_OUT')));
    expect((offlineDot.decoration as BoxDecoration).color, isNot(Colors.greenAccent));

    // Go online via the toggle.
    await tester.tap(find.byKey(const Key('fbd_online_toggle')));
    await tester.pumpAndSettle();

    // The numeric value carried by the c1 -> o1 wire is now shown (~2dp).
    expect(find.textContaining('15.00'), findsWidgets);

    // The AND gate's bool-true OUT pin is styled energized (green).
    final onlineDot = tester.widget<Container>(find.byKey(const Key('fbdpin_and1_out_OUT')));
    expect((onlineDot.decoration as BoxDecoration).color, Colors.greenAccent);
  });
}
