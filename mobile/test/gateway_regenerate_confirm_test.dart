// QA batch C — the gateway's nine protocol-map "Regenerate" buttons.
//
// They sit one tap away from "Add entry" and used to replace the entire map
// from the project tags instantly, silently, and with no confirmation — the
// most destructive unannounced action left in the app after the delete-policy
// sweep. Protocol maps ARE in the undo history (`protocols` is part of
// `PlcProject.toJson()` and the gateway reports through the project-changed
// callback), so the policy in `lib/ui/delete_feedback.dart` splits on whether
// anything is actually at risk: a non-empty map confirms first, an empty one
// goes straight through, and both announce the result with UNDO.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:soft_plc_mobile/models/modbus_map.dart';
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
import 'package:soft_plc_mobile/ui/delete_feedback.dart';

import 'support/responsive_test_utils.dart';

/// Every protocol's Regenerate button, keyed, with the tab that reveals it.
const Map<String, String> _regenButtons = {
  'opcua': 'opcua',
  'modbus': 'modbus',
  'mqtt': 'mqtt',
  'dnp3': 'dnp3',
  'enip': 'enip',
  's7': 's7',
  'fins': 'fins',
  'slmp': 'slmp',
  'bacnet': 'bacnet',
};

PlcProject _project() {
  final project = PlcProject(
    id: 'proj_regen_test',
    name: 'Regenerate Test',
    controllerName: 'PLC_01',
    tags: [
      PlcTag(
          name: 'Start_PB',
          path: 'Inputs.Start_PB',
          dataType: 'BOOL',
          value: false,
          ioType: 'SimulatedInput'),
      PlcTag(
          name: 'Motor_Run',
          path: 'Outputs.Motor_Run',
          dataType: 'BOOL',
          value: false,
          ioType: 'SimulatedOutput'),
    ],
    structDefs: const [],
    programs: const [],
    tasks: const [],
    hmis: const [],
  );
  project.protocols = ProtocolSettings.defaults(project);
  project.protocols!.opcua = OpcUaProtocolConfig.defaults(project)..enabled = true;
  project.protocols!.modbus!.enabled = true;
  project.protocols!.mqtt!.enabled = true;
  project.protocols!.dnp3!.enabled = true;
  project.protocols!.ethernetIp!.enabled = true;
  project.protocols!.s7!.enabled = true;
  project.protocols!.fins!.enabled = true;
  project.protocols!.slmp!.enabled = true;
  project.protocols!.bacnet!.enabled = true;
  return project;
}

class _Harness {
  _Harness(this.project);
  final PlcProject project;
  final OpcUaHost opcua = OpcUaHost();
  final ModbusHost modbus = ModbusHost();
  final MqttHost mqtt = MqttHost();
  final DnpHost dnp = DnpHost();
  final EnipHost enip = EnipHost();
  final S7Host s7 = S7Host();
  final FinsHost fins = FinsHost();
  final SlmpHost slmp = SlmpHost();
  final BacnetHost bacnet = BacnetHost();
  int updates = 0;

  void dispose() {
    opcua.dispose();
    modbus.dispose();
    mqtt.dispose();
    dnp.dispose();
    enip.dispose();
    s7.dispose();
    fins.dispose();
    slmp.dispose();
    bacnet.dispose();
  }

  Widget app({VoidCallback? onUndo}) {
    final screen = GatewayScreen(
      currentProject: project,
      host: opcua,
      modbusHost: modbus,
      mqttHost: mqtt,
      dnpHost: dnp,
      enipHost: enip,
      s7Host: s7,
      finsHost: fins,
      slmpHost: slmp,
      bacnetHost: bacnet,
      onProjectUpdated: () => updates++,
    );
    return MaterialApp(
      home: onUndo == null ? screen : UndoScope(onUndo: onUndo, child: screen),
    );
  }
}

Future<void> _selectTab(WidgetTester tester, String protocol) async {
  final tab = find.byKey(Key('protocol_tab_$protocol'));
  await tester.ensureVisible(tab);
  await tester.pumpAndSettle();
  await tester.tap(tab);
  await tester.pumpAndSettle();
}

