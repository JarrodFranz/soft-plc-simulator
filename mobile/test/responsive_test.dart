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
  });

  testWidgets('showAdaptiveWidthDialog clamps to viewport on a phone',
      (tester) async {
    await setSurface(tester, phoneSize);
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showAdaptiveWidthDialog(ctx,
                  desiredWidth: 460, child: const SizedBox(height: 80)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final box = tester.getSize(find
        .descendant(of: find.byType(Dialog), matching: find.byType(ConstrainedBox))
        .first);
    expect(box.width, lessThanOrEqualTo(360 - 32));
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
