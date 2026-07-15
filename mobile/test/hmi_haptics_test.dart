// Haptic feedback on HMI pushbuttons + toggles, with a global on/off setting.
//
// Covers:
//  (a) a PushbuttonSwitch / ToggleSwitch press fires a HapticFeedback platform
//      call when haptics are enabled, and none when disabled.
//  (b) the shell reads `haptics_enabled` from SharedPreferences at boot
//      (default true), and `applyHapticsEnabled` updates + persists it.
//  (c) the SoftPLC Settings dialog surfaces the toggle and returns it on Save.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/hmi_dashboard_builder_screen.dart';
import 'package:soft_plc_mobile/screens/softplc_settings_dialog.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';
import 'package:soft_plc_mobile/services/tag_historian.dart';
import 'package:soft_plc_mobile/widgets/live_tick.dart';

PlcProject _projWith(HmiComponent comp) {
  return PlcProject(
    id: 'p', name: 'P', controllerName: 'C',
    tags: [PlcTag(name: 'Btn', path: 'Btn', dataType: 'BOOL', value: false, ioType: 'Internal')],
    structDefs: [], programs: [], tasks: [],
    hmis: [HmiScreenDef(id: 'h', title: 'S', components: [comp])],
  );
}

Future<void> _pumpHmi(
  WidgetTester tester, {
  required bool haptics,
  required HmiComponent comp,
  required List<MethodCall> calls,
}) async {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      calls.add(call);
      return null;
    },
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));

  final proj = _projWith(comp);
  await tester.pumpWidget(MaterialApp(
    home: LiveTickScope(
      notifier: LiveTick(),
      child: HmiDashboardBuilderScreen(
        currentProject: proj,
        hmiScreen: proj.hmis.first,
        onScanTriggered: () {},
        onProjectUpdated: () {},
        historian: TagHistorian(),
        hapticsEnabled: haptics,
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

bool _hadHaptic(List<MethodCall> calls) =>
    calls.any((c) => c.method == 'HapticFeedback.vibrate');

void main() {
  testWidgets('pushbutton press fires a haptic pulse when enabled', (tester) async {
    final calls = <MethodCall>[];
    await _pumpHmi(
      tester,
      haptics: true,
      comp: HmiComponent(id: 'b1', title: 'PUSH', type: 'PushbuttonSwitch', tagBinding: 'Btn'),
      calls: calls,
    );

    await tester.tap(find.widgetWithText(ElevatedButton, 'PUSH'));
    await tester.pump();
    expect(_hadHaptic(calls), isTrue);
    await tester.pump(const Duration(milliseconds: 350)); // drain momentary release timer
  });

  testWidgets('pushbutton press does NOT fire a haptic when disabled', (tester) async {
    final calls = <MethodCall>[];
    await _pumpHmi(
      tester,
      haptics: false,
      comp: HmiComponent(id: 'b1', title: 'PUSH', type: 'PushbuttonSwitch', tagBinding: 'Btn'),
      calls: calls,
    );

    await tester.tap(find.widgetWithText(ElevatedButton, 'PUSH'));
    await tester.pump();
    expect(_hadHaptic(calls), isFalse);
    await tester.pump(const Duration(milliseconds: 350));
  });

  testWidgets('toggle switch fires a haptic pulse when enabled', (tester) async {
    final calls = <MethodCall>[];
    await _pumpHmi(
      tester,
      haptics: true,
      comp: HmiComponent(id: 't1', title: 'TOG', type: 'ToggleSwitch', tagBinding: 'Btn'),
      calls: calls,
    );

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(_hadHaptic(calls), isTrue);
  });

  group('shell haptics preference', () {
    testWidgets('defaults to enabled when haptics_enabled is absent', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
      await tester.pumpAndSettle();
      final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
      expect(state.debugHapticsEnabled, isTrue);
    });

    testWidgets('reads a persisted haptics_enabled=false at boot', (tester) async {
      SharedPreferences.setMockInitialValues({'haptics_enabled': false});
      await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
      await tester.pumpAndSettle();
      final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
      expect(state.debugHapticsEnabled, isFalse);
    });

    testWidgets('applyHapticsEnabled(false) updates and persists', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
      await tester.pumpAndSettle();
      final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));

      await state.applyHapticsEnabled(false);
      await tester.pump();

      expect(state.debugHapticsEnabled, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('haptics_enabled'), false);
    });
  });

  testWidgets('settings dialog toggles haptics and returns it on Save', (tester) async {
    SoftPlcSettingsResult? result;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              result = await showDialog<SoftPlcSettingsResult>(
                context: context,
                builder: (_) => const SoftPlcSettingsDialog(
                  initialRefreshHz: 10,
                  initialHapticsEnabled: true,
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Turn haptics off, then Save.
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.refreshHz, 10);
    expect(result!.hapticsEnabled, isFalse);
  });
}
