import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/screens/gateway_screen.dart';
import 'package:soft_plc_mobile/services/modbus_host.dart';
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

/// A fake host that fakes `status`/counts directly (no real socket) — used
/// ONLY by the "Subscriptions: N · Monitored items: M" line tests, where the
/// point is purely to prove the screen renders/hides that line off the
/// host's counts, not to exercise the real networking stack (that's what
/// `opcua_host_test.dart`'s E2E test is for).
class _FakeCountsOpcUaHost extends OpcUaHost {
  OpcUaHostStatus _fakeStatus = OpcUaHostStatus.stopped;
  int _fakeSubscriptionCount = 0;
  int _fakeMonitoredItemCount = 0;

  @override
  OpcUaHostStatus get status => _fakeStatus;

  @override
  int get subscriptionCount => _fakeSubscriptionCount;

  @override
  int get monitoredItemCount => _fakeMonitoredItemCount;

  void setRunning({required int subscriptions, required int monitoredItems}) {
    _fakeStatus = OpcUaHostStatus.running;
    _fakeSubscriptionCount = subscriptions;
    _fakeMonitoredItemCount = monitoredItems;
    notifyListeners();
  }

  void setStopped() {
    _fakeStatus = OpcUaHostStatus.stopped;
    _fakeSubscriptionCount = 0;
    _fakeMonitoredItemCount = 0;
    notifyListeners();
  }
}

