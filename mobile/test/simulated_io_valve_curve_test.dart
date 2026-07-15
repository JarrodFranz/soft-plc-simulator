import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/simulated_io_screen.dart';

void main() {
  testWidgets('valve-curve dropdown shows for an integrate rule with an actuator', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [
        PlcTag(name: 'Valve', path: 'Valve', dataType: 'FLOAT64', value: 20.0, ioType: 'Internal'),
        PlcTag(name: 'Level', path: 'Level', dataType: 'FLOAT64', value: 0.0, ioType: 'Internal'),
      ],
      structDefs: [], programs: [], tasks: [], hmis: [],
    );
    proj.simRules.add(SimRule(
      id: 'r', name: 'fill', targetPath: 'Level', behavior: 'integrate',
      ratePerSec: 100.0, sourcePath: 'Valve', refValue: 100.0));

    await tester.pumpWidget(MaterialApp(
      home: SimulatedIoScreen(currentProject: proj, onProjectUpdated: () {}),
    ));
    await tester.pumpAndSettle();

    // Open the rule editor via the row's edit icon button.
    await tester.tap(find.byIcon(Icons.edit));
    await tester.pumpAndSettle();

    // The valve-characteristic control is present.
    expect(find.textContaining('Valve characteristic'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
