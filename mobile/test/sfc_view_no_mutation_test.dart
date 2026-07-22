import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sfc_exec.dart';
import 'package:soft_plc_mobile/screens/sfc_editor_screen.dart';

// Regression: opening the SFC editor must NOT mutate the (possibly running)
// program. Previously initState -> _ensureDefaultSfc() silently injected three
// demo steps + transitions into any empty SFC program, which then fought other
// programs over shared output tags (see the tank-level demo). A view must never
// fabricate or inject logic into a program.
void main() {
  testWidgets('opening an empty SFC program leaves it empty (no step injection)',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final prog = PlcProgram(
        name: 'EmptyChart', language: 'SequentialFunctionChart', rungs: []);
    final proj = PlcProject(
      id: 'p', name: 'P', controllerName: 'C',
      tags: [], structDefs: [], programs: [prog], tasks: [], hmis: [],
    );

    var mutated = false;
    await tester.pumpWidget(MaterialApp(
      home: SfcEditorScreen(
        currentProject: proj,
        program: prog,
        onProgramUpdated: () => mutated = true,
        sfcRuntime: SfcRuntime(),
        scanRunning: false,
      ),
    ));
    await tester.pumpAndSettle();

    expect(prog.sfcSteps, isEmpty,
        reason: 'the editor must not inject demo steps into an empty program');
    expect(prog.sfcTransitions, isEmpty);
    expect(mutated, isFalse,
        reason: 'opening the view must not report a program mutation');
    expect(tester.takeException(), isNull);
  });

  test('tank demo no longer ships an empty SFC assigned to the running task', () {
    final tank = DefaultProjects.all().firstWhere(
        (p) => p.programs.any((prog) => prog.name == 'TankLevel_FBD'));

    // The pointless empty SFC that fought the FBD is gone.
    expect(tank.programs.any((p) => p.name == 'TankSequence_SFC'), isFalse);
    expect(
        tank.programs.any((p) => p.language == 'SequentialFunctionChart'), isFalse);

    // The process task now runs only the FBD control program.
    final task = tank.tasks.firstWhere((t) => t.name == 'ProcessLoopTask');
    expect(task.programNames, ['TankLevel_FBD']);
  });
}
