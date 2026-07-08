// Widget coverage for the Modbus register-map editor (Task 3 of the
// "Protocol Interop Fixes" workstream): the Modbus card previously only
// offered "Regenerate" — this proves the new "Add entry" affordance plus
// per-row edit/delete route through the same project-changed/autosave
// callback the OPC UA node-map editor uses on this screen. Mirrors the
// existing Modbus coverage in `gateway_screen_test.dart`.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/screens/gateway_screen.dart';
import 'package:soft_plc_mobile/services/modbus_host.dart';
import 'package:soft_plc_mobile/services/opcua_host.dart';
import 'support/responsive_test_utils.dart';

PlcProject _project() {
  final project = PlcProject(
    id: 'proj_modbus_map_editor_test',
    name: 'Modbus Map Editor Test',
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
        name: 'Speed',
        path: 'Internal.Speed',
        dataType: 'INT32',
        value: 0,
        ioType: 'Internal',
      ),
    ],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );
  project.protocols = ProtocolSettings.defaults(project);
  project.protocols!.modbus!.enabled = true;
  project.protocols!.modbus!.map.entries.clear();
  return project;
}

Widget _app(PlcProject project, {required VoidCallback onProjectUpdated}) {
  return MaterialApp(
    home: GatewayScreen(
      currentProject: project,
      host: OpcUaHost(),
      modbusHost: ModbusHost(),
      onProjectUpdated: onProjectUpdated,
    ),
  );
}

void main() {
  testWidgets('Add entry appends a default ModbusMapEntry to the project map', (tester) async {
    final project = _project();
    var updates = 0;

    await tester.pumpWidget(_app(project, onProjectUpdated: () => updates++));
    await tester.pumpAndSettle();

    expect(project.protocols!.modbus!.map.entries, isEmpty);

    await tester.tap(find.widgetWithText(TextButton, 'Add entry'));
    await tester.pump();

    expect(project.protocols!.modbus!.map.entries, hasLength(1));
    expect(project.protocols!.modbus!.map.entries.first.table, 'holding');
    expect(project.protocols!.modbus!.map.entries.first.address, 0);
    expect(project.protocols!.modbus!.map.entries.first.access, 'ReadWrite');
    expect(updates, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('editing a row (tag/table/address/access) updates the same entry', (tester) async {
    final project = _project();
    await tester.pumpWidget(_app(project, onProjectUpdated: () {}));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Add entry'));
    await tester.pump();
    final entry = project.protocols!.modbus!.map.entries.first;

    // Tag: type a value into the TagAutocompleteField (free-text onChanged).
    final tagFieldFinder = find.descendant(
      of: find.byType(GatewayScreen),
      matching: find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == 'Tag'),
    );
    expect(tagFieldFinder, findsOneWidget);
    await tester.enterText(tagFieldFinder, 'Speed');
    await tester.pump();
    expect(entry.tag, 'Speed');

    // Table dropdown -> 'input'.
    final tableDropdown = find.widgetWithText(DropdownButtonFormField<String>, 'holding');
    expect(tableDropdown, findsOneWidget);
    await tester.tap(tableDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('input').last);
    await tester.pumpAndSettle();
    expect(entry.table, 'input');

    // Address field (initial value '0', from the freshly-added default entry).
    final addressFieldFinder = find.widgetWithText(TextFormField, '0');
    expect(addressFieldFinder, findsOneWidget);
    await tester.enterText(addressFieldFinder, '42');
    await tester.pumpAndSettle();
    expect(entry.address, 42);

    // Access dropdown -> 'ReadOnly'.
    final accessDropdown = find.widgetWithText(DropdownButtonFormField<String>, 'ReadWrite');
    expect(accessDropdown, findsOneWidget);
    await tester.tap(accessDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('ReadOnly').last);
    await tester.pumpAndSettle();
    expect(entry.access, 'ReadOnly');

    expect(tester.takeException(), isNull);
  });

  testWidgets('deleting a row removes it from the map', (tester) async {
    final project = _project();
    await tester.pumpWidget(_app(project, onProjectUpdated: () {}));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Add entry'));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Add entry'));
    await tester.pump();
    expect(project.protocols!.modbus!.map.entries, hasLength(2));

    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pump();

    expect(project.protocols!.modbus!.map.entries, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('tag options include composite/dotted paths via leafAndNodePaths', (tester) async {
    final project = _project();
    project.structDefs.add(PlcStructDef(name: 'MotorType', fields: [
      StructFieldDef(name: 'Speed', dataType: 'INT32', defaultValue: 0),
    ]));
    project.tags.add(PlcTag(
      name: 'Motor',
      path: 'Motor',
      dataType: 'MotorType',
      value: {'Speed': 0},
      ioType: 'Internal',
    ));

    await tester.pumpWidget(_app(project, onProjectUpdated: () {}));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Add entry'));
    await tester.pump();

    final tagFieldFinder = find.descendant(
      of: find.byType(GatewayScreen),
      matching: find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == 'Tag'),
    );
    await tester.tap(tagFieldFinder);
    await tester.enterText(tagFieldFinder, 'Motor.Speed');
    await tester.pump();

    final entry = project.protocols!.modbus!.map.entries.first;
    expect(entry.tag, 'Motor.Speed');
    expect(tester.takeException(), isNull);
  });

  testWidgets('no overflow at 320 width with an entry row shown', (tester) async {
    final project = _project();
    await setSurface(tester, smallPhoneSize);
    await tester.pumpWidget(_app(project, onProjectUpdated: () {}));
    await tester.pumpAndSettle();

    final addEntryFinder = find.widgetWithText(TextButton, 'Add entry');
    await tester.ensureVisible(addEntryFinder);
    await tester.pumpAndSettle();
    await tester.tap(addEntryFinder);
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('no overflow at 360 width with an entry row shown', (tester) async {
    final project = _project();
    await setSurface(tester, const Size(360, 800));
    await tester.pumpWidget(_app(project, onProjectUpdated: () {}));
    await tester.pumpAndSettle();

    final addEntryFinder = find.widgetWithText(TextButton, 'Add entry');
    await tester.ensureVisible(addEntryFinder);
    await tester.pumpAndSettle();
    await tester.tap(addEntryFinder);
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('no overflow at 1400 width with an entry row shown', (tester) async {
    final project = _project();
    await setSurface(tester, desktopSize);
    await tester.pumpWidget(_app(project, onProjectUpdated: () {}));
    await tester.pumpAndSettle();

    final addEntryFinder = find.widgetWithText(TextButton, 'Add entry');
    await tester.ensureVisible(addEntryFinder);
    await tester.pumpAndSettle();
    await tester.tap(addEntryFinder);
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
