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

/// Regression guard for the protocol map-row overflow: the map-row builders
/// (`_dnpRow`, `_modbusRow`, …) used to choose their stacked-vs-Row layout
/// from `context.isCompact` (the WINDOW width via MediaQuery) while actually
/// rendering inside a much narrower PANE (e.g. squeezed by the tag-inspector
/// dock). When the window was >= 640 but the pane was ~410, the non-compact
/// Row's fixed-width columns (DNP: 190+100+140+40 + gaps = 494px) overflowed
/// the pane by ~84px. The fix keys the decision off the LayoutBuilder's pane
/// width (`constraints.maxWidth`) instead.
///
/// Every pre-existing gateway "no overflow" test sets the surface so the pane
/// EQUALS the window (320 -> both compact; 1400 -> both wide), so none of them
/// exercise the divergence. This test deliberately makes them diverge: a wide
/// 900px window (isCompact == false) with the screen constrained to a 410px
/// pane.
PlcProject _project() {
  final project = PlcProject(
    id: 'proj_gw_narrow_pane',
    name: 'Narrow Pane Test',
    controllerName: 'PLC_01',
    tags: [
      PlcTag(name: 'Start_PB', path: 'Inputs.Start_PB', dataType: 'BOOL', value: false, ioType: 'SimulatedInput'),
      PlcTag(name: 'Motor_Run', path: 'Outputs.Motor_Run', dataType: 'BOOL', value: false, ioType: 'SimulatedOutput'),
      PlcTag(name: 'Level_PV', path: 'Inputs.Level_PV', dataType: 'REAL', value: 0.0, ioType: 'SimulatedInput'),
    ],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );
  // Enable DNP3 with its default (tag-derived) map so `_dnpRow`s actually
  // render — that row has the widest fixed-width column set and is the one
  // the user's report overflowed by 84px.
  project.protocols = ProtocolSettings.defaults(project);
  project.protocols!.dnp3!.enabled = true;
  return project;
}

/// Builds the GatewayScreen inside a 410px-wide pane while the surrounding
/// window (MediaQuery) stays at [windowWidth] px wide.
Widget _appInPane(PlcProject project, {required double paneWidth}) {
  return MaterialApp(
    home: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: paneWidth,
        height: 760,
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
          hostingSupported: true,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
      'DNP map rows do not overflow in a 410px pane inside a 900px (non-compact) window',
      (tester) async {
    // Wide window => context.isCompact is FALSE. Pre-fix this forced the Row
    // layout even though the pane below is only 410px.
    await setSurface(tester, const Size(900, 800));
    final project = _project();

    await tester.pumpWidget(_appInPane(project, paneWidth: 410));
    await tester.pumpAndSettle();

    // Bring the DNP3 tab into the scrollable TabBar's view and select it so
    // its (enabled) map editor with the `_dnpRow`s builds.
    await tester.ensureVisible(find.byKey(const Key('protocol_tab_dnp3')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('protocol_tab_dnp3')));
    await tester.pumpAndSettle();

    // The DNP map editor is showing with tag-derived rows and hosting
    // controls; none may overflow at this pane width.
    expect(find.text('DNP3 Point Map'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
