// Canvas pan/scroll affordances (QA §3.3): the FBD lane canvas and the LD
// compact ladder canvas clipped at the pane boundary with no scrollbar, no
// minimap and a dead mouse wheel. `PannableCanvas` wraps their
// InteractiveViewer with wheel panning, scroll chaining and clipped-content
// edge fades — this locks the interaction model in.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:soft_plc_mobile/ui/pannable_canvas.dart';

/// Sends one wheel notch of [delta] at [where] in the test surface.
Future<void> _wheel(WidgetTester tester, Offset where, Offset delta) async {
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(where));
  await tester.sendEventToBinding(pointer.scroll(delta));
  await tester.pump();
}

Future<void> _withKey(LogicalKeyboardKey key, Future<void> Function() body) async {
  await simulateKeyDownEvent(key);
  try {
    await body();
  } finally {
    await simulateKeyUpEvent(key);
  }
}

Widget _host(
  TransformationController controller, {
  Size viewport = const Size(200, 200),
  Size content = const Size(1000, 1000),
  Rect? occupiedBounds,
  bool wheelPansVertically = true,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: viewport.width,
          height: viewport.height,
          child: PannableCanvas(
            transformationController: controller,
            contentSize: content,
            occupiedBounds: occupiedBounds,
            wheelPansVertically: wheelPansVertically,
            child: SizedBox(
              width: content.width,
              height: content.height,
              child: const ColoredBox(color: Colors.teal),
            ),
          ),
        ),
      ),
    ),
  );
}

double _tx(TransformationController c) => c.value.getTranslation().x;
double _ty(TransformationController c) => c.value.getTranslation().y;

