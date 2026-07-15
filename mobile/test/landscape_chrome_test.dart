// Landscape-phone (short viewport) chrome: the Scan Loop Speed bar is
// collapsed by default and revealed via an app-bar toggle, reclaiming
// vertical space; on taller viewports the bar always shows and there is
// no toggle.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';
import 'support/responsive_test_utils.dart';

void main() {
  testWidgets('short (landscape) viewport collapses the scan speed bar behind a toggle',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await setSurface(tester, const Size(900, 410)); // wide but short = landscape phone
    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();

    // Collapsed by default; the reveal toggle is present.
    expect(find.byKey(const Key('scanSpeedBar')), findsNothing);
    expect(find.byTooltip('Show scan speed bar'), findsOneWidget);

    // Tapping the toggle reveals the bar.
    await tester.tap(find.byTooltip('Show scan speed bar'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('scanSpeedBar')), findsOneWidget);
    expect(find.byTooltip('Hide scan speed bar'), findsOneWidget);
  });

  testWidgets('tall viewport always shows the scan speed bar and no toggle',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await setSurface(tester, const Size(400, 740)); // portrait phone (tall)
    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('scanSpeedBar')), findsOneWidget);
    expect(find.byTooltip('Show scan speed bar'), findsNothing);
  });
}
