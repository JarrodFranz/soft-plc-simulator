// Regression coverage for the QA "stale field" bug: a protocol map row's
// TextFormField/DropdownButtonFormField/TagAutocompleteField descendants
// seed their internal controllers from `initialValue` exactly once, in
// `initState`. `ListView.builder` reuses the Element at a given index across
// rebuilds when the returned widget carries no key, so when Regenerate (or
// undo of a Regenerate) replaces `map.entries` with a list of brand-new entry
// objects, the row at each index kept its OLD controller — still showing
// whatever the user last hand-typed — even though the underlying model
// (`entry.address` etc.) was already correct. A full page reload (a fresh
// widget tree top to bottom) was the only thing that fixed it; switching
// protocol tabs away and back did not, because `_KeepAliveTabBody` keeps each
// tab's subtree (and its stale controllers) alive across ordinary rebuilds.
//
// The fix keys each row by the entry's own object identity
// (`ObjectKey(entry)` via `_virtualizedMapList`), so a genuine object swap —
// but not an in-place field edit — forces Flutter to unmount the stale row
// and mount a fresh one seeded from the new entry.
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

PlcProject _project() {
  final project = PlcProject(
    id: 'proj_stale_field_test',
    name: 'Stale Field Test',
    controllerName: 'PLC_01',
    tags: [
      PlcTag(
        name: 'Start_PB',
        path: 'Inputs.Start_PB',
        dataType: 'BOOL',
        value: false,
        ioType: 'SimulatedInput',
      ),
    ],
    structDefs: const [],
    programs: const [],
    tasks: const [],
    hmis: const [],
  );
  project.protocols = ProtocolSettings.defaults(project);
  project.protocols!.modbus!.enabled = true;
  // A hand-edited entry that autoGenerate would never produce for a BOOL
  // SimulatedInput tag (autoGenerate puts it in the `coil` table at address
  // 0) — anything left showing '999'/'holding' after Regenerate is provably
  // stale, not a coincidental match.
  project.protocols!.modbus!.map = ModbusMap(entries: [
    ModbusMapEntry(tag: 'Start_PB', table: 'holding', address: 999, access: 'ReadOnly'),
  ]);
  return project;
}

Widget _app(PlcProject project) {
  return MaterialApp(
    home: UndoScope(
      onUndo: () {},
      child: GatewayScreen(
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
      ),
    ),
  );
}

Future<void> _selectModbusTab(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('protocol_tab_modbus')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'Regenerate replaces a hand-edited row entry AND the on-screen field '
      'follows it (not the stale hand-typed text)', (tester) async {
    await setSurface(tester, desktopSize);
    final project = _project();
    await tester.pumpWidget(_app(project));
    await tester.pumpAndSettle();
    await _selectModbusTab(tester);

    // Sanity: the row starts out showing the seeded hand-edited value.
    expect(find.widgetWithText(TextFormField, '999'), findsOneWidget);

    // Hand-edit the address field further, as a user would before ever
    // touching Regenerate.
    final addressField = find.widgetWithText(TextFormField, '999');
    await tester.enterText(addressField, '555');
    await tester.pump();
    expect(project.protocols!.modbus!.map.entries.single.address, 555);
    expect(find.widgetWithText(TextFormField, '555'), findsOneWidget);

    // Regenerate — confirms (map is non-empty) and replaces `entries` with a
    // list of brand-new ModbusMapEntry objects built from the project tags.
    final regenButton = find.byKey(const Key('regen_modbus_button'));
    await tester.ensureVisible(regenButton);
    await tester.pumpAndSettle();
    await tester.tap(regenButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kDestructiveReplaceConfirmKey));
    await tester.pumpAndSettle();

    // The model is correct: address 0 in the `coil` table (BOOL,
    // SimulatedInput -> read/write -> coil, first bit).
    final regenerated = project.protocols!.modbus!.map.entries.single;
    expect(regenerated.address, 0);
    expect(regenerated.table, 'coil');

    // The FIELD must follow: no leftover '555' (the hand-typed text) or
    // '999' (the original seed) anywhere in the row, and the new value must
    // actually be showing.
    expect(find.widgetWithText(TextFormField, '555'), findsNothing,
        reason: 'the hand-typed value must not survive a Regenerate');
    expect(find.widgetWithText(TextFormField, '999'), findsNothing,
        reason: 'the original seeded value must not survive a Regenerate');
    expect(find.widgetWithText(TextFormField, '0'), findsOneWidget,
        reason: 'the address field must resync to the regenerated entry');

    expect(tester.takeException(), isNull);
  });

  testWidgets('the same resync holds for the TagAutocompleteField (Tag column)',
      (tester) async {
    await setSurface(tester, desktopSize);
    final project = _project();
    await tester.pumpWidget(_app(project));
    await tester.pumpAndSettle();
    await _selectModbusTab(tester);

    final tagField = find.descendant(
      of: find.byType(GatewayScreen),
      matching: find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == 'Tag'),
    );
    await tester.enterText(tagField, 'Hand_Typed_Junk');
    await tester.pump();
    expect(find.text('Hand_Typed_Junk'), findsOneWidget);

    final regenButton = find.byKey(const Key('regen_modbus_button'));
    await tester.ensureVisible(regenButton);
    await tester.pumpAndSettle();
    await tester.tap(regenButton);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(kDestructiveReplaceConfirmKey));
    await tester.pumpAndSettle();

    expect(find.text('Hand_Typed_Junk'), findsNothing,
        reason: 'the hand-typed tag text must not survive a Regenerate');
    expect(find.text('Start_PB'), findsOneWidget,
        reason: 'the tag field must resync to the regenerated entry');

    expect(tester.takeException(), isNull);
  });
}
