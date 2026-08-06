// QA sweep item A1 (#11): every import path ends with an `Imported "<name>"`
// snackbar, but export gave no completion feedback at all — only the OS's
// native share/download indicator showed it worked. This adds a matching
// `Exported "<name>"` snackbar, shown from the same success-tail spot that
// `_exportActiveProject` reaches once `Share.shareXFiles` resolves.
//
// The real plugin call can't be driven from a widget test (see
// `_onExportSucceeded`'s doc comment in workspace_shell.dart, and
// `debugImportProject`'s doc comment for the same constraint on the import
// side), so this exercises the success tail directly via the
// `debugExportSucceeded` test hook — the same pattern `debugImportProject`
// already establishes for import.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('a successful export shows an Exported "<name>" snackbar', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();

    final state = tester.state<WorkspaceShellState>(find.byType(WorkspaceShell));
    final projectName = state.debugActiveProject.name;

    state.debugExportSucceeded('${projectName}_export.splc.json');
    await tester.pump();

    expect(find.text('Exported "$projectName"'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });
}
