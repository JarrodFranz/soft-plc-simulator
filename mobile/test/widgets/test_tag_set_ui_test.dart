import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/test_tag_set.dart';
import 'package:soft_plc_mobile/screens/memory_manager_screen.dart';
import 'package:soft_plc_mobile/widgets/live_tick.dart';

void main() {
  testWidgets('generate + delete a test set updates tags, gens, and maps', (tester) async {
    final proj = PlcProject(id: 'x', name: 'x', controllerName: 'c',
        tags: [], structDefs: [], programs: [], tasks: [], hmis: []);
    await tester.pumpWidget(LiveTickScope(
      notifier: LiveTick(),
      child: MaterialApp(
        home: MemoryManagerScreen(currentProject: proj, onProjectUpdated: () {}),
      ),
    ));
    await tester.pumpAndSettle();
    final state = tester.state<MemoryManagerScreenState>(find.byType(MemoryManagerScreen));

    state.debugGenerateTestSet(
      TestSetSpec(folder: 'ramp1', baseName: 'R', count: 5, type: 'ramp',
        minValue: 0, maxValue: 100, periodMs: 1000),
      opcua: true, modbus: false, dnp3: false, mqtt: false);
    expect(proj.tags.where((t) => t.folder == 'ramp1').length, 5);
    expect(proj.signalGens.length, 5);

    state.debugDeleteFolder('ramp1');
    expect(proj.tags.where((t) => t.folder == 'ramp1'), isEmpty);
    expect(proj.signalGens, isEmpty);
  });

  testWidgets('debugGenerateTestSet rejects count <= 0 and adds nothing', (tester) async {
    final proj = PlcProject(id: 'x', name: 'x', controllerName: 'c',
        tags: [], structDefs: [], programs: [], tasks: [], hmis: []);
    await tester.pumpWidget(LiveTickScope(
      notifier: LiveTick(),
      child: MaterialApp(
        home: MemoryManagerScreen(currentProject: proj, onProjectUpdated: () {}),
      ),
    ));
    await tester.pumpAndSettle();
    final state = tester.state<MemoryManagerScreenState>(find.byType(MemoryManagerScreen));

    final ok = state.debugGenerateTestSet(
      TestSetSpec(folder: 'zero1', baseName: 'Z', count: 0, type: 'ramp',
        minValue: 0, maxValue: 100, periodMs: 1000),
      opcua: false, modbus: false, dnp3: false, mqtt: false);

    expect(ok, isFalse);
    expect(proj.tags, isEmpty);
    expect(proj.signalGens, isEmpty);
  });
}
