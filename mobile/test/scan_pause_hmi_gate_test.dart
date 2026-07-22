// Regression: an HMI write (slider/switch/button) must NOT drive a scan tick
// while the PLC is paused. Previously `onScanTriggered` ran `_executeScan`
// gated only on `_faulted`, so dragging a slider while "PAUSED" fired a full
// scan (process-sim integrator + logic) and moved PV. The historian samples on
// every scan tick, so we use it to detect whether a scan actually ran.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('paused HMI scan-trigger runs no scan; running one does',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();

    final st = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
    final proj = st.debugActiveProject;
    proj.tags.add(PlcTag(
        name: 'HistTag', path: 'HistTag', dataType: 'FLOAT64', value: 1.0,
        ioType: 'Internal'));
    proj.trends.add(TrendPen(tagPath: 'HistTag', sampleIntervalMs: 0));
    st.syncHistorianForTest();

    // Paused: an HMI trigger must NOT run a scan (no historian sample).
    st.isRunning = false;
    st.debugHmiScanTrigger();
    await tester.pump();
    expect(st.historianForTest.buffer('HistTag').isEmpty, isTrue,
        reason: 'a paused HMI write must not drive a scan tick');

    // Running: the same HMI trigger DOES run a scan (sample appended).
    st.isRunning = true;
    st.debugHmiScanTrigger();
    await tester.pump();
    expect(st.historianForTest.buffer('HistTag').isNotEmpty, isTrue,
        reason: 'while running, an HMI write drives one scan tick');
  });
}
