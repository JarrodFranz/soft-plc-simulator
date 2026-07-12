import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';

void main() {
  // WorkspaceShell() boots via the real (non-injected) SharedPreferences
  // .getInstance() path. Mock initial values so that call actually resolves
  // inside the test's fake-async zone — see shell_responsive_test.dart for
  // the same pattern (an unmocked platform channel call never completes
  // there, hanging every pumpAndSettle() below).
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('fault banner shows task name and Clear Fault dismisses it', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();

    final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
    state.debugForceFault('PumpTask');
    await tester.pump();

    expect(find.textContaining('PumpTask'), findsWidgets);
    expect(find.text('Clear Fault'), findsOneWidget);

    await tester.tap(find.text('Clear Fault'));
    await tester.pump();
    expect(find.text('Clear Fault'), findsNothing);
  });
}
