// QA sweep item A5 (#12): at 390px width the "Project actions" (⋮) tap
// target sat ~12px below its painted glyph. The trigger used
// `PopupMenuButton(icon: ...)`, which routes through IconButton's forced
// 48x48 minimum tap-target box; using `child:` instead wraps exactly the
// icon's own Padding in the InkWell (shrink-wrap tap target size), so the
// hit-testable region is the same rect as what's painted — no separate
// IconButton-sized box to drift out of alignment with the glyph.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:soft_plc_mobile/screens/workspace_shell.dart';
import 'support/responsive_test_utils.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Project actions trigger renders as a PopupMenuButton.child (icon painted '
      'inside the same box the InkWell hit-tests), not the icon-property path', (tester) async {
    await setSurface(tester, phoneSize);
    await tester.pumpWidget(const MaterialApp(home: WorkspaceShell()));
    await tester.pumpAndSettle();

    final hamburger = find.byTooltip('Open navigation menu');
    if (hamburger.evaluate().isNotEmpty) {
      await tester.tap(hamburger);
      await tester.pumpAndSettle();
    }

    final popupFinder = find.byWidgetPredicate(
      (w) => w is PopupMenuButton<String> && w.tooltip == 'Project actions',
    );
    expect(popupFinder, findsOneWidget);
    final popup = tester.widget<PopupMenuButton<String>>(popupFinder);

    // `icon:` is the path with the alignment bug (forced 48x48 IconButton
    // box independent of the glyph's own bounds); `child:` is the fix.
    expect(popup.icon, isNull);
    expect(popup.child, isNotNull);

    // The glyph itself must still be present and reachable.
    expect(
      find.descendant(of: popupFinder, matching: find.byIcon(Icons.more_vert)),
      findsOneWidget,
    );

    // Tapping the trigger's own bounds (whatever they are) must still open
    // the menu — i.e. the hit region and the painted widget coincide.
    await tester.tap(popupFinder);
    await tester.pumpAndSettle();
    expect(find.text('New Project'), findsOneWidget);

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