Future<void> _tapRegenerate(WidgetTester tester, String protocol) async {
  final button = find.byKey(Key('regen_${protocol}_button'));
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('all nine protocol cards expose a keyed Regenerate button', (tester) async {
    await setSurface(tester, desktopSize);
    final harness = _Harness(_project());
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    for (final protocol in _regenButtons.values) {
      await _selectTab(tester, protocol);
      expect(find.byKey(Key('regen_${protocol}_button')), findsOneWidget,
          reason: '$protocol must route through the shared regenerate guard');
    }
  });

  testWidgets('regenerating a NON-empty map confirms first, naming the entry count',
      (tester) async {
    await setSurface(tester, desktopSize);
    final project = _project();
    project.protocols!.modbus!.map = ModbusMap(entries: [
      ModbusMapEntry(tag: 'Start_PB', table: 'holding', address: 40, access: 'ReadWrite'),
      ModbusMapEntry(tag: 'Motor_Run', table: 'holding', address: 41, access: 'ReadWrite'),
    ]);
    final harness = _Harness(project);
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    await _selectTab(tester, 'modbus');
    await _tapRegenerate(tester, 'modbus');

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Regenerate Modbus register map?'), findsOneWidget);
    expect(find.textContaining('replaces all 2 current entries'), findsOneWidget);
    // The map is untouched while the dialog is up.
    expect(project.protocols!.modbus!.map.entries.first.address, 40);
  });

  testWidgets('Cancel on the confirmation leaves the map exactly as it was', (tester) async {
    await setSurface(tester, desktopSize);
    final project = _project();
    project.protocols!.modbus!.map = ModbusMap(entries: [
      ModbusMapEntry(tag: 'Start_PB', table: 'holding', address: 40, access: 'ReadWrite'),
    ]);
    final harness = _Harness(project);
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    await _selectTab(tester, 'modbus');
    await _tapRegenerate(tester, 'modbus');
    final updatesBefore = harness.updates;

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(project.protocols!.modbus!.map.entries.length, 1);
    expect(project.protocols!.modbus!.map.entries.single.address, 40);
    expect(harness.updates, updatesBefore, reason: 'Cancel must not dirty the project');
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('confirming replaces the map and reports the new count with UNDO', (tester) async {
    await setSurface(tester, desktopSize);
    final project = _project();
    project.protocols!.modbus!.map = ModbusMap(entries: [
      ModbusMapEntry(tag: 'Hand_Edited', table: 'holding', address: 999, access: 'ReadOnly'),
    ]);
    final harness = _Harness(project);
    addTearDown(harness.dispose);
    var undos = 0;
    await tester.pumpWidget(harness.app(onUndo: () => undos++));
    await tester.pumpAndSettle();

    await _selectTab(tester, 'modbus');
    await _tapRegenerate(tester, 'modbus');
    await tester.tap(find.byKey(kDestructiveReplaceConfirmKey));
    await tester.pumpAndSettle();

    final entries = project.protocols!.modbus!.map.entries;
    expect(entries.any((e) => e.tag == 'Hand_Edited'), isFalse);
    expect(entries, isNotEmpty);
    expect(harness.updates, greaterThan(0));

    expect(find.byType(SnackBar), findsOneWidget);
    expect(
        find.textContaining(
            'Regenerated Modbus register map from project tags — ${entries.length} '),
        findsOneWidget);

    await tester.tap(find.byKey(kDeleteUndoActionKey));
    await tester.pumpAndSettle();
    expect(undos, 1, reason: 'the SnackBar UNDO must reach the shell undo');
  });

  testWidgets('regenerating an EMPTY map skips the dialog and just reports', (tester) async {
    await setSurface(tester, desktopSize);
    final project = _project();
    project.protocols!.modbus!.map.entries.clear();
    final harness = _Harness(project);
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    await _selectTab(tester, 'modbus');
    expect(
        find.text('No entries yet. Tap Regenerate to build a default map from the project tags.'),
        findsOneWidget);

    await _tapRegenerate(tester, 'modbus');

    // Nothing to lose, so no dialog — the empty state literally instructs the
    // user to press this button.
    expect(find.byType(AlertDialog), findsNothing);
    expect(project.protocols!.modbus!.map.entries, isNotEmpty);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('Regenerated Modbus register map'), findsOneWidget);
  });

  testWidgets('the OPC UA node map is guarded too, counting nodes', (tester) async {
    await setSurface(tester, desktopSize);
    final project = _project();
    final harness = _Harness(project);
    addTearDown(harness.dispose);
    await tester.pumpWidget(harness.app());
    await tester.pumpAndSettle();

    final nodeCount = project.protocols!.opcua!.map.nodes.length;
    expect(nodeCount, greaterThan(0));

    await _selectTab(tester, 'opcua');
    await _tapRegenerate(tester, 'opcua');

    expect(find.text('Regenerate OPC UA node map?'), findsOneWidget);
    expect(find.textContaining('replaces all $nodeCount current entries'), findsOneWidget);

    await tester.tap(find.byKey(kDestructiveReplaceConfirmKey));
    await tester.pumpAndSettle();
    expect(find.textContaining('Regenerated OPC UA node map'), findsOneWidget);
  });
}
