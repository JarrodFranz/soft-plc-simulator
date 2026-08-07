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
      'activating the flagship starts no protocol host', (tester) async {
    // Sanity: the flagship really does ship enabled protocol configs.
    final flagship =
        DefaultProjects.all().firstWhere((p) => p.id == 'proj_flagship_line');
    expect(flagship.protocols!.modbus!.enabled, isTrue);
    expect(flagship.protocols!.opcua!.enabled, isTrue);
    final modbusPort = flagship.protocols!.modbus!.port;
    final opcuaPort = flagship.protocols!.opcua!.port;

    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();

    // The shell boots on `all()[0]` (the conveyor), so the flagship has to be
    // ACTIVATED for this gate to mean anything — the claim under test is
    // "loading the flagship starts no host", not "booting the conveyor does
    // not". Same pattern as workspace_undo_redo_test.dart's `openStProgram`.
    final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
    state.debugSwitchToProject(state.debugAllProjects
        .firstWhere((p) => p.id == 'proj_flagship_line'));
    await tester.pumpAndSettle();
    expect(state.debugActiveProject.id, 'proj_flagship_line');

    for (var i = 0; i < 5; i++) {
      state.debugRunScan();
    }
    await tester.pump();

    final hostEntries = state.debugLogger.entries.where(
        (e) => e.source == kLogSourceOpcUa || e.source == kLogSourceModbus);
    expect(hostEntries, isEmpty,
        reason:
            'a protocol host logged while the flagship was active — something '
            'auto-started it: '
            '${hostEntries.map((e) => "${e.source}: ${e.message}").join(" | ")}');

    // Direct evidence: both configured ports are still free. A started host
    // would be holding them and these binds would throw SocketException.
    // (The log check above cannot see a host that only logs below
    // AppLogger.kDefaultMinLevel, which is why this second check exists.)
    //
    // `ServerSocket.bind` is REAL async I/O, which the widget-test fake-async
    // zone never completes — it has to run inside `tester.runAsync`.
    //
    // Port 502 is privileged on Linux/macOS: an unprivileged CI user gets
    // EACCES rather than EADDRINUSE, which says nothing about whether a host
    // started. That one case is skipped with a note; every other bind failure
    // (notably address-already-in-use) is a hard failure, and 4840 is
    // unprivileged everywhere so it stays a hard assertion either way.
    final probe = await tester.runAsync(() async {
      final hardFailures = <String>[];
      final skipped = <String>[];
      for (final port in [modbusPort, opcuaPort]) {
        try {
          final socket =
              await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
          await socket.close();
        } on SocketException catch (e) {
          if (_isPermissionDenied(e) && port < 1024) {
            skipped.add('port $port (privileged, bind not permitted for this '
                'user — inconclusive, not a regression): $e');
          } else {
            hardFailures.add('port $port: $e');
          }
        }
      }
      return {'hard': hardFailures, 'skipped': skipped};
    });
    expect(probe, isNotNull,
        reason: 'runAsync did not complete — the port probe never ran');
    final hardFailures = probe?['hard'] ?? const <String>[];
    final skipped = probe?['skipped'] ?? const <String>[];
    if (skipped.isNotEmpty) {
      debugPrint('flagship_gateway_no_autostart: skipped '
          '${skipped.length} port probe(s): ${skipped.join(" | ")}');
    }
    expect(hardFailures, isEmpty,
        reason: 'a configured protocol port is already bound while the '
            'flagship is active — a protocol host auto-started (or another '
            'process holds it): ${hardFailures.join(" | ")}');

    expect(tester.takeException(), isNull);
  });
}

/// True when [e] is the OS refusing the bind for lack of privilege (EACCES on
/// POSIX, WSAEACCES on Windows) rather than reporting the port taken.
bool _isPermissionDenied(SocketException e) {
  final code = e.osError?.errorCode;
  if (code == 13 || code == 10013) return true;
  final message = (e.osError?.message ?? e.message).toLowerCase();
  return message.contains('permission denied') ||
      message.contains('access permissions') ||
      message.contains('permissions to access a socket');
}
