// Integration coverage for task 4 of the trend-historian effort: the shell
// owns a `TagHistorian`, samples it each scan tick (`_executeScan`), and
// keeps it synced to the active project's pens.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';

void main() {
  setUp(() {
    // WorkspaceShell() boots via the real (non-injected) SharedPreferences
    // .getInstance() path. Mock initial values so that call actually
    // resolves inside the test's zone (see scan_no_shell_rebuild_test.dart
    // for the same pattern).
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('scan tick appends a sample for a configured pen', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();

    final st = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
    final proj = st.debugActiveProject; // existing @visibleForTesting getter
    // Add an analog tag + a pen recording it.
    proj.tags.add(PlcTag(name: 'HistTag', path: 'HistTag', dataType: 'FLOAT64', value: 1.0, ioType: 'Internal'));
    proj.trends.add(TrendPen(tagPath: 'HistTag', sampleIntervalMs: 0));
    st.syncHistorianForTest();

    st.debugRunScan();
    expect(st.historianForTest.buffer('HistTag').isNotEmpty, isTrue);
  });
}
