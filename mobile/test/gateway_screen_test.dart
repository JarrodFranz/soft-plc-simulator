import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:soft_plc_mobile/models/dnp3_map.dart';
import 'package:soft_plc_mobile/models/mqtt_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/screens/gateway_screen.dart';
import 'package:soft_plc_mobile/services/dnp3_host.dart';
import 'package:soft_plc_mobile/services/enip_host.dart';
import 'package:soft_plc_mobile/services/fins_host.dart';
import 'package:soft_plc_mobile/services/s7_host.dart';
import 'package:soft_plc_mobile/services/modbus_host.dart';
import 'package:soft_plc_mobile/services/mqtt_host.dart';
import 'package:soft_plc_mobile/services/opcua_host.dart';
import 'package:soft_plc_mobile/services/slmp_host.dart';
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

/// A fake host that fakes `appCertThumbprint`/`regenerateCertificate()` (no
/// real cert-store I/O or RSA keygen) — used to test the OPC UA card's
/// app-certificate display + Regenerate button without the ~1-3s real keygen
/// cost (that's what `opcua_host_test.dart`'s cert-store wiring test is for).
class _FakeCertOpcUaHost extends OpcUaHost {
  String? _fakeThumbprint;
  int regenerateCalls = 0;

  @override
  String? get appCertThumbprint => _fakeThumbprint;

  @override
  Future<void> regenerateCertificate() async {
    regenerateCalls++;
    _fakeThumbprint = 'AA:BB:CC:${regenerateCalls.toString().padLeft(2, '0')}';
    notifyListeners();
  }
}

/// A fake host that fakes `status` directly (no real socket) — mirrors
/// [_FakeCountsOpcUaHost]: used ONLY to prove the MQTT card disables its
/// config-edit fields (format dropdown, topic/namespace fields, etc.) while
/// `status == running`, without exercising the real networking stack.
class _FakeConnectedMqttHost extends MqttHost {
  MqttHostStatus _fakeStatus = MqttHostStatus.stopped;
  int rebirthCalls = 0;

  @override
  MqttHostStatus get status => _fakeStatus;

  void setConnected() {
    _fakeStatus = MqttHostStatus.running;
    notifyListeners();
  }