void main() {
  group('PannableCanvas wheel panning', () {
    testWidgets('a plain wheel notch pans the canvas vertically', (tester) async {
      final controller = TransformationController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_host(controller));

      expect(_ty(controller), 0);
      await _wheel(tester, tester.getCenter(find.byType(PannableCanvas)), const Offset(0, 120));

      // Scrolling down reveals lower content: the scene moves UP by the delta.
      expect(_ty(controller), -120);
      expect(_tx(controller), 0);
    });

    testWidgets('Shift+wheel pans horizontally instead', (tester) async {
      final controller = TransformationController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_host(controller));

      await _withKey(LogicalKeyboardKey.shiftLeft, () async {
        await _wheel(tester, tester.getCenter(find.byType(PannableCanvas)), const Offset(0, 90));
      });

      expect(_tx(controller), -90);
      expect(_ty(controller), 0);
    });

    testWidgets('a trackpad horizontal delta pans horizontally with no modifier', (tester) async {
      final controller = TransformationController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_host(controller));

      await _wheel(tester, tester.getCenter(find.byType(PannableCanvas)), const Offset(45, 0));

      expect(_tx(controller), -45);
      expect(_ty(controller), 0);
    });

    testWidgets('the pan stops at the content edge instead of running off into space',
        (tester) async {
      final controller = TransformationController();
      addTearDown(controller.dispose);
      // 300 tall content in a 200 tall viewport: only 100px of travel exists.
      await tester.pumpWidget(
        _host(controller, content: const Size(300, 300)),
      );
      final at = tester.getCenter(find.byType(PannableCanvas));

      await _wheel(tester, at, const Offset(0, 400));
      expect(_ty(controller), -100);

      // Scrolling back up stops at the start edge.
      await _wheel(tester, at, const Offset(0, -400));
      expect(_ty(controller), 0);
    });

    testWidgets('Ctrl+wheel zooms about the pointer rather than panning', (tester) async {
      final controller = TransformationController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_host(controller));

      await _withKey(LogicalKeyboardKey.controlLeft, () async {
        await _wheel(tester, tester.getCenter(find.byType(PannableCanvas)), const Offset(0, -100));
      });

      expect(controller.value.getMaxScaleOnAxis(), greaterThan(1.0));
    });

    testWidgets(
        'wheelPansVertically:false leaves the vertical wheel alone but still '
        'pans on Shift+wheel', (tester) async {
      final controller = TransformationController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_host(controller, wheelPansVertically: false));
      final at = tester.getCenter(find.byType(PannableCanvas));

      await _wheel(tester, at, const Offset(0, 120));
      expect(_ty(controller), 0);
      expect(_tx(controller), 0);

      await _withKey(LogicalKeyboardKey.shiftLeft, () async {
        await _wheel(tester, at, const Offset(0, 120));
      });
      expect(_tx(controller), -120);
    });

    testWidgets('an exhausted pan chains to the enclosing Scrollable', (tester) async {
      final controller = TransformationController();
      addTearDown(controller.dispose);
      final outer = ScrollController();
      addTearDown(outer.dispose);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: outer,
            children: [
              SizedBox(
                width: 200,
                height: 200,
                child: PannableCanvas(
                  transformationController: controller,
                  // Content fits the viewport exactly: nothing to pan.
                  contentSize: const Size(200, 200),
                  child: const SizedBox(width: 200, height: 200),
                ),
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      ));

      await _wheel(tester, const Offset(100, 100), const Offset(0, 150));

      expect(_ty(controller), 0, reason: 'canvas had no room to pan');
      expect(outer.offset, 150, reason: 'the wheel notch fell through to the page');
    });

    testWidgets('a pan that DOES move is not also handed to the enclosing Scrollable',
        (tester) async {
      final controller = TransformationController();
      addTearDown(controller.dispose);
      final outer = ScrollController();
      addTearDown(outer.dispose);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: outer,
            children: [
              SizedBox(
                width: 200,
                height: 200,
                child: PannableCanvas(
                  transformationController: controller,
                  contentSize: const Size(1000, 1000),
                  child: const SizedBox(width: 1000, height: 1000),
                ),
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      ));

      await _wheel(tester, const Offset(100, 100), const Offset(0, 150));

      expect(_ty(controller), -150);
      expect(outer.offset, 0);
    });

    testWidgets(
        'QA F5: with wheelPansVertically:false, a diagonal notch pans the canvas '
        'horizontally but still lets its vertical component chain to the enclosing '
        'lane list', (tester) async {
      final controller = TransformationController();
      addTearDown(controller.dispose);
      final outer = ScrollController();
      addTearDown(outer.dispose);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: outer,
            children: [
              SizedBox(
                width: 200,
                height: 200,
                child: PannableCanvas(
                  transformationController: controller,
                  contentSize: const Size(1000, 1000),
                  wheelPansVertically: false,
                  child: const SizedBox(width: 1000, height: 1000),
                ),
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      ));

      // A single trackpad notch with both components set (the diagonal case):
      // dx is real horizontal intent, dy is the incidental vertical wobble a
      // trackpad reports even on a "mostly horizontal" swipe.
      await _wheel(tester, const Offset(100, 100), const Offset(40, 90));

      // The horizontal component is consumed by the canvas...
      expect(_tx(controller), -40);
      expect(_ty(controller), 0,
          reason: 'wheelPansVertically:false means the canvas itself never reacts '
              'to the vertical component');
      // ...but before the fix, panning horizontally claimed the WHOLE notch,
      // so the vertical component never reached the lane list either. It must
      // now chain through exactly like a plain vertical notch would.
      expect(outer.offset, 90,
          reason: "a diagonal notch's vertical component must still reach the "
              'enclosing lane list, not be swallowed by the canvas claiming the '
              'whole notch');
    });
  });

  group('PannableCanvas clipped-content edges', () {
    testWidgets('content overflowing right/bottom fades those edges only', (tester) async {
      final controller = TransformationController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_host(controller));

      expect(find.byKey(kPannableEdgeRightKey), findsOneWidget);
      expect(find.byKey(kPannableEdgeBottomKey), findsOneWidget);
      expect(find.byKey(kPannableEdgeLeftKey), findsNothing);
      expect(find.byKey(kPannableEdgeTopKey), findsNothing);
    });

    testWidgets('panning down raises the top fade', (tester) async {
      final controller = TransformationController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_host(controller));

      await _wheel(tester, tester.getCenter(find.byType(PannableCanvas)), const Offset(0, 120));

      expect(find.byKey(kPannableEdgeTopKey), findsOneWidget);
    });

    testWidgets('content that fits gets no fades at all', (tester) async {
      final controller = TransformationController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_host(controller, content: const Size(200, 200)));

      expect(find.byKey(kPannableEdgeRightKey), findsNothing);
      expect(find.byKey(kPannableEdgeBottomKey), findsNothing);
    });

    testWidgets('occupiedBounds, not the oversized canvas box, decides the fades', (tester) async {
      final controller = TransformationController();
      addTearDown(controller.dispose);
      // A 1000x1000 canvas whose only real content sits inside the 200x200
      // viewport: nothing is clipped, so nothing should hint that it is.
      await tester.pumpWidget(_host(
        controller,
        occupiedBounds: const Rect.fromLTWH(10, 10, 100, 100),
      ));

      expect(find.byKey(kPannableEdgeRightKey), findsNothing);
      expect(find.byKey(kPannableEdgeBottomKey), findsNothing);
    });

    testWidgets('an empty occupied rect never fades', (tester) async {
      final controller = TransformationController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(_host(controller, occupiedBounds: Rect.zero));

      expect(find.byKey(kPannableEdgeLeftKey), findsNothing);
      expect(find.byKey(kPannableEdgeRightKey), findsNothing);
      expect(find.byKey(kPannableEdgeTopKey), findsNothing);
      expect(find.byKey(kPannableEdgeBottomKey), findsNothing);
    });

    testWidgets('the fades never swallow a tap meant for the canvas', (tester) async {
      final controller = TransformationController();
      addTearDown(controller.dispose);
      var taps = 0;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              height: 200,
              child: PannableCanvas(
                transformationController: controller,
                contentSize: const Size(1000, 1000),
                child: GestureDetector(
                  onTap: () => taps++,
                  child: const SizedBox(
                      width: 1000, height: 1000, child: ColoredBox(color: Colors.teal)),
                ),
              ),
            ),
          ),
        ),
      ));

      // Right on the right-hand fade strip.
      await tester.tapAt(tester.getBottomRight(find.byType(PannableCanvas)) - const Offset(6, 6));
      await tester.pump();

      expect(taps, 1);
    });
  });
}
