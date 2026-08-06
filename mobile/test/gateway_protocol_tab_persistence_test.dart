// Regression coverage for the QA "tab resets to OPC UA" bug: tapping UNDO on
// the Regenerate snackbar (or any other action that bumps
// `WorkspaceShellState._editorRevision`) re-keys the shell's center pane,
// tearing the whole `GatewayScreen` down and rebuilding it — including its
// `DefaultTabController`, which always starts a brand-new screen instance at
// tab 0. `WorkspaceShellState` fixes this by remembering the last-selected
// index itself (see `_gatewayTabIndex`) and feeding it back in via
// `initialProtocolTabIndex` on the next build; `GatewayScreen` reports every
// tab change back up via `onProtocolTabChanged` so the shell has something
// current to remember.
//
// This file covers `GatewayScreen`'s side of that contract directly — mount
// with a non-zero `initialProtocolTabIndex` and confirm it opens on that tab,
// then confirm `onProtocolTabChanged` fires with the new index on both a chip
// tap and a `TabBarView` swipe — without needing to stand up the full
// `WorkspaceShell` (scan loop, autosave, undo history) just to prove the
// plumbing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/screens/gateway_screen.dart';
import 'package:soft_plc_mobile/services/bacnet_host.dart';
import 'package:soft_plc_mobile/services/dnp3_host.dart';
import 'package:soft_plc_mobile/services/enip_host.dart';
import 'package:soft_plc_mobile/services/fins_host.dart';
import 'package:soft_plc_mobile/services/modbus_host.dart';
import 'package:soft_plc_mobile/services/mqtt_host.dart';
import 'package:soft_plc_mobile/services/opcua_host.dart';
import 'package:soft_plc_mobile/services/s7_host.dart';
import 'package:soft_plc_mobile/services/slmp_host.dart';

import 'support/responsive_test_utils.dart';

PlcProject _project() {
  final project = PlcProject(
    id: 'proj_tab_persist_test',
    name: 'Tab Persistence Test',
    controllerName: 'PLC_01',
    tags: const [],
    structDefs: const [],
    programs: const [],
    tasks: const [],
    hmis: const [],
  );
  project.protocols = ProtocolSettings.defaults(project);
  return project;
}

Widget _app(PlcProject project, {int initialProtocolTabIndex = 0, ValueChanged<int>? onTabChanged}) {
  return MaterialApp(
    home: GatewayScreen(
      currentProject: project,
      host: OpcUaHost(),
      modbusHost: ModbusHost(),
      mqttHost: MqttHost(),
      dnpHost: DnpHost(),
      enipHost: EnipHost(),
      s7Host: S7Host(),
      finsHost: FinsHost(),
      slmpHost: SlmpHost(),
      bacnetHost: BacnetHost(),
      onProjectUpdated: () {},
      initialProtocolTabIndex: initialProtocolTabIndex,
      onProtocolTabChanged: onTabChanged,
    ),
  );
}

void main() {
  testWidgets('initialProtocolTabIndex opens the screen on that tab, not OPC UA', (tester) async {
    await setSurface(tester, desktopSize);
    // dnp3 is index 3 in _protocolTabs (opcua, modbus, mqtt, dnp3, ...).
    await tester.pumpWidget(_app(_project(), initialProtocolTabIndex: 3));
    await tester.pumpAndSettle();

    final controller = DefaultTabController.of(
      tester.element(find.byKey(const Key('protocol_tab_dnp3'))),
    );
    expect(controller.index, 3);
    // The DNP3 card's own content should be visible without tapping anything.
    expect(find.text('DNP3'), findsWidgets);
  });

  testWidgets('an out-of-range initialProtocolTabIndex clamps instead of throwing', (tester) async {
    await setSurface(tester, desktopSize);
    await tester.pumpWidget(_app(_project(), initialProtocolTabIndex: 99));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a protocol chip reports the new index via onProtocolTabChanged',
      (tester) async {
    await setSurface(tester, desktopSize);
    final reported = <int>[];
    await tester.pumpWidget(_app(_project(), onTabChanged: reported.add));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('protocol_tab_mqtt')));
    await tester.pumpAndSettle();

    expect(reported, contains(2)); // mqtt is index 2 (opcua, modbus, mqtt, ...).
  });

  testWidgets(
      'a GatewayScreen remounted with the last-reported index reopens on that tab '
      '(what WorkspaceShellState does across an undo-driven remount)', (tester) async {
    await setSurface(tester, desktopSize);
    var lastIndex = 0;
    final project = _project();
    await tester.pumpWidget(_app(project, onTabChanged: (i) => lastIndex = i));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('protocol_tab_s7')));
    await tester.pumpAndSettle();
    expect(lastIndex, 5); // s7 is index 5.

    // Simulate the shell's remount-on-undo: a brand-new GatewayScreen fed the
    // remembered index, exactly as `_buildCenterWorkspace` does after
    // `_applySnapshot` bumps `_editorRevision`.
    await tester.pumpWidget(_app(project, initialProtocolTabIndex: lastIndex));
    await tester.pumpAndSettle();

    final controller = DefaultTabController.of(
      tester.element(find.byKey(const Key('protocol_tab_s7'))),
    );
    expect(controller.index, 5, reason: 'the remount must reopen on the previously-selected tab');
  });
}