PlcProject _project({String id = 'proj_gw_ui_test', int? port}) {
  final project = PlcProject(
    id: id,
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
  if (port != null) {
    project.protocols = ProtocolSettings.defaults(project);
    project.protocols!.opcua = OpcUaProtocolConfig.defaults(project)
      ..enabled = true
      ..port = port;
  }
  return project;
}

/// A thin instrumented subclass of the REAL [ModbusHost] — mirrors
/// [_CountingOpcUaHost]: still binds a real (loopback, ephemeral-port)
/// socket via the base class, but records call counts so tests can assert
/// the UI actually invoked start/stop.
class _CountingModbusHost extends ModbusHost {
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

Widget _app(
  PlcProject project,
  OpcUaHost host, {
  bool hostingSupported = true,
  ModbusHost? modbusHost,
}) {
  return MaterialApp(
    home: GatewayScreen(
      currentProject: project,
      host: host,
      modbusHost: modbusHost ?? _CountingModbusHost(),
      onProjectUpdated: () {},
      hostingSupported: hostingSupported,
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
    expect(find.byKey(const Key('opcua_enable_switch')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('OPC UA card starts disabled by default with config hidden and 0 exposed', (tester) async {
    final project = _project();
    final host = _CountingOpcUaHost();
    addTearDown(host.dispose);

    await tester.pumpWidget(_app(project, host));
    await tester.pumpAndSettle();

    expect(project.protocols?.opcua?.enabled, false);
    final sw = tester.widget<Switch>(find.byKey(const Key('opcua_enable_switch')));
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

    await tester.tap(find.byKey(const Key('opcua_enable_switch')));
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

    await tester.tap(find.byKey(const Key('opcua_enable_switch')));
    await tester.pump();
    expect(project.protocols?.opcua?.enabled, true);

    await tester.tap(find.byKey(const Key('opcua_enable_switch')));
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
    await tester.tap(find.byKey(const Key('opcua_enable_switch')));
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

  testWidgets('hosting unsupported (web): Start hosting disabled + native-only note shown', (tester) async {
    final project = _project();
    final host = _CountingOpcUaHost();
    addTearDown(host.dispose);

    await tester.pumpWidget(_app(project, host, hostingSupported: false));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('opcua_enable_switch'))); // reveal hosting controls
    await tester.pump();

    final startBtn = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Start hosting'),
    );
    expect(startBtn.onPressed, isNull); // disabled — can't attempt a doomed bind
    expect(find.textContaining('web browsers do not allow'), findsOneWidget);
    expect(host.startCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('hosting supported (native): Start hosting enabled + no note', (tester) async {
    final project = _project();
    final host = _CountingOpcUaHost();
    addTearDown(host.dispose);

    await tester.pumpWidget(_app(project, host, hostingSupported: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('opcua_enable_switch')));
    await tester.pump();

    final startBtn = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Start hosting'),
    );
    expect(startBtn.onPressed, isNotNull); // enabled
    expect(find.textContaining('web browsers do not allow'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Stop hosting calls the injected host and returns to Stopped', (tester) async {
    final project = _project();
    final host = _CountingOpcUaHost();
    addTearDown(host.dispose);

    await tester.pumpWidget(_app(project, host));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('opcua_enable_switch')));
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
    await tester.tap(find.byKey(const Key('opcua_enable_switch')));
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
    await tester.tap(find.byKey(const Key('opcua_enable_switch')));
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
    await tester.tap(find.byKey(const Key('opcua_enable_switch')));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('reusing the State across a project switch refreshes the port field (didUpdateWidget)', (tester) async {
    final projectA = _project(id: 'proj_a', port: 4840);
    final host = _CountingOpcUaHost();
    addTearDown(host.dispose);

    await tester.pumpWidget(_app(projectA, host));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '4840'), findsOneWidget);

    // Rebuild the SAME State (same widget type/slot) with a different
    // project — Flutter reuses the State object, so `_portController` (a
    // `late final` seeded only in initState) would otherwise still show
    // project A's port.
    final projectB = _project(id: 'proj_b', port: 4900);
    await tester.pumpWidget(_app(projectB, host));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, '4900'), findsOneWidget);
    expect(find.widgetWithText(TextField, '4840'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no overflow at 1400 width', (tester) async {
    final project = _project();
    final host = _CountingOpcUaHost();
    addTearDown(host.dispose);
    await setSurface(tester, desktopSize);
    await tester.pumpWidget(_app(project, host));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('opcua_enable_switch')));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  group('Subscriptions/Monitored items status line (Task 3)', () {
    testWidgets('shows "Subscriptions: N · Monitored items: M" when running', (tester) async {
      final project = _project();
      final host = _FakeCountsOpcUaHost();
      addTearDown(host.dispose);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('opcua_enable_switch')));
      await tester.pump();

      host.setRunning(subscriptions: 2, monitoredItems: 5);
      await tester.pump();

      expect(find.text('Subscriptions: 2 · Monitored items: 5'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the counts line is absent when stopped', (tester) async {
      final project = _project();
      final host = _FakeCountsOpcUaHost();
      addTearDown(host.dispose);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('opcua_enable_switch')));
      await tester.pump();

      expect(host.status, OpcUaHostStatus.stopped);
      expect(find.textContaining('Subscriptions:'), findsNothing);

      // Running then stopped again: the line must disappear.
      host.setRunning(subscriptions: 1, monitoredItems: 1);
      await tester.pump();
      expect(find.textContaining('Subscriptions:'), findsOneWidget);

      host.setStopped();
      await tester.pump();
      expect(find.textContaining('Subscriptions:'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow at 320 width while running with the counts line shown', (tester) async {
      final project = _project();
      final host = _FakeCountsOpcUaHost();
      addTearDown(host.dispose);
      await setSurface(tester, smallPhoneSize);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('opcua_enable_switch')));
      await tester.pump();
      host.setRunning(subscriptions: 12, monitoredItems: 345);
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow at 1400 width while running with the counts line shown', (tester) async {
      final project = _project();
      final host = _FakeCountsOpcUaHost();
      addTearDown(host.dispose);
      await setSurface(tester, desktopSize);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('opcua_enable_switch')));
      await tester.pump();
      host.setRunning(subscriptions: 12, monitoredItems: 345);
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });

  group('Modbus TCP card (WS24 Task 3)', () {
    testWidgets('renders the Modbus TCP card, starts disabled with config hidden', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final modbusHost = _CountingModbusHost();
      addTearDown(modbusHost.dispose);

      await tester.pumpWidget(_app(project, host, modbusHost: modbusHost));
      await tester.pumpAndSettle();

      expect(find.text('Modbus TCP'), findsOneWidget);
      expect(find.byKey(const Key('modbus_enable_switch')), findsOneWidget);
      final sw = tester.widget<Switch>(find.byKey(const Key('modbus_enable_switch')));
      expect(sw.value, false);
      expect(find.text('Modbus Register Map'), findsNothing);
      expect(find.widgetWithText(ElevatedButton, 'Start hosting'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('toggling the Modbus switch ON reveals port, hosting controls, and map editor', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final modbusHost = _CountingModbusHost();
      addTearDown(modbusHost.dispose);

      await tester.pumpWidget(_app(project, host, modbusHost: modbusHost));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('modbus_enable_switch')));
      await tester.pump();

      expect(project.protocols?.modbus?.enabled, true);
      expect(find.text('Modbus Register Map'), findsOneWidget);
      expect(find.widgetWithText(TextField, '502'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Start hosting'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Stop hosting'), findsOneWidget);
      // The OPC UA card is still disabled/collapsed (only Modbus was
      // toggled), so only the Modbus card's status pill shows "Stopped".
      expect(find.text('Stopped'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('toggling the Modbus switch OFF hides the config again', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final modbusHost = _CountingModbusHost();
      addTearDown(modbusHost.dispose);

      await tester.pumpWidget(_app(project, host, modbusHost: modbusHost));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('modbus_enable_switch')));
      await tester.pump();
      expect(project.protocols?.modbus?.enabled, true);

      await tester.tap(find.byKey(const Key('modbus_enable_switch')));
      await tester.pump();

      expect(project.protocols?.modbus?.enabled, false);
      expect(find.text('Modbus Register Map'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Regenerate populates entries from the project tags', (tester) async {
      final project = _project();
      // Pre-configure Modbus enabled with an EMPTY map (rather than clearing
      // after first build) so the "No entries yet" prompt is part of the
      // widget's initial build, not a mutation the running State never
      // learns about.
      project.protocols = ProtocolSettings.defaults(project);
      project.protocols!.modbus!.enabled = true;
      project.protocols!.modbus!.map.entries.clear();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final modbusHost = _CountingModbusHost();
      addTearDown(modbusHost.dispose);

      await tester.pumpWidget(_app(project, host, modbusHost: modbusHost));
      await tester.pumpAndSettle();
      expect(find.text('No entries yet. Tap Regenerate to build a default map from the project tags.'),
          findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Regenerate'));
      await tester.pump();

      expect(project.protocols?.modbus?.map.entries, isNotEmpty);
      expect(find.text('No entries yet. Tap Regenerate to build a default map from the project tags.'),
          findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Start hosting calls the injected Modbus host and shows Running + endpoint', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final modbusHost = _CountingModbusHost();
      addTearDown(modbusHost.dispose);

      await tester.pumpWidget(_app(project, host, modbusHost: modbusHost));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('modbus_enable_switch')));
      await tester.pump();
      // Port 0 -> the OS picks an ephemeral free port, never colliding with a
      // real port or leaking a fixed one across test runs.
      await tester.enterText(find.widgetWithText(TextField, '502'), '0');
      await tester.pump();

      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(ElevatedButton, 'Start hosting'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      expect(modbusHost.startCalls, 1);
      expect(find.text('Running'), findsOneWidget);
      expect(find.textContaining('modbus-tcp://'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Stop hosting calls the injected Modbus host and returns to Stopped', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final modbusHost = _CountingModbusHost();
      addTearDown(modbusHost.dispose);

      await tester.pumpWidget(_app(project, host, modbusHost: modbusHost));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('modbus_enable_switch')));
      await tester.pump();
      await tester.enterText(find.widgetWithText(TextField, '502'), '0');
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

      expect(modbusHost.stopCalls, 1);
      expect(find.text('Stopped'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('hosting unsupported (web): Modbus Start hosting disabled + native-only note shown', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final modbusHost = _CountingModbusHost();
      addTearDown(modbusHost.dispose);

      await tester.pumpWidget(_app(project, host, modbusHost: modbusHost, hostingSupported: false));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('modbus_enable_switch')));
      await tester.pump();

      final startBtn = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Start hosting'),
      );
      expect(startBtn.onPressed, isNull);
      expect(find.textContaining('web browsers do not allow'), findsOneWidget);
      expect(modbusHost.startCalls, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('hosting supported (native): Modbus Start hosting enabled + no note', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final modbusHost = _CountingModbusHost();
      addTearDown(modbusHost.dispose);

      await tester.pumpWidget(_app(project, host, modbusHost: modbusHost, hostingSupported: true));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('modbus_enable_switch')));
      await tester.pump();

      final startBtn = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Start hosting'),
      );
      expect(startBtn.onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow at 320 width with both cards expanded', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final modbusHost = _CountingModbusHost();
      addTearDown(modbusHost.dispose);
      await setSurface(tester, smallPhoneSize);

      await tester.pumpWidget(_app(project, host, modbusHost: modbusHost));
      await tester.pumpAndSettle();
      // Toggle Modbus first, while both switches are still on-screen — once
      // OPC UA expands (node map + hosting controls) it pushes the Modbus
      // switch below the small-phone viewport.
      await tester.tap(find.byKey(const Key('modbus_enable_switch')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('opcua_enable_switch')));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow at 1400 width with both cards expanded', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final modbusHost = _CountingModbusHost();
      addTearDown(modbusHost.dispose);
      await setSurface(tester, desktopSize);

      await tester.pumpWidget(_app(project, host, modbusHost: modbusHost));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('modbus_enable_switch')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('opcua_enable_switch')));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });
}
