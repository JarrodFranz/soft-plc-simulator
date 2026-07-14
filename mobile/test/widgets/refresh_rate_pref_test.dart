// Task 7: SoftPLC Settings dialog + global UI-refresh-rate preference.
//
// Covers:
//  (a) the pure `clampRefreshHz` helper clamps to 1-30.
//  (b) the pure `refreshWindow` helper maps hz -> the throttle Duration.
//  (c) the shell reads `ui_refresh_hz` from SharedPreferences at boot
//      (defaulting to 10 when the key is absent).
//  (d) `applyRefreshHz` clamps, updates `_refreshHz`, and persists the
//      clamped value back to `ui_refresh_hz`.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';

const String _kUiRefreshHzKey = 'ui_refresh_hz';

void main() {
  group('clampRefreshHz (pure helper)', () {
    test('clamps values below 1 up to 1', () {
      expect(clampRefreshHz(0), 1);
      expect(clampRefreshHz(-5), 1);
    });

    test('clamps values above 30 down to 30', () {
      expect(clampRefreshHz(31), 30);
      expect(clampRefreshHz(1000), 30);
    });

    test('passes 1..30 through unchanged', () {
      for (var hz = 1; hz <= 30; hz++) {
        expect(clampRefreshHz(hz), hz);
      }
    });
  });

  group('refreshWindow (pure helper)', () {
    test('maps hz to a millisecond Duration matching 1000/hz (rounded)', () {
      expect(refreshWindow(10), const Duration(milliseconds: 100));
      expect(refreshWindow(1), const Duration(milliseconds: 1000));
      expect(refreshWindow(30), Duration(milliseconds: (1000 / 30).round()));
    });

    test('clamps out-of-range hz before computing the window', () {
      expect(refreshWindow(0), refreshWindow(1));
      expect(refreshWindow(999), refreshWindow(30));
    });
  });

  group('shell boot + applyRefreshHz', () {
    testWidgets('defaults to 10Hz when ui_refresh_hz is absent', (tester) async {
      SharedPreferences.setMockInitialValues({});

      await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
      await tester.pumpAndSettle();

      final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
      expect(state.debugRefreshHz, 10);
    });

    testWidgets('reads a persisted ui_refresh_hz value at boot', (tester) async {
      SharedPreferences.setMockInitialValues({_kUiRefreshHzKey: 25});

      await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
      await tester.pumpAndSettle();

      final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
      expect(state.debugRefreshHz, 25);
    });

    testWidgets('applyRefreshHz(20) updates _refreshHz and persists to prefs', (tester) async {
      SharedPreferences.setMockInitialValues({});

      await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
      await tester.pumpAndSettle();

      final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
      await state.applyRefreshHz(20);
      await tester.pump();

      expect(state.debugRefreshHz, 20);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(_kUiRefreshHzKey), 20);
    });

    testWidgets('applyRefreshHz clamps out-of-range input before persisting', (tester) async {
      SharedPreferences.setMockInitialValues({});

      await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
      await tester.pumpAndSettle();

      final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
      await state.applyRefreshHz(500);
      await tester.pump();

      expect(state.debugRefreshHz, 30);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(_kUiRefreshHzKey), 30);
    });
  });
}
