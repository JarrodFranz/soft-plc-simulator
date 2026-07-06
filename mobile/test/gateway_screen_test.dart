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
  testWidgets('renders status, Connect control, URL field, exposed-tag count', (tester) async {
    final project = _project();
    final client = GatewayClient();
    addTearDown(client.dispose);

    await tester.pumpWidget(_app(project, client));
    await tester.pumpAndSettle();

    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Connect'), findsOneWidget);
    expect(find.byType(TextField), findsWidgets);
    // Auto-generated map from tags => 2 exposed tags.
    expect(find.textContaining('2'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no overflow at 320 width', (tester) async {
    final project = _project();
    final client = GatewayClient();
    addTearDown(client.dispose);
    await setSurface(tester, smallPhoneSize);
    await tester.pumpWidget(_app(project, client));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('no overflow at 1400 width', (tester) async {
    final project = _project();
    final client = GatewayClient();
    addTearDown(client.dispose);
    await setSurface(tester, desktopSize);
    await tester.pumpWidget(_app(project, client));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