  @override
  void requestRebirth() {
    rebirthCalls++;
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

/// Fakes that report a live `status` (no real socket) and count teardown
/// calls — used to prove that flipping a protocol's enable toggle OFF while
/// it is hosting tears the host down (auto-stop-on-disable).
class _RunningOpcUaHost extends OpcUaHost {
  int stopCalls = 0;
  @override
  OpcUaHostStatus get status => OpcUaHostStatus.running;
  @override
  Future<void> stop() async {
    stopCalls++;
  }
}

class _RunningModbusHost extends ModbusHost {
  int stopCalls = 0;
  @override
  ModbusHostStatus get status => ModbusHostStatus.running;
  @override
  Future<void> stop() async {
    stopCalls++;
  }
}

class _ConnectedMqttHost extends MqttHost {
  int disconnectCalls = 0;
  int rebirthCalls = 0;
  @override
  MqttHostStatus get status => MqttHostStatus.running;
  @override
  Future<void> disconnect() async {
    disconnectCalls++;
  }

  @override
  void requestRebirth() {
    rebirthCalls++;
  }
}

/// A thin instrumented subclass of the REAL [DnpHost] — mirrors
/// [_CountingModbusHost]: still binds a real (loopback, ephemeral-port)
/// socket via the base class, but records call counts so tests can assert
/// the UI actually invoked start/stop.
class _CountingDnpHost extends DnpHost {
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

class _RunningDnpHost extends DnpHost {
  int stopCalls = 0;
  @override
  DnpHostStatus get status => DnpHostStatus.running;
  @override
  Future<void> stop() async {
    stopCalls++;
  }
}

/// A thin instrumented subclass of the REAL [EnipHost] — mirrors
/// [_CountingModbusHost]/[_CountingDnpHost]: still binds a real
/// (loopback, ephemeral-port) socket via the base class, but records call
/// counts so tests can assert the UI actually invoked start/stop.
class _CountingEnipHost extends EnipHost {
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

class _RunningEnipHost extends EnipHost {
  int stopCalls = 0;
  @override
  EnipHostStatus get status => EnipHostStatus.running;
  @override
  Future<void> stop() async {
    stopCalls++;
  }
}

Widget _app(
  PlcProject project,
  OpcUaHost host, {
  bool hostingSupported = true,
  ModbusHost? modbusHost,
  MqttHost? mqttHost,
  DnpHost? dnpHost,
  EnipHost? enipHost,
}) {
  return MaterialApp(
    home: GatewayScreen(
      currentProject: project,
      host: host,
      modbusHost: modbusHost ?? _CountingModbusHost(),
      mqttHost: mqttHost ?? MqttHost(),
      dnpHost: dnpHost ?? _CountingDnpHost(),
      enipHost: enipHost ?? _CountingEnipHost(),
      s7Host: S7Host(),
      finsHost: FinsHost(),
      slmpHost: SlmpHost(),
      onProjectUpdated: () {},
      hostingSupported: hostingSupported,
    ),
  );
}

/// Selects a protocol's tab via its `Tab` key (WS-tabs: the Outbound
/// Protocols screen moved from one long vertical list of four cards into a
/// scrollable `TabBar` + `TabBarView` — a protocol's card only exists in the
/// widget tree while its tab is selected, so any test targeting that
/// protocol's fields/switches must select its tab first). Keys avoid any
/// ambiguity with a card's own header text (e.g. the OPC UA tab's label,
/// 'OPC UA', is identical to the OPC UA card's title text once that card is
/// built).
const Key opcuaTabKey = Key('protocol_tab_opcua');
const Key modbusTabKey = Key('protocol_tab_modbus');
const Key mqttTabKey = Key('protocol_tab_mqtt');
const Key dnpTabKey = Key('protocol_tab_dnp3');
const Key enipTabKey = Key('protocol_tab_enip');
const Key s7TabKey = Key('protocol_tab_s7');
const Key finsTabKey = Key('protocol_tab_fins');
const Key slmpTabKey = Key('protocol_tab_slmp');

Future<void> _selectTab(WidgetTester tester, Key tabKey) async {
  // The TabBar is `isScrollable: true` (mobile-first — see the design spec),
  // so at narrow widths a not-yet-selected tab (e.g. MQTT/DNP3 at 320px) can
  // sit outside the visible strip and needs scrolling into view before it's
  // hit-testable.
  await tester.ensureVisible(find.byKey(tabKey));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(tabKey));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders "Outbound Protocols" title and OPC UA card', (tester) async {
    final project = _project();
    final host = _CountingOpcUaHost();
    addTearDown(host.dispose);

    await tester.pumpWidget(_app(project, host));
    await tester.pumpAndSettle();

    expect(find.text('Outbound Protocols'), findsOneWidget);
    // 'OPC UA' matches both the (always-present) tab label and the card's
    // own title — scope to the card (inside the TabBarView body) to check
    // the card specifically, not just the tab bar.
    expect(find.descendant(of: find.byType(TabBarView), matching: find.text('OPC UA')), findsOneWidget);
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

  group('OPC UA security config (WS19 Task 6)', () {
    testWidgets('None switch is always on and disabled (non-removable)', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('opcua_enable_switch')));
      await tester.pump();

      final noneSwitch = tester.widget<Switch>(
        find.byKey(const Key('opcua_security_none_switch')),
      );
      expect(noneSwitch.value, isTrue);
      expect(noneSwitch.onChanged, isNull);
      expect(project.protocols!.opcua!.securityModes, contains('None'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('toggling Basic256Sha256 Sign edits securityModes', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('opcua_enable_switch')));
      await tester.pump();

      expect(project.protocols!.opcua!.securityModes, isNot(contains('Basic256Sha256/Sign')));

      await tester.tap(find.byKey(const Key('opcua_security_sign_switch')));
      await tester.pump();
      expect(project.protocols!.opcua!.securityModes, contains('Basic256Sha256/Sign'));

      await tester.tap(find.byKey(const Key('opcua_security_sign_switch')));
      await tester.pump();
      expect(project.protocols!.opcua!.securityModes, isNot(contains('Basic256Sha256/Sign')));
      expect(tester.takeException(), isNull);
    });

    testWidgets('toggling Basic256Sha256 Sign & Encrypt edits securityModes', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('opcua_enable_switch')));
      await tester.pump();

      await tester.tap(find.byKey(const Key('opcua_security_sign_encrypt_switch')));
      await tester.pump();
      expect(
        project.protocols!.opcua!.securityModes,
        contains('Basic256Sha256/SignAndEncrypt'),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('toggling allow-anonymous edits allowAnonymous', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('opcua_enable_switch')));
      await tester.pump();

      expect(project.protocols!.opcua!.allowAnonymous, isTrue);
      await tester.ensureVisible(find.byKey(const Key('opcua_allow_anonymous_switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('opcua_allow_anonymous_switch')));
      await tester.pump();
      expect(project.protocols!.opcua!.allowAnonymous, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('adding, editing, and deleting a credential row edits config.credentials', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('opcua_enable_switch')));
      await tester.pump();

      expect(project.protocols!.opcua!.credentials, isEmpty);

      await tester.ensureVisible(find.byKey(const Key('opcua_add_credential_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('opcua_add_credential_button')));
      await tester.pump();
      expect(project.protocols!.opcua!.credentials.length, 1);

      await tester.ensureVisible(find.byKey(const Key('opcua_credential_username_0')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('opcua_credential_username_0')), 'operator');
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('opcua_credential_password_0')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('opcua_credential_password_0')), 's3cret');
      await tester.pump();

      expect(project.protocols!.opcua!.credentials.single.username, 'operator');
      expect(project.protocols!.opcua!.credentials.single.password, 's3cret');

      // Password never leaks into the persisted project JSON.
      final json = project.protocols!.opcua!.toJson();
      expect((json['credentials'] as List).single, {'username': 'operator'});

      await tester.ensureVisible(find.byKey(const Key('opcua_credential_delete_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('opcua_credential_delete_0')));
      await tester.pump();
      expect(project.protocols!.opcua!.credentials, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('app-cert thumbprint shows a placeholder until an identity is loaded, '
        'and the Regenerate button calls host.regenerateCertificate()', (tester) async {
      final project = _project();
      final host = _FakeCertOpcUaHost();
      addTearDown(host.dispose);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('opcua_enable_switch')));
      await tester.pump();

      expect(find.textContaining('Not yet generated'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('opcua_regenerate_cert_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('opcua_regenerate_cert_button')));
      await tester.pump();

      expect(host.regenerateCalls, 1);
      expect(find.textContaining('Not yet generated'), findsNothing);
      expect(find.byKey(const Key('opcua_cert_thumbprint_text')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow at 320 width with security section, credentials, and cert section shown', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      await setSurface(tester, smallPhoneSize);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('opcua_enable_switch')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('opcua_add_credential_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('opcua_add_credential_button')));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow at 1400 width with security section, credentials, and cert section shown', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      await setSurface(tester, desktopSize);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('opcua_enable_switch')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('opcua_add_credential_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('opcua_add_credential_button')));
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
      await _selectTab(tester, modbusTabKey);

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
      await _selectTab(tester, modbusTabKey);

      await tester.tap(find.byKey(const Key('modbus_enable_switch')));
      await tester.pump();

      expect(project.protocols?.modbus?.enabled, true);
      expect(find.text('Modbus Register Map'), findsOneWidget);
      expect(find.widgetWithText(TextField, '502'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Start hosting'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Stop hosting'), findsOneWidget);
      // Only the Modbus tab is on-screen (each protocol's card now lives in
      // its own tab), so only the Modbus card's status pill shows "Stopped".
      expect(find.text('Stopped'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders the word-swap switch and unit-id field with their defaults', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final modbusHost = _CountingModbusHost();
      addTearDown(modbusHost.dispose);

      await tester.pumpWidget(_app(project, host, modbusHost: modbusHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, modbusTabKey);

      await tester.tap(find.byKey(const Key('modbus_enable_switch')));
      await tester.pump();

      expect(find.byKey(const Key('modbus_word_swap_switch')), findsOneWidget);
      final wordSwapSwitch = tester.widget<Switch>(find.byKey(const Key('modbus_word_swap_switch')));
      expect(wordSwapSwitch.value, false);

      expect(find.byKey(const Key('modbus_byte_swap_switch')), findsOneWidget);
      final byteSwapSwitch = tester.widget<Switch>(find.byKey(const Key('modbus_byte_swap_switch')));
      expect(byteSwapSwitch.value, false);

      expect(find.byKey(const Key('modbus_unit_id_field')), findsOneWidget);
      expect(find.widgetWithText(TextField, '255'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('toggling the word-swap switch updates ModbusProtocolConfig.wordSwap', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final modbusHost = _CountingModbusHost();
      addTearDown(modbusHost.dispose);

      await tester.pumpWidget(_app(project, host, modbusHost: modbusHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, modbusTabKey);

      await tester.tap(find.byKey(const Key('modbus_enable_switch')));
      await tester.pump();
      expect(project.protocols?.modbus?.wordSwap, false);

      await tester.tap(find.byKey(const Key('modbus_word_swap_switch')));
      await tester.pump();

      expect(project.protocols?.modbus?.wordSwap, true);
      final wordSwapSwitch = tester.widget<Switch>(find.byKey(const Key('modbus_word_swap_switch')));
      expect(wordSwapSwitch.value, true);
      expect(tester.takeException(), isNull);
    });

    testWidgets('toggling the byte-swap switch updates ModbusProtocolConfig.byteSwap', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final modbusHost = _CountingModbusHost();
      addTearDown(modbusHost.dispose);

      await tester.pumpWidget(_app(project, host, modbusHost: modbusHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, modbusTabKey);

      await tester.tap(find.byKey(const Key('modbus_enable_switch')));
      await tester.pump();
      expect(project.protocols?.modbus?.byteSwap, false);

      await tester.tap(find.byKey(const Key('modbus_byte_swap_switch')));
      await tester.pump();

      expect(project.protocols?.modbus?.byteSwap, true);
      final byteSwapSwitch = tester.widget<Switch>(find.byKey(const Key('modbus_byte_swap_switch')));
      expect(byteSwapSwitch.value, true);
      expect(tester.takeException(), isNull);
    });

    testWidgets('editing the unit-id field updates ModbusProtocolConfig.unitId', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final modbusHost = _CountingModbusHost();
      addTearDown(modbusHost.dispose);

      await tester.pumpWidget(_app(project, host, modbusHost: modbusHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, modbusTabKey);

      await tester.tap(find.byKey(const Key('modbus_enable_switch')));
      await tester.pump();

      await tester.enterText(find.byKey(const Key('modbus_unit_id_field')), '12');
      await tester.pump();

      expect(project.protocols?.modbus?.unitId, 12);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an out-of-range unit id (>255) is ignored, keeping the last-valid value', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final modbusHost = _CountingModbusHost();
      addTearDown(modbusHost.dispose);

      await tester.pumpWidget(_app(project, host, modbusHost: modbusHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, modbusTabKey);

      await tester.tap(find.byKey(const Key('modbus_enable_switch')));
      await tester.pump();

      await tester.enterText(find.byKey(const Key('modbus_unit_id_field')), '9999');
      await tester.pump();

      expect(project.protocols?.modbus?.unitId, 255); // unchanged — 9999 rejected
      expect(tester.takeException(), isNull);
    });

    testWidgets('word-swap switch and unit-id field are locked while hosting is running', (tester) async {
      final project = _project();
      project.protocols = ProtocolSettings.defaults(project);
      project.protocols!.modbus!.enabled = true;
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final modbusHost = _RunningModbusHost();
      addTearDown(modbusHost.dispose);

      await tester.pumpWidget(_app(project, host, modbusHost: modbusHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, modbusTabKey);

      final wordSwapSwitch = tester.widget<Switch>(find.byKey(const Key('modbus_word_swap_switch')));
      expect(wordSwapSwitch.onChanged, isNull);

      final byteSwapSwitch = tester.widget<Switch>(find.byKey(const Key('modbus_byte_swap_switch')));
      expect(byteSwapSwitch.onChanged, isNull);

      final unitIdField = tester.widget<TextField>(find.byKey(const Key('modbus_unit_id_field')));
      expect(unitIdField.enabled, false);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders the Framing dropdown defaulting to Modbus TCP', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final modbusHost = _CountingModbusHost();
      addTearDown(modbusHost.dispose);

      await tester.pumpWidget(_app(project, host, modbusHost: modbusHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, modbusTabKey);

      await tester.tap(find.byKey(const Key('modbus_enable_switch')));
      await tester.pump();

      expect(find.byKey(const Key('modbus_framing_dropdown')), findsOneWidget);
      final dropdownFinder = find.byKey(const Key('modbus_framing_dropdown'));
      final dropdown = tester.widget<DropdownButtonFormField<String>>(dropdownFinder);
      expect(dropdown.initialValue, 'tcp');
      expect(find.descendant(of: dropdownFinder, matching: find.text('Modbus TCP')), findsOneWidget);
    });

    testWidgets('a project already set to rtuOverTcp displays RTU over TCP, not coerced to Modbus TCP',
        (tester) async {
      final project = _project();
      project.protocols = ProtocolSettings.defaults(project);
      project.protocols!.modbus!.enabled = true;
      project.protocols!.modbus!.framing = 'rtuOverTcp';
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final modbusHost = _CountingModbusHost();
      addTearDown(modbusHost.dispose);

      await tester.pumpWidget(_app(project, host, modbusHost: modbusHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, modbusTabKey);

      final dropdown = tester.widget<DropdownButtonFormField<String>>(
          find.byKey(const Key('modbus_framing_dropdown')));
      expect(dropdown.initialValue, 'rtuOverTcp');
      // Scope the text search to the dropdown itself — "Modbus TCP" also
      // appears as the card's own title text elsewhere on screen, so a
      // whole-tree search for it would be a false positive either way.
      final dropdownFinder = find.byKey(const Key('modbus_framing_dropdown'));
      expect(find.descendant(of: dropdownFinder, matching: find.text('RTU over TCP')), findsOneWidget);
      // Guards the coercion-class bug: must NOT silently display as tcp.
      expect(find.descendant(of: dropdownFinder, matching: find.text('Modbus TCP')), findsNothing);
    });

    testWidgets('changing the Framing dropdown updates ModbusProtocolConfig.framing', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final modbusHost = _CountingModbusHost();
      addTearDown(modbusHost.dispose);

      await tester.pumpWidget(_app(project, host, modbusHost: modbusHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, modbusTabKey);

      await tester.tap(find.byKey(const Key('modbus_enable_switch')));
      await tester.pump();
      expect(project.protocols?.modbus?.framing, 'tcp');

      await tester.ensureVisible(find.byKey(const Key('modbus_framing_dropdown')));
      await tester.tap(find.byKey(const Key('modbus_framing_dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('RTU over TCP').last);
      await tester.pumpAndSettle();

      expect(project.protocols?.modbus?.framing, 'rtuOverTcp');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Framing dropdown is disabled while hosting is running', (tester) async {
      final project = _project();
      project.protocols = ProtocolSettings.defaults(project);
      project.protocols!.modbus!.enabled = true;
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final modbusHost = _RunningModbusHost();
      addTearDown(modbusHost.dispose);

      await tester.pumpWidget(_app(project, host, modbusHost: modbusHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, modbusTabKey);

      final dropdown = tester.widget<DropdownButtonFormField<String>>(
          find.byKey(const Key('modbus_framing_dropdown')));
      expect(dropdown.onChanged, isNull);
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
      await _selectTab(tester, modbusTabKey);

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
      await _selectTab(tester, modbusTabKey);
      expect(find.text('No entries yet. Tap Regenerate to build a default map from the project tags.'),
          findsOneWidget);

      // The Framing dropdown + caption (Task 2) pushed the Regenerate button
      // further down the card, so it may sit outside the default 800x600
      // test viewport — scroll it into view before tapping.
      await tester.ensureVisible(find.widgetWithText(TextButton, 'Regenerate'));
      await tester.pumpAndSettle();
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
      await _selectTab(tester, modbusTabKey);
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
      await _selectTab(tester, modbusTabKey);
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
      await _selectTab(tester, modbusTabKey);
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
      await _selectTab(tester, modbusTabKey);
      await tester.tap(find.byKey(const Key('modbus_enable_switch')));
      await tester.pump();

      final startBtn = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Start hosting'),
      );
      expect(startBtn.onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow at 320 width with the Modbus and OPC UA cards expanded (each on its own tab)',
        (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final modbusHost = _CountingModbusHost();
      addTearDown(modbusHost.dispose);
      await setSurface(tester, smallPhoneSize);

      await tester.pumpWidget(_app(project, host, modbusHost: modbusHost));
      await tester.pumpAndSettle();
      // Each protocol's card now lives in its own tab, so expanding both
      // means selecting each tab in turn and toggling that tab's switch —
      // they can never be simultaneously on-screen anymore.
      await _selectTab(tester, modbusTabKey);
      await tester.tap(find.byKey(const Key('modbus_enable_switch')));
      await tester.pump();
      expect(tester.takeException(), isNull);

      await _selectTab(tester, opcuaTabKey);
      await tester.tap(find.byKey(const Key('opcua_enable_switch')));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow at 1400 width with the Modbus and OPC UA cards expanded (each on its own tab)',
        (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final modbusHost = _CountingModbusHost();
      addTearDown(modbusHost.dispose);
      await setSurface(tester, desktopSize);

      await tester.pumpWidget(_app(project, host, modbusHost: modbusHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, modbusTabKey);
      await tester.tap(find.byKey(const Key('modbus_enable_switch')));
      await tester.pump();
      expect(tester.takeException(), isNull);

      await _selectTab(tester, opcuaTabKey);
      await tester.tap(find.byKey(const Key('opcua_enable_switch')));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });

  group('MQTT / Sparkplug B card (WS-mqtt Task 5)', () {
    testWidgets('renders the MQTT card, starts disabled with config hidden', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final mqttHost = MqttHost();
      addTearDown(mqttHost.dispose);

      await tester.pumpWidget(_app(project, host, mqttHost: mqttHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, mqttTabKey);

      expect(find.text('MQTT / Sparkplug B'), findsOneWidget);
      expect(find.byKey(const Key('mqtt_enable_switch')), findsOneWidget);
      final sw = tester.widget<Switch>(find.byKey(const Key('mqtt_enable_switch')));
      expect(sw.value, false);
      expect(find.text('MQTT Tag Map'), findsNothing);
      expect(find.widgetWithText(ElevatedButton, 'Connect'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('toggling the MQTT switch ON reveals broker fields, controls, and map editor',
        (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final mqttHost = MqttHost();
      addTearDown(mqttHost.dispose);

      await tester.pumpWidget(_app(project, host, mqttHost: mqttHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, mqttTabKey);

      await tester.tap(find.byKey(const Key('mqtt_enable_switch')));
      await tester.pump();

      expect(project.protocols?.mqtt?.enabled, true);
      expect(find.text('MQTT Tag Map'), findsOneWidget);
      expect(find.widgetWithText(TextField, '1883'), findsOneWidget);
      expect(find.byKey(const Key('mqtt_tls_switch')), findsOneWidget);
      expect(find.byKey(const Key('mqtt_format_dropdown')), findsOneWidget);
      expect(find.text('Base topic'), findsOneWidget); // default format is 'json'
      expect(find.widgetWithText(ElevatedButton, 'Connect'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Disconnect'), findsOneWidget);
      expect(find.byKey(const Key('mqtt_password_field')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('switching payload format to sparkplug swaps base-topic for group/edge-node fields',
        (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final mqttHost = MqttHost();
      addTearDown(mqttHost.dispose);

      await tester.pumpWidget(_app(project, host, mqttHost: mqttHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, mqttTabKey);
      await tester.tap(find.byKey(const Key('mqtt_enable_switch')));
      await tester.pump();

      await tester.ensureVisible(find.byKey(const Key('mqtt_format_dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('mqtt_format_dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('sparkplug').last);
      await tester.pumpAndSettle();

      expect(project.protocols?.mqtt?.format, 'sparkplug');
      expect(find.text('Base topic'), findsNothing);
      expect(find.text('Group ID'), findsOneWidget);
      expect(find.text('Edge node ID'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'config-edit fields (format, group/edge-node, base topic, QoS, heartbeat, allow-remote-writes) '
        'are disabled while connected', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final mqttHost = _FakeConnectedMqttHost();
      addTearDown(mqttHost.dispose);

      await tester.pumpWidget(_app(project, host, mqttHost: mqttHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, mqttTabKey);
      await tester.tap(find.byKey(const Key('mqtt_enable_switch')));
      await tester.pump();

      // Default format is 'json' — Base topic is the visible topic field.
      final baseTopicField = tester.widget<TextFormField>(
        find.ancestor(of: find.text('Base topic'), matching: find.byType(TextFormField)).first,
      );
      expect(baseTopicField.enabled, isTrue);
      final formatDropdownBefore =
          tester.widget<DropdownButtonFormField<String>>(find.byKey(const Key('mqtt_format_dropdown')));
      expect(formatDropdownBefore.onChanged, isNotNull);
      final qosDropdownBefore =
          tester.widget<DropdownButtonFormField<int>>(find.byKey(const Key('mqtt_qos_dropdown')));
      expect(qosDropdownBefore.onChanged, isNotNull);
      final allowRemoteWritesBefore =
          tester.widget<Switch>(find.byKey(const Key('mqtt_allow_remote_writes_switch')));
      expect(allowRemoteWritesBefore.onChanged, isNotNull);

      mqttHost.setConnected();
      await tester.pump();

      final formatDropdown =
          tester.widget<DropdownButtonFormField<String>>(find.byKey(const Key('mqtt_format_dropdown')));
      expect(formatDropdown.onChanged, isNull, reason: 'format must be locked while connected');

      final baseTopicFieldConnected = tester.widget<TextFormField>(
        find.ancestor(of: find.text('Base topic'), matching: find.byType(TextFormField)).first,
      );
      expect(baseTopicFieldConnected.enabled, isFalse, reason: 'base topic must be locked while connected');

      final qosDropdown =
          tester.widget<DropdownButtonFormField<int>>(find.byKey(const Key('mqtt_qos_dropdown')));
      expect(qosDropdown.onChanged, isNull, reason: 'QoS must be locked while connected');

      final allowRemoteWrites =
          tester.widget<Switch>(find.byKey(const Key('mqtt_allow_remote_writes_switch')));
      expect(allowRemoteWrites.onChanged, isNotNull,
          reason: 'allow remote writes must stay toggleable while connected — it is safe to '
              'flip live (the host is always subscribed to the NCMD topic and re-reads the '
              'flag per message), unlike the format/topic/group/node fields which are locked');

      final heartbeatField = tester.widget<TextFormField>(
        find.ancestor(of: find.text('Heartbeat (s)'), matching: find.byType(TextFormField)).first,
      );
      expect(heartbeatField.enabled, isFalse, reason: 'heartbeat must be locked while connected');

      expect(tester.takeException(), isNull);
    });

    testWidgets('group/edge-node fields are disabled while connected (sparkplug format)', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final mqttHost = _FakeConnectedMqttHost();
      addTearDown(mqttHost.dispose);

      await tester.pumpWidget(_app(project, host, mqttHost: mqttHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, mqttTabKey);
      await tester.tap(find.byKey(const Key('mqtt_enable_switch')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const Key('mqtt_format_dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('mqtt_format_dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('sparkplug').last);
      await tester.pumpAndSettle();

      mqttHost.setConnected();
      await tester.pump();

      final groupIdField = tester.widget<TextFormField>(
        find.ancestor(of: find.text('Group ID'), matching: find.byType(TextFormField)).first,
      );
      expect(groupIdField.enabled, isFalse, reason: 'Group ID must be locked while connected');

      final edgeNodeField = tester.widget<TextFormField>(
        find.ancestor(of: find.text('Edge node ID'), matching: find.byType(TextFormField)).first,
      );
      expect(edgeNodeField.enabled, isFalse, reason: 'Edge node ID must be locked while connected');

      expect(tester.takeException(), isNull);
    });

    testWidgets('toggling the MQTT switch OFF hides the config again', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final mqttHost = MqttHost();
      addTearDown(mqttHost.dispose);

      await tester.pumpWidget(_app(project, host, mqttHost: mqttHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, mqttTabKey);
      await tester.tap(find.byKey(const Key('mqtt_enable_switch')));
      await tester.pump();
      expect(project.protocols?.mqtt?.enabled, true);

      await tester.tap(find.byKey(const Key('mqtt_enable_switch')));
      await tester.pump();

      expect(project.protocols?.mqtt?.enabled, false);
      expect(find.text('MQTT Tag Map'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Regenerate populates entries from the project tags', (tester) async {
      final project = _project();
      project.protocols = ProtocolSettings.defaults(project);
      project.protocols!.mqtt!.enabled = true;
      project.protocols!.mqtt!.map.entries.clear();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final mqttHost = MqttHost();
      addTearDown(mqttHost.dispose);

      await tester.pumpWidget(_app(project, host, mqttHost: mqttHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, mqttTabKey);
      expect(find.text('No entries yet. Tap Regenerate to build a default map from the project tags.'),
          findsOneWidget);

      final regenerateButton = find.widgetWithText(TextButton, 'Regenerate');
      // The MQTT card has many of its own fields below the map editor, so its
      // Regenerate button can be scrolled off the default test viewport —
      // scroll it into view before tapping.
      await tester.ensureVisible(regenerateButton);
      await tester.pumpAndSettle();
      await tester.tap(regenerateButton);
      await tester.pump();

      expect(project.protocols?.mqtt?.map.entries, isNotEmpty);
      expect(find.text('No entries yet. Tap Regenerate to build a default map from the project tags.'),
          findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('hosting unsupported (web): Connect disabled + native-only note shown', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final mqttHost = MqttHost();
      addTearDown(mqttHost.dispose);

      await tester.pumpWidget(_app(project, host, mqttHost: mqttHost, hostingSupported: false));
      await tester.pumpAndSettle();
      await _selectTab(tester, mqttTabKey);
      await tester.tap(find.byKey(const Key('mqtt_enable_switch')));
      await tester.pump();

      final connectBtn = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Connect'),
      );
      expect(connectBtn.onPressed, isNull);
      expect(find.textContaining('web browsers do not allow'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow at 320 width with each of the four cards expanded on its own tab', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final modbusHost = _CountingModbusHost();
      addTearDown(modbusHost.dispose);
      final mqttHost = MqttHost();
      addTearDown(mqttHost.dispose);
      final dnpHost = _CountingDnpHost();
      addTearDown(dnpHost.dispose);
      await setSurface(tester, smallPhoneSize);

      await tester.pumpWidget(_app(project, host, modbusHost: modbusHost, mqttHost: mqttHost, dnpHost: dnpHost));
      await tester.pumpAndSettle();
      // Each protocol's card now lives in its own tab (never simultaneously
      // on-screen with another), so expanding "all four" means visiting each
      // tab in turn and toggling that tab's switch there.
      await _selectTab(tester, mqttTabKey);
      await tester.tap(find.byKey(const Key('mqtt_enable_switch')));
      await tester.pump();
      expect(tester.takeException(), isNull);

      await _selectTab(tester, modbusTabKey);
      await tester.tap(find.byKey(const Key('modbus_enable_switch')));
      await tester.pump();
      expect(tester.takeException(), isNull);

      await _selectTab(tester, dnpTabKey);
      await tester.tap(find.byKey(const Key('dnp_enable_switch')));
      await tester.pump();
      expect(tester.takeException(), isNull);

      await _selectTab(tester, opcuaTabKey);
      await tester.tap(find.byKey(const Key('opcua_enable_switch')));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow at 1400 width with each of the four cards expanded on its own tab', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final modbusHost = _CountingModbusHost();
      addTearDown(modbusHost.dispose);
      final mqttHost = MqttHost();
      addTearDown(mqttHost.dispose);
      final dnpHost = _CountingDnpHost();
      addTearDown(dnpHost.dispose);
      await setSurface(tester, desktopSize);

      await tester.pumpWidget(_app(project, host, modbusHost: modbusHost, mqttHost: mqttHost, dnpHost: dnpHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, mqttTabKey);
      await tester.tap(find.byKey(const Key('mqtt_enable_switch')));
      await tester.pump();
      expect(tester.takeException(), isNull);

      await _selectTab(tester, modbusTabKey);
      await tester.tap(find.byKey(const Key('modbus_enable_switch')));
      await tester.pump();
      expect(tester.takeException(), isNull);

      await _selectTab(tester, dnpTabKey);
      await tester.tap(find.byKey(const Key('dnp_enable_switch')));
      await tester.pump();
      expect(tester.takeException(), isNull);

      await _selectTab(tester, opcuaTabKey);
      await tester.tap(find.byKey(const Key('opcua_enable_switch')));
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });

  group('MQTT manual Rebirth button + live map editing (mqtt-rebirth-live-tags)', () {
    testWidgets('Rebirth button exists and is disabled while disconnected', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final mqttHost = MqttHost();
      addTearDown(mqttHost.dispose);

      await tester.pumpWidget(_app(project, host, mqttHost: mqttHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, mqttTabKey);
      await tester.tap(find.byKey(const Key('mqtt_enable_switch')));
      await tester.pump();

      expect(find.byKey(const Key('mqtt_rebirth_button')), findsOneWidget);
      final button = tester.widget<OutlinedButton>(find.byKey(const Key('mqtt_rebirth_button')));
      expect(button.onPressed, isNull, reason: 'Rebirth must be disabled while disconnected');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Rebirth button is disabled when connected with JSON format (default)', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final mqttHost = _FakeConnectedMqttHost();
      addTearDown(mqttHost.dispose);

      await tester.pumpWidget(_app(project, host, mqttHost: mqttHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, mqttTabKey);
      await tester.tap(find.byKey(const Key('mqtt_enable_switch')));
      await tester.pump();
      // Default format is 'json'.
      mqttHost.setConnected();
      await tester.pump();

      final button = tester.widget<OutlinedButton>(find.byKey(const Key('mqtt_rebirth_button')));
      expect(button.onPressed, isNull, reason: 'Rebirth is meaningless for JSON format (no rebirth concept)');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Rebirth button is enabled when connected with Sparkplug format, and tapping it calls the host',
        (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final mqttHost = _FakeConnectedMqttHost();
      addTearDown(mqttHost.dispose);

      await tester.pumpWidget(_app(project, host, mqttHost: mqttHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, mqttTabKey);
      await tester.tap(find.byKey(const Key('mqtt_enable_switch')));
      await tester.pump();

      await tester.ensureVisible(find.byKey(const Key('mqtt_format_dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('mqtt_format_dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('sparkplug').last);
      await tester.pumpAndSettle();

      mqttHost.setConnected();
      await tester.pump();

      final buttonFinder = find.byKey(const Key('mqtt_rebirth_button'));
      await tester.ensureVisible(buttonFinder);
      await tester.pumpAndSettle();
      final button = tester.widget<OutlinedButton>(buttonFinder);
      expect(button.onPressed, isNotNull,
          reason: 'Rebirth must be enabled once connected with Sparkplug format');

      await tester.tap(buttonFinder);
      await tester.pump();

      expect(mqttHost.rebirthCalls, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the map editor (Add entry, per-row tag/metric/writable/delete) stays enabled while connected',
        (tester) async {
      final project = _project();
      project.protocols = ProtocolSettings.defaults(project);
      project.protocols!.mqtt!.enabled = true;
      project.protocols!.mqtt!.format = 'sparkplug';
      project.protocols!.mqtt!.map.entries.clear();
      project.protocols!.mqtt!.map.entries.add(
        MqttMapEntry(tag: 'Inputs.Start_PB', metric: 'Start_PB', writable: false),
      );
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final mqttHost = _ConnectedMqttHost();
      addTearDown(mqttHost.dispose);

      await tester.pumpWidget(_app(project, host, mqttHost: mqttHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, mqttTabKey);

      // "Add entry" must still be tappable while connected — adding a mapped
      // tag live is safe (unlike editing format/topic/group/node), the user
      // just needs to press Rebirth afterwards.
      final addEntryButton = find.widgetWithText(TextButton, 'Add entry');
      await tester.ensureVisible(addEntryButton);
      await tester.pumpAndSettle();
      final entryCountBefore = project.protocols!.mqtt!.map.entries.length;
      await tester.tap(addEntryButton);
      await tester.pump();
      expect(project.protocols!.mqtt!.map.entries.length, entryCountBefore + 1,
          reason: 'Add entry must work while connected');

      // A per-row control (the writable Switch on the first row) must also
      // remain enabled/tappable while connected.
      final rowSwitch = find.byType(Switch).last;
      await tester.ensureVisible(rowSwitch);
      await tester.pumpAndSettle();
      final switchWidget = tester.widget<Switch>(rowSwitch);
      expect(switchWidget.onChanged, isNotNull, reason: 'per-row writable switch must stay enabled while connected');

      // The connected hint nudging the user toward Rebirth should be visible
      // (Sparkplug format + connected).
      expect(find.textContaining('tap Rebirth above'), findsOneWidget);

      expect(tester.takeException(), isNull);
    });
  });

  group('DNP3 outstation card (WS26 Task 5)', () {
    testWidgets('renders the DNP3 card, starts disabled with config hidden', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final dnpHost = _CountingDnpHost();
      addTearDown(dnpHost.dispose);

      await tester.pumpWidget(_app(project, host, dnpHost: dnpHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, dnpTabKey);

      // 'DNP3' matches both the tab label and the card's own title — scope
      // to the card (inside the TabBarView body) to check the card
      // specifically.
      expect(find.descendant(of: find.byType(TabBarView), matching: find.text('DNP3')), findsOneWidget);
      expect(find.byKey(const Key('dnp_enable_switch')), findsOneWidget);
      final sw = tester.widget<Switch>(find.byKey(const Key('dnp_enable_switch')));
      expect(sw.value, false);
      expect(find.text('DNP3 Point Map'), findsNothing);
      expect(find.widgetWithText(ElevatedButton, 'Start hosting'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('toggling the DNP3 switch ON reveals port, addresses, hosting controls, and map editor',
        (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final dnpHost = _CountingDnpHost();
      addTearDown(dnpHost.dispose);

      await tester.pumpWidget(_app(project, host, dnpHost: dnpHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, dnpTabKey);

      await tester.tap(find.byKey(const Key('dnp_enable_switch')));
      await tester.pump();

      expect(project.protocols?.dnp3?.enabled, true);
      expect(find.text('DNP3 Point Map'), findsOneWidget);
      expect(find.widgetWithText(TextField, '20000'), findsOneWidget);
      expect(find.widgetWithText(TextField, '1024'), findsOneWidget);
      expect(find.widgetWithText(TextField, '1'), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Start hosting'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Stop hosting'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('toggling the DNP3 switch OFF hides the config again', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final dnpHost = _CountingDnpHost();
      addTearDown(dnpHost.dispose);

      await tester.pumpWidget(_app(project, host, dnpHost: dnpHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, dnpTabKey);

      await tester.tap(find.byKey(const Key('dnp_enable_switch')));
      await tester.pump();
      expect(project.protocols?.dnp3?.enabled, true);

      await tester.tap(find.byKey(const Key('dnp_enable_switch')));
      await tester.pump();

      expect(project.protocols?.dnp3?.enabled, false);
      expect(find.text('DNP3 Point Map'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Regenerate populates entries from the project tags', (tester) async {
      final project = _project();
      project.protocols = ProtocolSettings.defaults(project);
      project.protocols!.dnp3!.enabled = true;
      project.protocols!.dnp3!.map.entries.clear();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final dnpHost = _CountingDnpHost();
      addTearDown(dnpHost.dispose);

      await tester.pumpWidget(_app(project, host, dnpHost: dnpHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, dnpTabKey);
      expect(find.text('No entries yet. Tap Regenerate to build a default map from the project tags.'),
          findsOneWidget);

      final regenerateButton = find.widgetWithText(TextButton, 'Regenerate').last;
      await tester.ensureVisible(regenerateButton);
      await tester.pumpAndSettle();
      await tester.tap(regenerateButton);
      await tester.pump();

      expect(project.protocols?.dnp3?.map.entries, isNotEmpty);
      expect(find.text('No entries yet. Tap Regenerate to build a default map from the project tags.'),
          findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('DNP3 card exposes an event-Class dropdown on input rows, and editing it sets eventClass',
        (tester) async {
      final project = _project();
      project.protocols = ProtocolSettings.defaults(project);
      project.protocols!.dnp3!.enabled = true;
      final inputEntry = DnpMapEntry(tag: 'Start_PB', pointType: 'binaryInput', index: 0);
      final outputEntry = DnpMapEntry(tag: 'Motor_Run', pointType: 'binaryOutput', index: 0);
      project.protocols!.dnp3!.map = DnpMap(entries: [inputEntry, outputEntry]);
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final dnpHost = _CountingDnpHost();
      addTearDown(dnpHost.dispose);
      await setSurface(tester, desktopSize);

      await tester.pumpWidget(_app(project, host, dnpHost: dnpHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, dnpTabKey);

      // Both the input row and the output row show the event-Class dropdown
      // now (all four DNP3 point types support events), each defaulting to
      // Static. Row order follows map.entries order: input row first.
      final dropdownFinder = find.byKey(const Key('dnp_event_class_dropdown'));
      expect(dropdownFinder, findsNWidgets(2), reason: 'both input and output rows get an event-Class dropdown');
      expect(inputEntry.eventClass, 0);
      expect(outputEntry.eventClass, 0);

      await tester.tap(dropdownFinder.first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Class 2').last);
      await tester.pumpAndSettle();

      expect(inputEntry.eventClass, 2);
      expect(outputEntry.eventClass, 0, reason: 'editing the input row dropdown leaves the output row untouched');
      expect(tester.takeException(), isNull);
    });

    testWidgets('DNP3 card exposes an event-Class dropdown on output rows too, and editing it sets eventClass',
        (tester) async {
      final project = _project();
      project.protocols = ProtocolSettings.defaults(project);
      project.protocols!.dnp3!.enabled = true;
      final outputEntry = DnpMapEntry(tag: 'Motor_Run', pointType: 'binaryOutput', index: 0);
      project.protocols!.dnp3!.map = DnpMap(entries: [outputEntry]);
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final dnpHost = _CountingDnpHost();
      addTearDown(dnpHost.dispose);
      await setSurface(tester, desktopSize);

      await tester.pumpWidget(_app(project, host, dnpHost: dnpHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, dnpTabKey);

      final dropdownFinder = find.byKey(const Key('dnp_event_class_dropdown'));
      expect(dropdownFinder, findsOneWidget, reason: 'the binaryOutput row shows the event-Class dropdown');
      expect(outputEntry.eventClass, 0);

      await tester.tap(dropdownFinder);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Class 1').last);
      await tester.pumpAndSettle();

      expect(outputEntry.eventClass, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Start hosting calls the injected DNP3 host and shows Running + endpoint', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final dnpHost = _CountingDnpHost();
      addTearDown(dnpHost.dispose);

      await tester.pumpWidget(_app(project, host, dnpHost: dnpHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, dnpTabKey);
      await tester.tap(find.byKey(const Key('dnp_enable_switch')));
      await tester.pump();
      // Port 0 -> the OS picks an ephemeral free port, never colliding with a
      // real port or leaking a fixed one across test runs.
      await tester.enterText(find.widgetWithText(TextField, '20000'), '0');
      await tester.pump();

      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(ElevatedButton, 'Start hosting'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();

      expect(dnpHost.startCalls, 1);
      expect(find.text('Running'), findsOneWidget);
      expect(find.textContaining('dnp3://'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Stop hosting calls the injected DNP3 host and returns to Stopped', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final dnpHost = _CountingDnpHost();
      addTearDown(dnpHost.dispose);

      await tester.pumpWidget(_app(project, host, dnpHost: dnpHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, dnpTabKey);
      await tester.tap(find.byKey(const Key('dnp_enable_switch')));
      await tester.pump();
      await tester.enterText(find.widgetWithText(TextField, '20000'), '0');
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

      expect(dnpHost.stopCalls, 1);
      expect(find.text('Stopped'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('hosting unsupported (web): DNP3 Start hosting disabled + native-only note shown', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final dnpHost = _CountingDnpHost();
      addTearDown(dnpHost.dispose);

      await tester.pumpWidget(_app(project, host, dnpHost: dnpHost, hostingSupported: false));
      await tester.pumpAndSettle();
      await _selectTab(tester, dnpTabKey);
      await tester.tap(find.byKey(const Key('dnp_enable_switch')));
      await tester.pump();

      final startBtn = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, 'Start hosting'),
      );
      expect(startBtn.onPressed, isNull);
      expect(find.textContaining('web browsers do not allow'), findsOneWidget);
      expect(dnpHost.startCalls, 0);
      expect(tester.takeException(), isNull);
    });
  });

  group('auto-stop hosting when a protocol is disabled', () {
    testWidgets('toggling OPC UA enable OFF while running stops the host', (tester) async {
      final project = _project(port: 0); // opcua enabled=true + config present
      final host = _RunningOpcUaHost();
      addTearDown(host.dispose);
      await setSurface(tester, desktopSize);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      // Switch starts ON (enabled); tap to turn it OFF.
      await tester.tap(find.byKey(const Key('opcua_enable_switch')));
      await tester.pump();

      expect(host.stopCalls, 1);
      expect(project.protocols!.opcua!.enabled, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('toggling Modbus enable OFF while running stops the host', (tester) async {
      final project = _project();
      project.protocols = ProtocolSettings.defaults(project);
      project.protocols!.modbus!.enabled = true;
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final modbusHost = _RunningModbusHost();
      addTearDown(modbusHost.dispose);
      await setSurface(tester, desktopSize);

      await tester.pumpWidget(_app(project, host, modbusHost: modbusHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, modbusTabKey);
      await tester.tap(find.byKey(const Key('modbus_enable_switch')));
      await tester.pump();

      expect(modbusHost.stopCalls, 1);
      expect(project.protocols!.modbus!.enabled, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('toggling DNP3 enable OFF while running stops the host', (tester) async {
      final project = _project();
      project.protocols = ProtocolSettings.defaults(project);
      project.protocols!.dnp3!.enabled = true;
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final dnpHost = _RunningDnpHost();
      addTearDown(dnpHost.dispose);
      await setSurface(tester, desktopSize);

      await tester.pumpWidget(_app(project, host, dnpHost: dnpHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, dnpTabKey);
      await tester.tap(find.byKey(const Key('dnp_enable_switch')));
      await tester.pump();

      expect(dnpHost.stopCalls, 1);
      expect(project.protocols!.dnp3!.enabled, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('toggling MQTT enable OFF while connected disconnects the client', (tester) async {
      final project = _project();
      project.protocols = ProtocolSettings.defaults(project);
      project.protocols!.mqtt!.enabled = true;
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final mqttHost = _ConnectedMqttHost();
      addTearDown(mqttHost.dispose);
      await setSurface(tester, desktopSize);

      await tester.pumpWidget(_app(project, host, mqttHost: mqttHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, mqttTabKey);
      await tester.tap(find.byKey(const Key('mqtt_enable_switch')));
      await tester.pump();

      expect(mqttHost.disconnectCalls, 1);
      expect(project.protocols!.mqtt!.enabled, isFalse);
      expect(tester.takeException(), isNull);
    });
  });

  group('Outbound Protocols tab structure (WS-tabs)', () {
    testWidgets('renders all five protocol tabs', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();

      expect(find.byKey(opcuaTabKey), findsOneWidget);
      expect(find.byKey(modbusTabKey), findsOneWidget);
      expect(find.byKey(mqttTabKey), findsOneWidget);
      expect(find.byKey(dnpTabKey), findsOneWidget);
      expect(find.byKey(enipTabKey), findsOneWidget);
      // OPC UA is the default (index 0) selected tab, so its card (with the
      // same title text, 'OPC UA') is simultaneously on-screen — scope to
      // the TabBar itself to check the tab label specifically. The other
      // four tabs' cards aren't built yet, so their labels are unambiguous.
      expect(find.descendant(of: find.byType(TabBar), matching: find.text('OPC UA')), findsOneWidget);
      expect(find.text('Modbus'), findsOneWidget);
      expect(find.text('MQTT'), findsOneWidget);
      expect(find.text('DNP3'), findsOneWidget);
      expect(find.text('EtherNet/IP'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping each tab shows that protocol\'s card and hides the others', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final modbusHost = _CountingModbusHost();
      addTearDown(modbusHost.dispose);
      final mqttHost = MqttHost();
      addTearDown(mqttHost.dispose);
      final dnpHost = _CountingDnpHost();
      addTearDown(dnpHost.dispose);
      final enipHost = _CountingEnipHost();
      addTearDown(enipHost.dispose);

      await tester.pumpWidget(_app(project, host,
          modbusHost: modbusHost, mqttHost: mqttHost, dnpHost: dnpHost, enipHost: enipHost));
      await tester.pumpAndSettle();

      // Each protocol's enable-switch key is a stable, unique fingerprint for
      // its card, present regardless of that protocol's enabled/disabled
      // state — exactly one of these five must be found at a time, matching
      // whichever tab is currently selected.
      const protocolSwitchKeys = [
        Key('opcua_enable_switch'),
        Key('modbus_enable_switch'),
        Key('mqtt_enable_switch'),
        Key('dnp_enable_switch'),
        Key('enip_enable_switch'),
      ];
      const tabKeys = [opcuaTabKey, modbusTabKey, mqttTabKey, dnpTabKey, enipTabKey];

      for (var selected = 0; selected < tabKeys.length; selected++) {
        await _selectTab(tester, tabKeys[selected]);
        for (var other = 0; other < protocolSwitchKeys.length; other++) {
          final finder = find.byKey(protocolSwitchKeys[other]);
          if (other == selected) {
            expect(finder, findsOneWidget,
                reason: 'tab ${tabKeys[selected]} should show its own card');
          } else {
            expect(finder, findsNothing,
                reason: 'tab ${tabKeys[selected]} should hide ${protocolSwitchKeys[other]}\'s card');
          }
        }
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow at 320 width across all tabs', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final modbusHost = _CountingModbusHost();
      addTearDown(modbusHost.dispose);
      final mqttHost = MqttHost();
      addTearDown(mqttHost.dispose);
      final dnpHost = _CountingDnpHost();
      addTearDown(dnpHost.dispose);
      final enipHost = _CountingEnipHost();
      addTearDown(enipHost.dispose);
      await setSurface(tester, smallPhoneSize);

      await tester.pumpWidget(_app(project, host,
          modbusHost: modbusHost, mqttHost: mqttHost, dnpHost: dnpHost, enipHost: enipHost));
      await tester.pumpAndSettle();

      for (final tabKey in const [opcuaTabKey, modbusTabKey, mqttTabKey, dnpTabKey, enipTabKey, s7TabKey, finsTabKey, slmpTabKey]) {
        await _selectTab(tester, tabKey);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('no overflow at 360 width across all tabs', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final modbusHost = _CountingModbusHost();
      addTearDown(modbusHost.dispose);
      final mqttHost = MqttHost();
      addTearDown(mqttHost.dispose);
      final dnpHost = _CountingDnpHost();
      addTearDown(dnpHost.dispose);
      final enipHost = _CountingEnipHost();
      addTearDown(enipHost.dispose);
      await setSurface(tester, const Size(360, 800));

      await tester.pumpWidget(_app(project, host,
          modbusHost: modbusHost, mqttHost: mqttHost, dnpHost: dnpHost, enipHost: enipHost));
      await tester.pumpAndSettle();

      for (final tabKey in const [opcuaTabKey, modbusTabKey, mqttTabKey, dnpTabKey, enipTabKey, s7TabKey, finsTabKey, slmpTabKey]) {
        await _selectTab(tester, tabKey);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('no overflow at 1400 width across all tabs', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final modbusHost = _CountingModbusHost();
      addTearDown(modbusHost.dispose);
      final mqttHost = MqttHost();
      addTearDown(mqttHost.dispose);
      final dnpHost = _CountingDnpHost();
      addTearDown(dnpHost.dispose);
      final enipHost = _CountingEnipHost();
      addTearDown(enipHost.dispose);
      await setSurface(tester, desktopSize);

      await tester.pumpWidget(_app(project, host,
          modbusHost: modbusHost, mqttHost: mqttHost, dnpHost: dnpHost, enipHost: enipHost));
      await tester.pumpAndSettle();

      for (final tabKey in const [opcuaTabKey, modbusTabKey, mqttTabKey, dnpTabKey, enipTabKey, s7TabKey, finsTabKey, slmpTabKey]) {
        await _selectTab(tester, tabKey);
        expect(tester.takeException(), isNull);
      }
    });
  });

  group('EtherNet/IP card', () {
    testWidgets('enable switch defaults to off and shows the disabled message', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await _selectTab(tester, enipTabKey);

      expect(find.byKey(const Key('enip_enable_switch')), findsOneWidget);
      final sw = tester.widget<Switch>(find.byKey(const Key('enip_enable_switch')));
      expect(sw.value, isFalse);
      expect(find.textContaining('Disabled'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('enabling shows the port field (default 44818), map editor, and hosting buttons',
        (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await _selectTab(tester, enipTabKey);

      await tester.tap(find.byKey(const Key('enip_enable_switch')));
      await tester.pump();

      expect(project.protocols!.ethernetIp!.enabled, isTrue);
      expect(project.protocols!.ethernetIp!.port, 44818);
      expect(find.text('Start hosting'), findsOneWidget);
      expect(find.text('Stop hosting'), findsOneWidget);
      expect(find.text('EtherNet/IP Tag Map'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Start hosting calls enipHost.start; Stop hosting calls enipHost.stop', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final enipHost = _CountingEnipHost();
      addTearDown(enipHost.dispose);

      await tester.pumpWidget(_app(project, host, enipHost: enipHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, enipTabKey);

      await tester.tap(find.byKey(const Key('enip_enable_switch')));
      await tester.pump();
      // Port 0 -> the OS picks an ephemeral free port, never colliding with a
      // real port or leaking a fixed one across test runs.
      await tester.enterText(find.widgetWithText(TextField, '44818'), '0');
      await tester.pump();

      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(ElevatedButton, 'Start hosting'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(enipHost.startCalls, 1);
      expect(enipHost.status, EnipHostStatus.running);

      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(OutlinedButton, 'Stop hosting'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(enipHost.stopCalls, 1);
      expect(enipHost.status, EnipHostStatus.stopped);
      expect(tester.takeException(), isNull);
    });

    testWidgets('disabling while hosting tears the host down (auto-stop-on-disable)', (tester) async {
      final project = _project();
      project.protocols = ProtocolSettings.defaults(project);
      project.protocols!.ethernetIp!.enabled = true;
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final enipHost = _RunningEnipHost();
      addTearDown(enipHost.dispose);

      await tester.pumpWidget(_app(project, host, enipHost: enipHost));
      await tester.pumpAndSettle();
      await _selectTab(tester, enipTabKey);
      await tester.tap(find.byKey(const Key('enip_enable_switch')));
      await tester.pump();

      expect(enipHost.stopCalls, 1);
      expect(project.protocols!.ethernetIp!.enabled, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('port field edits update the project config', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await _selectTab(tester, enipTabKey);
      await tester.tap(find.byKey(const Key('enip_enable_switch')));
      await tester.pump();

      await tester.enterText(find.byType(TextField).first, '44819');
      await tester.pump();

      expect(project.protocols!.ethernetIp!.port, 44819);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Add entry / Regenerate / delete route through onProjectUpdated', (tester) async {
      final project = _project();
      project.protocols = ProtocolSettings.defaults(project);
      project.protocols!.ethernetIp!.enabled = true;
      project.protocols!.ethernetIp!.map.entries.clear();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      var updates = 0;

      await tester.pumpWidget(MaterialApp(
        home: GatewayScreen(
          currentProject: project,
          host: host,
          modbusHost: _CountingModbusHost(),
          mqttHost: MqttHost(),
          dnpHost: _CountingDnpHost(),
          enipHost: _CountingEnipHost(),
          s7Host: S7Host(),
          finsHost: FinsHost(),
          slmpHost: SlmpHost(),
          onProjectUpdated: () => updates++,
        ),
      ));
      await tester.pumpAndSettle();
      await _selectTab(tester, enipTabKey);

      expect(find.textContaining('No entries yet'), findsOneWidget);

      await tester.tap(find.text('Add entry'));
      await tester.pump();
      expect(project.protocols!.ethernetIp!.map.entries.length, 1);
      expect(updates, greaterThan(0));

      await tester.tap(find.text('Regenerate'));
      await tester.pump();
      expect(project.protocols!.ethernetIp!.map.entries, isNotEmpty);

      final beforeDelete = project.protocols!.ethernetIp!.map.entries.length;
      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await tester.pump();
      expect(project.protocols!.ethernetIp!.map.entries.length, beforeDelete - 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow at 320 width with the EtherNet/IP card expanded', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      await setSurface(tester, smallPhoneSize);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await _selectTab(tester, enipTabKey);
      await tester.tap(find.byKey(const Key('enip_enable_switch')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow at 1400 width with the EtherNet/IP card expanded', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      await setSurface(tester, desktopSize);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await _selectTab(tester, enipTabKey);
      await tester.tap(find.byKey(const Key('enip_enable_switch')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('S7comm card', () {
    testWidgets('renders its enable toggle, and the port field defaults to 102', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await _selectTab(tester, s7TabKey);

      expect(find.byKey(const Key('s7_enable_switch')), findsOneWidget);
      final sw = tester.widget<Switch>(find.byKey(const Key('s7_enable_switch')));
      expect(sw.value, isFalse, reason: 'S7comm hosting is opt-in and starts disabled');
      // The port field only exists once the card is enabled.
      expect(find.byKey(const Key('s7_port_field')), findsNothing);

      await tester.tap(find.byKey(const Key('s7_enable_switch')));
      await tester.pumpAndSettle();

      expect(project.protocols!.s7!.enabled, isTrue);
      expect(project.protocols!.s7!.port, 102);
      final portField = tester.widget<TextField>(find.byKey(const Key('s7_port_field')));
      expect(portField.controller!.text, '102');
      expect(find.text('Default: 102'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the privileged-port note is shown for 102 and disappears above 1023',
        (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await _selectTab(tester, s7TabKey);
      await tester.tap(find.byKey(const Key('s7_enable_switch')));
      await tester.pumpAndSettle();

      // 102 is below 1024, so the elevation caveat must be visible.
      expect(find.byKey(const Key('s7_privileged_port_note')), findsOneWidget);

      await tester.enterText(find.byKey(const Key('s7_port_field')), '10102');
      await tester.pumpAndSettle();

      expect(project.protocols!.s7!.port, 10102);
      expect(find.byKey(const Key('s7_privileged_port_note')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a bind failure is surfaced as a labelled error block, not as a card that '
        'merely failed to turn green', (tester) async {
      final project = _project();
      project.protocols = ProtocolSettings.defaults(project);
      project.protocols!.s7!.enabled = true;
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      final s7Host = S7Host();
      addTearDown(s7Host.dispose);

      await tester.pumpWidget(MaterialApp(
        home: GatewayScreen(
          currentProject: project,
          host: host,
          modbusHost: _CountingModbusHost(),
          mqttHost: MqttHost(),
          dnpHost: _CountingDnpHost(),
          enipHost: _CountingEnipHost(),
          s7Host: s7Host,
          finsHost: FinsHost(),
          slmpHost: SlmpHost(),
          onProjectUpdated: () {},
        ),
      ));
      await tester.pumpAndSettle();
      await _selectTab(tester, s7TabKey);

      expect(find.byKey(const Key('s7_error_banner')), findsNothing);

      // A start against a project whose S7comm config is missing/disabled is
      // the deterministic error path (no socket involved), which is what this
      // banner has to render.
      project.protocols!.s7!.enabled = false;
      await s7Host.start(() => project);
      await tester.pumpAndSettle();

      expect(s7Host.status, S7HostStatus.error);
      expect(find.byKey(const Key('s7_error_banner')), findsOneWidget);
      expect(find.text('Not hosting — the server did not start.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Add entry / Regenerate / delete route through onProjectUpdated', (tester) async {
      final project = _project();
      project.protocols = ProtocolSettings.defaults(project);
      project.protocols!.s7!.enabled = true;
      project.protocols!.s7!.map.entries.clear();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      var updates = 0;

      await tester.pumpWidget(MaterialApp(
        home: GatewayScreen(
          currentProject: project,
          host: host,
          modbusHost: _CountingModbusHost(),
          mqttHost: MqttHost(),
          dnpHost: _CountingDnpHost(),
          enipHost: _CountingEnipHost(),
          s7Host: S7Host(),
          finsHost: FinsHost(),
          slmpHost: SlmpHost(),
          onProjectUpdated: () => updates++,
        ),
      ));
      await tester.pumpAndSettle();
      await _selectTab(tester, s7TabKey);

      expect(find.textContaining('No entries yet'), findsOneWidget);

      await tester.tap(find.text('Add entry'));
      await tester.pump();
      expect(project.protocols!.s7!.map.entries.length, 1);
      expect(updates, greaterThan(0));

      await tester.tap(find.text('Regenerate'));
      await tester.pump();
      expect(project.protocols!.s7!.map.entries, isNotEmpty);

      final beforeDelete = project.protocols!.s7!.map.entries.length;
      // The S7 row carries more fields than the other protocols' rows, so at
      // the default 800x600 test surface its delete button can sit below the
      // fold — scroll it in before tapping, or the tap silently misses.
      await tester.ensureVisible(find.byIcon(Icons.delete_outline).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await tester.pump();
      expect(project.protocols!.s7!.map.entries.length, beforeDelete - 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow at 320 width with the S7comm card expanded', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      await setSurface(tester, smallPhoneSize);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await _selectTab(tester, s7TabKey);
      await tester.tap(find.byKey(const Key('s7_enable_switch')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow at 360 width with the S7comm card expanded', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      await setSurface(tester, phoneSize);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await _selectTab(tester, s7TabKey);
      await tester.tap(find.byKey(const Key('s7_enable_switch')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow at 1400 width with the S7comm card expanded', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      await setSurface(tester, desktopSize);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await _selectTab(tester, s7TabKey);
      await tester.tap(find.byKey(const Key('s7_enable_switch')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('FINS card', () {
    testWidgets('renders its enable toggle, and the port field defaults to 9600', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await _selectTab(tester, finsTabKey);

      expect(find.byKey(const Key('fins_enable_switch')), findsOneWidget);
      final sw = tester.widget<Switch>(find.byKey(const Key('fins_enable_switch')));
      expect(sw.value, isFalse, reason: 'FINS hosting is opt-in and starts disabled');
      // The port field only exists once the card is enabled.
      expect(find.byKey(const Key('fins_port_field')), findsNothing);

      await tester.tap(find.byKey(const Key('fins_enable_switch')));
      await tester.pumpAndSettle();

      expect(project.protocols!.fins!.enabled, isTrue);
      expect(project.protocols!.fins!.port, 9600);
      final portField = tester.widget<TextField>(find.byKey(const Key('fins_port_field')));
      expect(portField.controller!.text, '9600');
      expect(find.text('Default: 9600'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('port 9600 shows NO privileged-port note (it is above 1023)', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await _selectTab(tester, finsTabKey);
      await tester.tap(find.byKey(const Key('fins_enable_switch')));
      await tester.pumpAndSettle();

      // Unlike S7comm's port 102, FINS's 9600 needs no elevation — the card
      // carries no privileged-port key at all.
      expect(find.byKey(const Key('s7_privileged_port_note')), findsNothing);

      await tester.enterText(find.byKey(const Key('fins_port_field')), '19600');
      await tester.pumpAndSettle();
      expect(project.protocols!.fins!.port, 19600);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Add entry / Regenerate / delete route through onProjectUpdated', (tester) async {
      final project = _project();
      project.protocols = ProtocolSettings.defaults(project);
      project.protocols!.fins!.enabled = true;
      project.protocols!.fins!.map.entries.clear();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      var updates = 0;

      await tester.pumpWidget(MaterialApp(
        home: GatewayScreen(
          currentProject: project,
          host: host,
          modbusHost: _CountingModbusHost(),
          mqttHost: MqttHost(),
          dnpHost: _CountingDnpHost(),
          enipHost: _CountingEnipHost(),
          s7Host: S7Host(),
          finsHost: FinsHost(),
          slmpHost: SlmpHost(),
          onProjectUpdated: () => updates++,
        ),
      ));
      await tester.pumpAndSettle();
      await _selectTab(tester, finsTabKey);

      expect(find.textContaining('No entries yet'), findsOneWidget);

      await tester.tap(find.text('Add entry'));
      await tester.pump();
      expect(project.protocols!.fins!.map.entries.length, 1);
      expect(updates, greaterThan(0));

      await tester.tap(find.text('Regenerate'));
      await tester.pump();
      expect(project.protocols!.fins!.map.entries, isNotEmpty);

      final beforeDelete = project.protocols!.fins!.map.entries.length;
      await tester.ensureVisible(find.byIcon(Icons.delete_outline).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await tester.pump();
      expect(project.protocols!.fins!.map.entries.length, beforeDelete - 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow at 320 width with the FINS card expanded', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      await setSurface(tester, smallPhoneSize);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await _selectTab(tester, finsTabKey);
      await tester.tap(find.byKey(const Key('fins_enable_switch')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow at 360 width with the FINS card expanded', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      await setSurface(tester, phoneSize);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await _selectTab(tester, finsTabKey);
      await tester.tap(find.byKey(const Key('fins_enable_switch')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow at 1400 width with the FINS card expanded', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      await setSurface(tester, desktopSize);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await _selectTab(tester, finsTabKey);
      await tester.tap(find.byKey(const Key('fins_enable_switch')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('SLMP card', () {
    testWidgets('renders its enable toggle, and the port field defaults to 5007', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await _selectTab(tester, slmpTabKey);

      expect(find.byKey(const Key('slmp_enable_switch')), findsOneWidget);
      final sw = tester.widget<Switch>(find.byKey(const Key('slmp_enable_switch')));
      expect(sw.value, isFalse, reason: 'SLMP hosting is opt-in and starts disabled');
      // The port field only exists once the card is enabled.
      expect(find.byKey(const Key('slmp_port_field')), findsNothing);

      await tester.tap(find.byKey(const Key('slmp_enable_switch')));
      await tester.pumpAndSettle();

      expect(project.protocols!.slmp!.enabled, isTrue);
      expect(project.protocols!.slmp!.port, 5007);
      final portField = tester.widget<TextField>(find.byKey(const Key('slmp_port_field')));
      expect(portField.controller!.text, '5007');
      expect(find.text('Default: 5007'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('port 5007 shows NO privileged-port note (it is above 1023)', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await _selectTab(tester, slmpTabKey);
      await tester.tap(find.byKey(const Key('slmp_enable_switch')));
      await tester.pumpAndSettle();

      // Like FINS's 9600, SLMP's 5007 needs no elevation — the card carries
      // no privileged-port key at all.
      expect(find.byKey(const Key('s7_privileged_port_note')), findsNothing);

      await tester.enterText(find.byKey(const Key('slmp_port_field')), '15007');
      await tester.pumpAndSettle();
      expect(project.protocols!.slmp!.port, 15007);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Add entry / Regenerate / delete route through onProjectUpdated', (tester) async {
      final project = _project();
      project.protocols = ProtocolSettings.defaults(project);
      project.protocols!.slmp!.enabled = true;
      project.protocols!.slmp!.map.entries.clear();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      var updates = 0;

      await tester.pumpWidget(MaterialApp(
        home: GatewayScreen(
          currentProject: project,
          host: host,
          modbusHost: _CountingModbusHost(),
          mqttHost: MqttHost(),
          dnpHost: _CountingDnpHost(),
          enipHost: _CountingEnipHost(),
          s7Host: S7Host(),
          finsHost: FinsHost(),
          slmpHost: SlmpHost(),
          onProjectUpdated: () => updates++,
        ),
      ));
      await tester.pumpAndSettle();
      await _selectTab(tester, slmpTabKey);

      expect(find.textContaining('No entries yet'), findsOneWidget);

      await tester.tap(find.text('Add entry'));
      await tester.pump();
      expect(project.protocols!.slmp!.map.entries.length, 1);
      expect(updates, greaterThan(0));

      await tester.tap(find.text('Regenerate'));
      await tester.pump();
      expect(project.protocols!.slmp!.map.entries, isNotEmpty);

      final beforeDelete = project.protocols!.slmp!.map.entries.length;
      await tester.ensureVisible(find.byIcon(Icons.delete_outline).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await tester.pump();
      expect(project.protocols!.slmp!.map.entries.length, beforeDelete - 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow at 320 width with the SLMP card expanded', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      await setSurface(tester, smallPhoneSize);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await _selectTab(tester, slmpTabKey);
      await tester.tap(find.byKey(const Key('slmp_enable_switch')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow at 360 width with the SLMP card expanded', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      await setSurface(tester, phoneSize);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await _selectTab(tester, slmpTabKey);
      await tester.tap(find.byKey(const Key('slmp_enable_switch')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('no overflow at 1400 width with the SLMP card expanded', (tester) async {
      final project = _project();
      final host = _CountingOpcUaHost();
      addTearDown(host.dispose);
      await setSurface(tester, desktopSize);

      await tester.pumpWidget(_app(project, host));
      await tester.pumpAndSettle();
      await _selectTab(tester, slmpTabKey);
      await tester.tap(find.byKey(const Key('slmp_enable_switch')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });
}
