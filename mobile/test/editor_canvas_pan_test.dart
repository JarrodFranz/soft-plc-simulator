// Canvas pan/scroll affordances wired into the real editors (QA §3.3).
//
// `pannable_canvas_test.dart` covers the widget in isolation; this file proves
// the two canvases that the finding is actually about behave correctly once
// mounted:
//
//   * FBD — lanes stack in one vertical scroller, so a plain wheel must scroll
//     the LANE LIST while Shift+wheel pans the lane sideways (the axis that
//     really clips), and the lane list must show its scrollbar thumb.
//   * LD compact — the ladder canvas owns both axes, so a plain wheel pans it
//     vertically.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:soft_plc_mobile/models/ld_graph.dart';
import 'package:soft_plc_mobile/models/ld_monitor.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/fbd_editor_screen.dart';
import 'package:soft_plc_mobile/screens/ld_editor_screen.dart';
import 'package:soft_plc_mobile/ui/pannable_canvas.dart';
import 'support/responsive_test_utils.dart';

Future<void> _wheel(WidgetTester tester, Offset where, Offset delta) async {
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(where));
  await tester.sendEventToBinding(pointer.scroll(delta));
  await tester.pumpAndSettle();
}

Future<void> _shiftWheel(WidgetTester tester, Offset where, Offset delta) async {
  await simulateKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  try {
    await _wheel(tester, where, delta);
  } finally {
    await simulateKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  }
}

// ------------------------------------------------------------------ FBD

PlcProject _fbdProject() => PlcProject(
      id: 'proj_pan_fbd',
      name: 'Pan FBD',
      controllerName: 'PLC',
      tags: const [],
      structDefs: const [],
      programs: const [],
      tasks: const [],
      hmis: const [],
    );

PlcProgram _fbdProgram() {
  final program = PlcProgram(name: 'FBD1', language: 'FunctionBlockDiagram');
  program.fbdBlocks.addAll([
    FbdBlock(id: 'and1', type: 'AND', title: 'And', x: 40, y: 40),
    // Far to the right, so the lane genuinely clips horizontally.
    FbdBlock(id: 'and2', type: 'AND', title: 'And 2', x: 1200, y: 40),
    // Low down, so the lane is taller than any test viewport and the lane
    // list genuinely has somewhere to scroll.
    FbdBlock(id: 'and3', type: 'AND', title: 'And 3', x: 40, y: 900),
  ]);
  return program;
}

// ------------------------------------------------------------------- LD

PlcProgram _ldProgram() {
  LdNode contact(String v) => LdNode(id: '', kind: LdKind.contact, variable: v);
  return PlcProgram(
    name: 'LD1',
    language: 'LadderLogic',
    rungs: [
      for (var i = 0; i < 8; i++)
        buildRung(
          index: i,
          comment: 'Rung $i',
          main: [
            contact('Sensor_$i'),
            LdNode(id: '', kind: LdKind.coil, variable: 'Out_$i'),
          ],
        ),
    ],
  );
}

PlcProject _ldProject(PlcProgram program) => PlcProject(
      id: 'proj_pan_ld',
      name: 'Pan LD',
      controllerName: 'PLC',
      tags: const [],
      structDefs: const [],
      programs: [program],
      tasks: const [],
      hmis: const [],
    );

