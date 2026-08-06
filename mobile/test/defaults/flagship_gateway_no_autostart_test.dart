import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soft_plc_mobile/data/default_projects.dart';
import 'package:soft_plc_mobile/models/app_log.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';

/// §4.6 verification gate: the flagship ships Modbus + OPC UA with
/// `enabled: true` so the Gateway screen has live content out of the box. That
/// is only safe because nothing auto-starts a host on project load — `start()`
/// is reached exclusively from the Gateway screen's toggle. If this test ever
/// fails, ship those configs with `enabled: false` and record the finding in
/// docs/DEFERRED.md; do NOT change host code (no-engine-changes rule).
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
      'booting the shell with the flagship in the catalog starts no '
      'protocol host', (tester) async {
    // Sanity: the flagship really does ship enabled protocol configs.
    final flagship =
        DefaultProjects.all().firstWhere((p) => p.id == 'proj_flagship_line');
    expect(flagship.protocols!.modbus!.enabled, isTrue);
    expect(flagship.protocols!.opcua!.enabled, isTrue);

    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();

    final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
    for (var i = 0; i < 5; i++) {
      state.debugRunScan();
    }
    await tester.pump();

    final hostEntries = state.debugLogger.entries.where(
        (e) => e.source == kLogSourceOpcUa || e.source == kLogSourceModbus);
    expect(hostEntries, isEmpty,
        reason:
            'a protocol host logged during boot/scan — something auto-started it: '
            '${hostEntries.map((e) => "${e.source}: ${e.message}").join(" | ")}');

    // Direct evidence: both configured ports are still free. A started host
    // would be holding them and these binds would throw SocketException.
    // (The log check above cannot see a host that only logs below
    // AppLogger.kDefaultMinLevel, which is why this second check exists.)
    //
    // `ServerSocket.bind` is REAL async I/O, which the widget-test fake-async
    // zone never completes — it has to run inside `tester.runAsync`.
    final bindFailures = await tester.runAsync(() async {
      final failures = <String>[];
      for (final port in [502, 4840]) {
        try {
          final probe =
              await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
          await probe.close();
        } on SocketException catch (e) {
          failures.add('port $port: $e');
        }
      }
      return failures;
    });
    expect(bindFailures, isEmpty,
        reason: 'a configured protocol port is already bound after booting on '
            'the flagship — a protocol host auto-started (or another process '
            'holds it): ${bindFailures?.join(" | ")}');

    expect(tester.takeException(), isNull);
  });
}
