import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/fbd_monitor.dart';
import 'package:soft_plc_mobile/models/fbd_pins.dart';
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

  Future<void> runNoOverflowOnlineCase(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final project = _buildProject();
    final program = _buildProgram();
    project.programs.add(program);

    final monitor = FbdMonitor();
    // A long-ish numeric value and a TRUE bool so the value-label chips are
    // non-trivial (worst-case text width) while the overlay renders.
    monitor.pinValue[monitor.keyFor(program.name, 'c1', 'OUT')] = 12345.678;
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

    // Go online via the toggle so the value-label chips actually render.
    await tester.tap(find.byKey(const Key('fbd_online_toggle')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  }

  testWidgets(
      'no overflow with the online overlay ON at 320x568 (smallPhoneSize)',
      (tester) async {
    await runNoOverflowOnlineCase(tester, const Size(320, 568));
  });

  testWidgets('no overflow with the online overlay ON at 360x800',
      (tester) async {
    await runNoOverflowOnlineCase(tester, const Size(360, 800));
  });

  testWidgets(
      'online overlay shows stateful-block (TON) Q/ET values at their pins',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final project = _buildProject();
    final program = PlcProgram(name: 'FBD1', language: 'FunctionBlockDiagram');
    program.fbdBlocks.add(
      FbdBlock(id: 'ton1', type: 'TON', title: 'Timer1', x: 200, y: 40),
    );
    project.programs.add(program);

    // Confirm the exact TON output pin names via the pure pin registry
    // rather than hardcoding them.
    final outs = fbdOutputPins('TON');
    expect(outs, ['Q', 'ET']);
    final qPin = outs[0];
    final etPin = outs[1];

    final monitor = FbdMonitor();
    monitor.pinValue[monitor.keyFor(program.name, 'ton1', qPin)] = true;
    monitor.pinValue[monitor.keyFor(program.name, 'ton1', etPin)] = 1500;

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

    // Go online via the toggle.
    await tester.tap(find.byKey(const Key('fbd_online_toggle')));
    await tester.pumpAndSettle();

    // ET is an int (1500), so `_formatMonitorValue` renders it as-is ("1500"),
    // not to 2dp (that path is only taken for non-int `num`s).
    expect(find.textContaining('1500'), findsWidgets);

    // The Q output pin dot is styled energized (green) — bool-true renders
    // as TRUE at the pin label and the dot mirrors the AND-gate energized case.
    final qDot = tester.widget<Container>(find.byKey(const Key('fbdpin_ton1_out_Q')));
    expect((qDot.decoration as BoxDecoration).color, Colors.greenAccent);

    expect(tester.takeException(), isNull);
  });
}
