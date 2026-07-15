import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/ui/responsive.dart';
import 'support/responsive_test_utils.dart';

void main() {
  testWidgets('widthClass / isCompact / isExpanded reflect surface width',
      (tester) async {
    late WidthClass wc;
    late bool compact;
    late bool expanded;
    Widget probe() => MaterialApp(
          home: Builder(builder: (ctx) {
            wc = ctx.widthClass;
            compact = ctx.isCompact;
            expanded = ctx.isExpanded;
            return const SizedBox();
          }),
        );

    await setSurface(tester, phoneSize);
    await tester.pumpWidget(probe());
    expect(wc, WidthClass.compact);
    expect(compact, isTrue);
    expect(expanded, isFalse);

    await setSurface(tester, const Size(760, 900));
    await tester.pumpWidget(probe());
    expect(wc, WidthClass.medium);
    expect(compact, isFalse);
    expect(expanded, isFalse);

    await setSurface(tester, desktopSize);
    await tester.pumpWidget(probe());
    expect(wc, WidthClass.expanded);
    expect(expanded, isTrue);

    // A phone in landscape is WIDE (>= 840) but SHORT (< 600 tall): it must NOT
    // get the 3-pane desktop IDE — it falls back to the adaptive/drawer layout.
    await setSurface(tester, const Size(900, 410));
    await tester.pumpWidget(probe());
    expect(wc, WidthClass.medium);
    expect(compact, isFalse);
    expect(expanded, isFalse);

    // A genuinely large landscape viewport (tablet/desktop) stays expanded.
    await setSurface(tester, const Size(1200, 800));
    await tester.pumpWidget(probe());
    expect(wc, WidthClass.expanded);
    expect(expanded, isTrue);
  });

  test('isExpandedSize requires both width and height', () {
    expect(isExpandedSize(const Size(1400, 900)), isTrue); // desktop
    expect(isExpandedSize(const Size(900, 410)), isFalse); // landscape phone (short)
    expect(isExpandedSize(const Size(760, 900)), isFalse); // too narrow
    expect(isExpandedSize(const Size(840, 600)), isTrue); // exact thresholds
    expect(isExpandedSize(const Size(840, 599)), isFalse); // 1px too short
  });

  test('isShortSize keys on height only', () {
    expect(isShortSize(const Size(900, 410)), isTrue); // landscape phone
    expect(isShortSize(const Size(360, 740)), isFalse); // portrait phone (tall)
    expect(isShortSize(const Size(1400, 900)), isFalse); // desktop
    expect(isShortSize(const Size(900, 499)), isTrue); // just under threshold
    expect(isShortSize(const Size(900, 500)), isFalse); // exact threshold
  });

  testWidgets('showAdaptiveWidthDialog clamps to viewport on a phone',
      (tester) async {
    await setSurface(tester, phoneSize);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              // Real callers always pass an AlertDialog (its own dialog
              // surface); use one here so the test mirrors production usage.
              onPressed: () => showAdaptiveWidthDialog(ctx,
                  desiredWidth: 460,
                  child: const AlertDialog(content: SizedBox(height: 80))),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // Assert the CLAMP CONSTRAINT itself, not a rendered size (the child is
    // narrow so its rendered width is bounded regardless, and the screen
    // physically caps width anyway — either would pass even if the clamp were
    // removed). Our ConstrainedBox must be clamped to
    // min(desiredWidth 460, screenWidth 360 - 32) == 328, so every finite
    // maxWidth in the dialog subtree must be <= 328 and 328 must be present.
    // Deleting the clamp makes our box maxWidth 460 > 328 and fails this test.
    final finiteMaxWidths = tester
        .widgetList<ConstrainedBox>(find.ancestor(
            of: find.byType(AlertDialog), matching: find.byType(ConstrainedBox)))
        .map((b) => b.constraints.maxWidth)
        .where((w) => w.isFinite)
        .toList();
    expect(finiteMaxWidths, isNotEmpty);
    expect(finiteMaxWidths.every((w) => w <= 360 - 32), isTrue);
    expect(finiteMaxWidths, contains(360.0 - 32));
    // Regression guard for the vertical over-expansion this replaced: the old
    // wrapper put an outer Dialog around the caller's AlertDialog (itself a
    // Dialog), and that nesting painted the outer surface as a full-height
    // sheet. The fix wraps in a plain Align, so exactly ONE Dialog (the
    // AlertDialog's own) must exist in the tree — two means the double-wrap
    // is back.
    expect(find.byType(Dialog), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('touchable guarantees a >= kMinTouch hit area', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Center(child: touchable(const Icon(Icons.close, size: 16)))),
    ));
    final size = tester.getSize(find.byType(ConstrainedBox).first);
    expect(size.width, greaterThanOrEqualTo(kMinTouch));
    expect(size.height, greaterThanOrEqualTo(kMinTouch));
  });
}
