import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/gateway_screen.dart';
import 'package:soft_plc_mobile/services/opcua_host.dart';
import 'support/responsive_test_utils.dart';

/// A thin instrumented subclass of the REAL [OpcUaHost] — it still binds a
/// real (loopback, ephemeral-port) socket via the base class, but records
/// call counts so tests can assert the UI actually invoked start/stop.
/// Using the real host (rather than a hand-rolled fake) exercises the
/// genuine start/stop wiring the screen depends on, with port 0 so tests
/// never collide with a real port or leak a fixed one.
class _CountingOpcUaHost extends OpcUaHost {
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Future<void> start(PlcProject Function() projectProvider) async {
    startCalls++;
    await super.start(projectProvider);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    await super.stop();
  }
}

PlcProject _project() {
  return PlcProject(
    id: 'proj_gw_ui_test',
    name: 'Gateway UI Test',
    controllerName: 'PLC_01',
    tags: [
      PlcTag(
        name: 'Start_PB',
        path: 'Inputs.Start_PB',
        dataType: 'BOOL',
        value: false,
        ioType: 'SimulatedInput',
      ),
      PlcTag(
        name: 'Motor_Run',
        path: 'Outputs.Motor_Run',
        dataType: 'BOOL',
        value: false,
        ioType: 'SimulatedOutput',
      ),
    ],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );
}

Widget _app(PlcProject project, OpcUaHost host) {
  return MaterialApp(
    home: GatewayScreen(
      currentProject: project,
      host: host,
      onProjectUpdated: () {},
    ),
  );
}

void main() {
  testWidgets('renders "Outbound Protocols" title and OPC UA card', (tester) async {
    final project = _project();
    final host = _CountingOpcUaHost();
    addTearDown(host.dispose);

    await tester.pumpWidget(_app(project, host));
    await tester.pumpAndSettle();

    expect(find.text('Outbound Protocols'), findsOneWidget);
    expect(find.text('OPC UA'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('OPC UA card starts disabled by default with config hidden and 0 exposed', (tester) async {
    final project = _project();
    final host = _CountingOpcUaHost();
    addTearDown(host.dispose);

    await tester.pumpWidget(_app(project, host));
    await tester.pumpAndSettle();

    expect(project.protocols?.opcua?.enabled, false);
    final sw = tester.widget<Switch>(find.byType(Switch));
    expect(sw.value, false);
    expect(find.text('OPC UA Node Map'), findsNothing);
    expect(find.widgetWithText(ElevatedButton, 'Start hosting'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('toggling the OPC UA switch ON reveals namespace, node map, and hosting controls', (tester) async {
    final project = _project();
    final host = _CountingOpcUaHost();
    addTearDown(host.dispose);

    await tester.pumpWidget(_app(project, host));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch));
    await tester.pump();

    expect(project.protocols?.opcua?.enabled, true);
    expect(find.text('OPC UA Node Map'), findsOneWidget);
    expect(find.textContaining('Namespace'), findsWidgets);
    expect(find.widgetWithText(ElevatedButton, 'Start hosting'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Stop hosting'), findsOneWidget);
    expect(find.text('Stopped'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('toggling the OPC UA switch OFF hides the config again', (tester) async {
    final project = _project();
    final host = _CountingOpcUaHost();
    addTearDown(host.dispose);

    await tester.pumpWidget(_app(project, host));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(project.protocols?.opcua?.enabled, true);

    await tester.tap(find.byType(Switch));
    await tester.pump();

    expect(project.protocols?.opcua?.enabled, false);
    expect(find.text('OPC UA Node Map'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Start hosting calls the injected host and shows Running + endpoint', (tester) async {
    final project = _project();
    final host = _CountingOpcUaHost();
    addTearDown(host.dispose);

    await tester.pumpWidget(_app(project, host));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pump();
    // Port 0 -> the OS picks an ephemeral free port, so this test never
    // collides with a real port or leaks a fixed one across test runs.
    await tester.enterText(find.widgetWithText(TextField, '4840'), '0');
    await tester.pump();

    // Real dart:io socket work (ServerSocket.bind) happens inside start(),
    // so this must run under runAsync — the widget-test binding's fake
    // clock never resolves real async IO otherwise.
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(ElevatedButton, 'Start hosting'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(host.startCalls, 1);
    expect(find.text('Running'), findsOneWidget);
    expect(find.textContaining('opc.tcp://'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Stop hosting calls the injected host and returns to Stopped', (tester) async {
    final project = _project();
    final host = _CountingOpcUaHost();
    addTearDown(host.dispose);

    await tester.pumpWidget(_app(project, host));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.enterText(find.widgetWithText(TextField, '4840'), '0');
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(ElevatedButton, 'Start hosting'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(OutlinedButton, 'Stop hosting'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(host.stopCalls, 1);
    expect(find.text('Stopped'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editing the port field persists to protocols.opcua.port', (tester) async {
    final project = _project();
    final host = _CountingOpcUaHost();
    addTearDown(host.dispose);

    await tester.pumpWidget(_app(project, host));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pump();

    final portField = find.widgetWithText(TextField, '4840');
    expect(portField, findsOneWidget);
    await tester.enterText(portField, '48401');
    await tester.pump();

    expect(project.protocols?.opcua?.port, 48401);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid port input is ignored (keeps last valid value)', (tester) async {
    final project = _project();
    final host = _CountingOpcUaHost();
    addTearDown(host.dispose);

    await tester.pumpWidget(_app(project, host));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pump();

    final portField = find.widgetWithText(TextField, '4840');
    await tester.enterText(portField, 'not-a-port');
    await tester.pump();

    expect(project.protocols?.opcua?.port, 4840);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no overflow at 320 width', (tester) async {
    final project = _project();
    final host = _CountingOpcUaHost();
    addTearDown(host.dispose);
    await setSurface(tester, smallPhoneSize);
    await tester.pumpWidget(_app(project, host));
    await tester.pumpAndSettle();
    // Also exercise the enabled/expanded state, the more overflow-prone one.
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('no overflow at 1400 width', (tester) async {
    final project = _project();
    final host = _CountingOpcUaHost();
    addTearDown(host.dispose);
    await setSurface(tester, desktopSize);
    await tester.pumpWidget(_app(project, host));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
