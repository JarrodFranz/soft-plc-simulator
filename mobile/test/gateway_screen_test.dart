import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/gateway_screen.dart';
import 'package:soft_plc_mobile/services/gateway_client.dart';
import 'support/responsive_test_utils.dart';

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

Widget _app(PlcProject project, GatewayClient client) {
  return MaterialApp(
    home: GatewayScreen(
      currentProject: project,
      client: client,
      onProjectUpdated: () {},
    ),
  );
}

void main() {
  testWidgets('renders "Outbound Protocols" title, connection card, and OPC UA card', (tester) async {
    final project = _project();
    final client = GatewayClient();
    addTearDown(client.dispose);

    await tester.pumpWidget(_app(project, client));
    await tester.pumpAndSettle();

    expect(find.text('Outbound Protocols'), findsOneWidget);
    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Connect'), findsOneWidget);
    expect(find.byType(TextField), findsWidgets);
    expect(find.text('OPC UA'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('OPC UA card starts disabled by default with config hidden and 0 exposed', (tester) async {
    final project = _project();
    final client = GatewayClient();
    addTearDown(client.dispose);

    await tester.pumpWidget(_app(project, client));
    await tester.pumpAndSettle();

    expect(project.protocols?.opcua?.enabled, false);
    final sw = tester.widget<Switch>(find.byType(Switch));
    expect(sw.value, false);
    expect(find.text('OPC UA Node Map'), findsNothing);
    expect(find.textContaining('Exposed tags: 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('toggling the OPC UA switch ON reveals namespace + node map and sets enabled=true', (tester) async {
    final project = _project();
    final client = GatewayClient();
    addTearDown(client.dispose);

    await tester.pumpWidget(_app(project, client));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch));
    await tester.pump();

    expect(project.protocols?.opcua?.enabled, true);
    expect(find.text('OPC UA Node Map'), findsOneWidget);
    expect(find.textContaining('Namespace'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('toggling the OPC UA switch OFF hides the config again', (tester) async {
    final project = _project();
    final client = GatewayClient();
    addTearDown(client.dispose);

    await tester.pumpWidget(_app(project, client));
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

  testWidgets('editing the gateway URL field updates protocols.gatewayUrl', (tester) async {
    final project = _project();
    final client = GatewayClient();
    addTearDown(client.dispose);

    await tester.pumpWidget(_app(project, client));
    await tester.pumpAndSettle();

    final urlField = find.byType(TextField).first;
    await tester.enterText(urlField, 'ws://example.test:9999');
    await tester.pump();

    expect(project.protocols?.gatewayUrl, 'ws://example.test:9999');
    expect(tester.takeException(), isNull);
  });

  testWidgets('no overflow at 320 width', (tester) async {
    final project = _project();
    final client = GatewayClient();
    addTearDown(client.dispose);
    await setSurface(tester, smallPhoneSize);
    await tester.pumpWidget(_app(project, client));
    await tester.pumpAndSettle();
    // Also exercise the enabled/expanded state, the more overflow-prone one.
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('no overflow at 1400 width', (tester) async {
    final project = _project();
    final client = GatewayClient();
    addTearDown(client.dispose);
    await setSurface(tester, desktopSize);
    await tester.pumpWidget(_app(project, client));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