void main() {
  group('FBD lane canvas', () {
    testWidgets('lanes hand the vertical wheel to the lane list and show its thumb',
        (tester) async {
      await setSurface(tester, desktopSize);
      final program = _fbdProgram();
      await tester.pumpWidget(MaterialApp(
        home: FbdEditorScreen(
          currentProject: _fbdProject(),
          program: program,
          onProgramUpdated: () {},
        ),
      ));
      await tester.pumpAndSettle();

      final canvas = find.byType(PannableCanvas).first;
      expect(tester.widget<PannableCanvas>(canvas).wheelPansVertically, isFalse);

      final scrollbar = find.ancestor(
        of: find.byType(PannableCanvas).first,
        matching: find.byType(Scrollbar),
      );
      expect(scrollbar, findsWidgets);
      expect(
        tester.widgetList<Scrollbar>(scrollbar).any((s) => s.thumbVisibility == true),
        isTrue,
        reason: 'the lane list scrollbar thumb must stay visible',
      );

      // A plain wheel notch over a lane scrolls the page, not the lane.
      final header = find.byKey(const Key('fbd_network_header_0'));
      final before = tester.getTopLeft(header);
      await _wheel(tester, tester.getCenter(canvas), const Offset(0, 120));
      expect(tester.getTopLeft(header).dy, lessThan(before.dy), reason: 'the lane list scrolled');
    });

    testWidgets('Shift+wheel pans the lane horizontally', (tester) async {
      await setSurface(tester, desktopSize);
      final program = _fbdProgram();
      await tester.pumpWidget(MaterialApp(
        home: FbdEditorScreen(
          currentProject: _fbdProject(),
          program: program,
          onProgramUpdated: () {},
        ),
      ));
      await tester.pumpAndSettle();

      final block = find.byKey(const Key('fbdpin_and1_out_OUT'));
      final before = tester.getTopLeft(block);
      await _shiftWheel(
          tester, tester.getCenter(find.byType(PannableCanvas).first), const Offset(0, 150));

      final after = tester.getTopLeft(block);
      expect(after.dx, lessThan(before.dx), reason: 'the canvas panned right');
      expect(after.dy, before.dy, reason: 'and only sideways');
    });

    testWidgets('a lane whose blocks all fit raises no clipped-content fade', (tester) async {
      await setSurface(tester, desktopSize);
      final program = PlcProgram(name: 'FBD1', language: 'FunctionBlockDiagram')
        ..fbdBlocks.add(FbdBlock(id: 'and1', type: 'AND', title: 'And', x: 20, y: 20));
      await tester.pumpWidget(MaterialApp(
        home: FbdEditorScreen(
          currentProject: _fbdProject(),
          program: program,
          onProgramUpdated: () {},
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(kPannableEdgeRightKey), findsNothing);
      expect(find.byKey(kPannableEdgeBottomKey), findsNothing);
    });

    testWidgets('a block placed off to the right raises the right-edge fade', (tester) async {
      await setSurface(tester, phoneSize);
      await tester.pumpWidget(MaterialApp(
        home: FbdEditorScreen(
          currentProject: _fbdProject(),
          program: _fbdProgram(),
          onProgramUpdated: () {},
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(kPannableEdgeRightKey), findsWidgets);
    });
  });

  group('LD compact ladder canvas', () {
    testWidgets('a plain wheel notch pans the ladder vertically', (tester) async {
      await setSurface(tester, const Size(390, 500));
      final program = _ldProgram();
      await tester.pumpWidget(MaterialApp(
        home: LdEditorScreen(
          currentProject: _ldProject(program),
          program: program,
          onProgramUpdated: () {},
          monitor: LdMonitor(),
          scanRunning: false,
        ),
      ));
      await tester.pumpAndSettle();

      final canvas = find.byType(PannableCanvas);
      expect(canvas, findsOneWidget);
      expect(tester.widget<PannableCanvas>(canvas).wheelPansVertically, isTrue);

      final rung = find.textContaining('RUNG 0').first;
      final before = tester.getTopLeft(rung);
      await _wheel(tester, tester.getCenter(canvas), const Offset(0, 100));

      expect(tester.getTopLeft(rung).dy, lessThan(before.dy));
    });

    testWidgets('the clipped bottom of the ladder is marked with a fade', (tester) async {
      await setSurface(tester, const Size(390, 500));
      final program = _ldProgram();
      await tester.pumpWidget(MaterialApp(
        home: LdEditorScreen(
          currentProject: _ldProject(program),
          program: program,
          onProgramUpdated: () {},
          monitor: LdMonitor(),
          scanRunning: false,
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byKey(kPannableEdgeBottomKey), findsOneWidget);
      expect(find.byKey(kPannableEdgeTopKey), findsNothing);
    });
  });
}
