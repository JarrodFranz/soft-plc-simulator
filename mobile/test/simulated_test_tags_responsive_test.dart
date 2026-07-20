// Manual-responsive-check coverage (simulated-test-tags workstream, Task 8,
// Step 3): the Generate Test Set dialog, the folder-grouped Memory Manager
// tag list, and a folder-grouped protocol map view must not RenderFlex
// overflow at 320/360/1400 width. Mirrors the existing overflow-guard style
// in `test/modbus_map_editor_test.dart`.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:soft_plc_mobile/models/modbus_map.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/protocol_settings.dart';
import 'package:soft_plc_mobile/models/signal_gen.dart';
import 'package:soft_plc_mobile/screens/gateway_screen.dart';
import 'package:soft_plc_mobile/screens/memory_manager_screen.dart';
import 'package:soft_plc_mobile/services/dnp3_host.dart';
import 'package:soft_plc_mobile/services/enip_host.dart';
import 'package:soft_plc_mobile/services/fins_host.dart';
import 'package:soft_plc_mobile/services/slmp_host.dart';
import 'package:soft_plc_mobile/services/s7_host.dart';
import 'package:soft_plc_mobile/services/modbus_host.dart';
import 'package:soft_plc_mobile/services/mqtt_host.dart';
import 'package:soft_plc_mobile/services/opcua_host.dart';
import 'package:soft_plc_mobile/services/tag_historian.dart';
import 'package:soft_plc_mobile/widgets/live_tick.dart';
import 'support/responsive_test_utils.dart';

/// A project with one root tag and a folder of 3 generated ramp tags (plus
/// their `SignalGen`s and a Modbus map entry per tag), so both the
/// folder-grouped tag list and the folder-grouped protocol map view have a
/// real folder section (not a degenerate empty-folder case) to render.
PlcProject _project() {
  final project = PlcProject(
    id: 'proj_sim_test_tags_responsive',
    name: 'Sim Test Tags Responsive Check',
    controllerName: 'PLC_01',
    tags: [
      PlcTag(name: 'Root_Tag', path: 'Root_Tag', dataType: 'BOOL', value: false, ioType: 'Internal'),
      for (var i = 1; i <= 3; i++)
        PlcTag(
          name: 'Ramp$i',
          path: 'RampSet/Ramp$i',
          dataType: 'FLOAT64',
          value: 0.0,
          ioType: 'SimulatedOutput',
          folder: 'RampSet',
        ),
    ],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
    signalGens: [
      for (var i = 1; i <= 3; i++)
        SignalGen(
          id: 'RampSet/Ramp$i',
          targetPath: 'Ramp$i',
          type: 'ramp',
          minValue: 0,
          maxValue: 100,
          periodMs: 1000,
          phase: (i - 1) / 3,
        ),
    ],
  );
  project.protocols = ProtocolSettings.defaults(project);
  project.protocols!.modbus!.enabled = true;
  project.protocols!.modbus!.map.entries
    ..clear()
    ..addAll([
      for (var i = 1; i <= 3; i++)
        ModbusMapEntry(tag: 'Ramp$i', table: 'input', address: i - 1, access: 'ReadOnly'),
    ]);
  return project;
}

Widget _memoryManagerApp(PlcProject project) {
  return LiveTickScope(
    notifier: LiveTick(),
    child: MaterialApp(
      home: MemoryManagerScreen(currentProject: project, onProjectUpdated: () {}, historian: TagHistorian()),
    ),
  );
}

Widget _gatewayApp(PlcProject project) {
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
      onProjectUpdated: () {},
    ),
  );
}

Future<void> _selectModbusTab(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('protocol_tab_modbus')));
  await tester.pumpAndSettle();
}

void main() {
  for (final entry in {'320': smallPhoneSize, '360': phoneSize, '1400': desktopSize}.entries) {
    final label = entry.key;
    final size = entry.value;

    testWidgets('folder-grouped Memory Manager list: no overflow at $label width', (tester) async {
      await setSurface(tester, size);
      await tester.pumpWidget(_memoryManagerApp(_project()));
      await tester.pumpAndSettle();

      // The folder section (collapsed by default) must render with no
      // overflow, and expanding it (revealing the 3 generated ramp rows)
      // must not overflow either.
      final folderHeader = find.text('RampSet');
      expect(folderHeader, findsOneWidget);
      await tester.tap(folderHeader);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });

    testWidgets('Generate Test Set dialog: no overflow at $label width', (tester) async {
      await setSurface(tester, size);
      await tester.pumpWidget(_memoryManagerApp(_project()));
      await tester.pumpAndSettle();

      // Deliberately no `ensureVisible` here: the FAB is a `Scaffold`
      // property (always on-screen, never needs scrolling into view), and
      // this screen's tab content sits inside a `TabBarView`'s `PageView` —
      // an ancestor Scrollable that `ensureVisible` would otherwise page
      // away from (off the Global Tags tab entirely) trying to bring the
      // (already fully visible) FAB "into view".
      final openButton = find.widgetWithText(FloatingActionButton, 'Generate Test Set');
      await tester.tap(openButton);
      await tester.pumpAndSettle();

      expect(find.text('Generate Test Set'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('folder-grouped protocol map view: no overflow at $label width', (tester) async {
      await setSurface(tester, size);
      await tester.pumpWidget(_gatewayApp(_project()));
      await tester.pumpAndSettle();
      await _selectModbusTab(tester);

      // The folder subheader for the 3 Ramp* map entries must be present
      // and render with no overflow.
      expect(find.text('RampSet'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }
}
