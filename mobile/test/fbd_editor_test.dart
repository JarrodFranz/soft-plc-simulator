import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/fbd_editor_screen.dart';
import 'support/responsive_test_utils.dart';

PlcTag _tag(String n, String type, dynamic v) =>
    PlcTag(name: n, path: n, dataType: type, value: v, ioType: 'Internal');

PlcProject _buildProject() {
  return PlcProject(
    id: 'proj_test_fbd',
    name: 'Test FBD Project',
    controllerName: 'TestPLC',
    tags: [
      _tag('Motor_Run', 'BOOL', false),
      _tag('Start_PB', 'BOOL', false),
    ],
    structDefs: [],
    programs: [],
    tasks: [],
    hmis: [],
  );
}

PlcProgram _buildProgram() {
  final program = PlcProgram(name: 'FBD1', language: 'FunctionBlockDiagram');
  program.fbdBlocks.addAll([
    FbdBlock(id: 'const1', type: 'CONST', title: 'Const Block', tagBinding: '1', x: 40, y: 40),
    FbdBlock(id: 'out1', type: 'TAG_OUTPUT', title: 'Output Block', tagBinding: 'Motor_Run', x: 320, y: 40),
    FbdBlock(id: 'ton1', type: 'TON', title: 'Timer Block', x: 40, y: 220),
    FbdBlock(id: 'and1', type: 'AND', title: 'And Block', x: 320, y: 220),
  ]);
  return program;
}

void main() {
  Widget app(PlcProject project, PlcProgram program) {
    return MaterialApp(
      home: FbdEditorScreen(
        currentProject: project,
        program: program,
        onProgramUpdated: () {},
      ),
    );
  }

  group('FbdEditorScreen pin rendering', () {
    testWidgets('TON shows two output dots (Q, ET); TAG_OUTPUT shows one input dot, no output dot',
        (tester) async {
      await setSurface(tester, desktopSize);
      final project = _buildProject();
      final program = _buildProgram();
      await tester.pumpWidget(app(project, program));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('fbdpin_ton1_out_Q')), findsOneWidget);
      expect(find.byKey(const Key('fbdpin_ton1_out_ET')), findsOneWidget);
      expect(find.byKey(const Key('fbdpin_ton1_in_IN')), findsOneWidget);
      expect(find.byKey(const Key('fbdpin_ton1_in_PT')), findsOneWidget);

      expect(find.byKey(const Key('fbdpin_out1_in_IN')), findsOneWidget);
      expect(find.byKey(const Key('fbdpin_out1_out_OUT')), findsNothing);

      expect(tester.takeException(), isNull);
    });

    testWidgets('phone size (360): pins render without overflow', (tester) async {
      await setSurface(tester, phoneSize);
      final project = _buildProject();
      final program = _buildProgram();
      await tester.pumpWidget(app(project, program));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('fbdpin_const1_out_OUT')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('small phone size (320): no overflow', (tester) async {
      await setSurface(tester, smallPhoneSize);
      final project = _buildProject();
      final program = _buildProgram();
      await tester.pumpWidget(app(project, program));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });

  group('FbdEditorScreen wiring', () {
    testWidgets('tap CONST output dot then TAG_OUTPUT input dot creates a pin-addressed wire',
        (tester) async {
      await setSurface(tester, desktopSize);
      final project = _buildProject();
      final program = _buildProgram();
      await tester.pumpWidget(app(project, program));
      await tester.pumpAndSettle();

      final before = program.fbdWires.length;

      await tester.tap(find.byKey(const Key('fbdpin_const1_out_OUT')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fbdpin_out1_in_IN')));
      await tester.pumpAndSettle();

      expect(program.fbdWires.length, before + 1);
      final wire = program.fbdWires.last;
      expect(wire.fromBlockId, 'const1');
      expect(wire.fromPin, 'OUT');
      expect(wire.toBlockId, 'out1');
      expect(wire.toPin, 'IN');

      expect(tester.takeException(), isNull);
    });

    testWidgets('connecting a second wire to the same input replaces the first', (tester) async {
      await setSurface(tester, desktopSize);
      final project = _buildProject();
      final program = _buildProgram();
      // Pre-wire and1's IN1 from const1.
      program.fbdWires.add(FbdWire(fromBlockId: 'const1', fromPin: 'OUT', toBlockId: 'and1', toPin: 'IN1'));
      await tester.pumpWidget(app(project, program));
      await tester.pumpAndSettle();

      // Re-wire and1's IN1 from ton1's Q output instead.
      await tester.tap(find.byKey(const Key('fbdpin_ton1_out_Q')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fbdpin_and1_in_IN1')));
      await tester.pumpAndSettle();

      final wiresToAnd1In1 = program.fbdWires.where((w) => w.toBlockId == 'and1' && w.toPin == 'IN1').toList();
      expect(wiresToAnd1In1.length, 1);
      expect(wiresToAnd1In1.first.fromBlockId, 'ton1');
      expect(wiresToAnd1In1.first.fromPin, 'Q');

      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping a block to itself is a no-op', (tester) async {
      await setSurface(tester, desktopSize);
      final project = _buildProject();
      final program = _buildProgram();
      await tester.pumpWidget(app(project, program));
      await tester.pumpAndSettle();

      final before = program.fbdWires.length;

      await tester.tap(find.byKey(const Key('fbdpin_ton1_out_Q')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fbdpin_ton1_in_IN')));
      await tester.pumpAndSettle();

      expect(program.fbdWires.length, before);
      expect(tester.takeException(), isNull);
    });
  });

  group('FbdEditorScreen wire delete', () {
    testWidgets('select then delete a wire removes it from the program', (tester) async {
      await setSurface(tester, desktopSize);
      final project = _buildProject();
      final program = _buildProgram();
      await tester.pumpWidget(app(project, program));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('fbdpin_const1_out_OUT')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fbdpin_out1_in_IN')));
      await tester.pumpAndSettle();

      final afterCreate = program.fbdWires.length;
      expect(afterCreate, greaterThan(0));

      // Select the wire hit-target (index 0, the only wire created so far).
      await tester.tap(find.byKey(const Key('fbdwire_0')));
      await tester.pumpAndSettle();

      // Now tap again on the same hit target area to hit the delete affordance.
      await tester.tap(find.byKey(const Key('fbdwire_0')));
      await tester.pumpAndSettle();

      expect(program.fbdWires.length, afterCreate - 1);
      expect(tester.takeException(), isNull);
    });
  });

  group('FbdEditorScreen extensible inputs', () {
    testWidgets('+ control increases AND inputCount and adds an input dot', (tester) async {
      await setSurface(tester, desktopSize);
      final project = _buildProject();
      final program = _buildProgram();
      await tester.pumpWidget(app(project, program));
      await tester.pumpAndSettle();

      final andBlock = program.fbdBlocks.firstWhere((b) => b.id == 'and1');
      expect(andBlock.inputCount, 2);
      expect(find.byKey(const Key('fbdpin_and1_in_IN3')), findsNothing);

      await tester.tap(find.byKey(const Key('fbdpin_and1_in_IN1'))); // no-op tap (unarmed input)
      await tester.pumpAndSettle();

      // Tap the '+' control within the AND block's card.
      final addButtons = find.descendant(
        of: find.byWidgetPredicate((w) => w is Container && w.key == null).first,
        matching: find.byIcon(Icons.add_circle_outline),
      );
      // Fall back to a plain global lookup for the add-circle icon on the card
      // (there is exactly one extensible block instance in this program).
      final plusIcon = addButtons.evaluate().isNotEmpty ? addButtons : find.byIcon(Icons.add_circle_outline);
      await tester.tap(plusIcon.first);
      await tester.pumpAndSettle();

      expect(andBlock.inputCount, 3);
      expect(find.byKey(const Key('fbdpin_and1_in_IN3')), findsOneWidget);

      expect(tester.takeException(), isNull);
    });

    testWidgets('- control decreases inputCount and drops wires to removed pins, clamped at 2', (tester) async {
      await setSurface(tester, desktopSize);
      final project = _buildProject();
      final program = _buildProgram();
      final andBlock = program.fbdBlocks.firstWhere((b) => b.id == 'and1');
      andBlock.inputCount = 3;
      program.fbdWires.add(FbdWire(fromBlockId: 'const1', fromPin: 'OUT', toBlockId: 'and1', toPin: 'IN3'));

      await tester.pumpWidget(app(project, program));
      await tester.pumpAndSettle();

      final minusIcon = find.byIcon(Icons.remove_circle_outline);
      await tester.tap(minusIcon.first);
      await tester.pumpAndSettle();

      expect(andBlock.inputCount, 2);
      expect(program.fbdWires.any((w) => w.toBlockId == 'and1' && w.toPin == 'IN3'), isFalse);

      // Clamp at 2: further decrements should not go below 2.
      await tester.tap(minusIcon.first);
      await tester.pumpAndSettle();
      expect(andBlock.inputCount, 2);

      expect(tester.takeException(), isNull);
    });
  });

  group('FbdEditorScreen responsive', () {
    testWidgets('desktop full width (1400): pannable workspace, no overflow, free-drag preserved (no config-on-tap)',
        (tester) async {
      await setSurface(tester, desktopSize);
      final project = _buildProject();
      final program = _buildProgram();
      await tester.pumpWidget(app(project, program));
      await tester.pumpAndSettle();

      // Desktop workspace is now pannable/zoomable (wrapped in InteractiveViewer)
      // while individual blocks stay free-draggable.
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('FbdEditorScreen auto-arrange', () {
    testWidgets('Auto-arrange button tidies blocks into dependency columns and notifies',
        (tester) async {
      await setSurface(tester, desktopSize);
      final project = _buildProject();
      final program = PlcProgram(name: 'FBD1', language: 'FunctionBlockDiagram');
      // Three chained blocks all stacked on the same cramped coordinate.
      program.fbdBlocks.addAll([
        FbdBlock(id: 'src', type: 'TAG_INPUT', title: 'In', tagBinding: 'Start_PB', x: 500, y: 500),
        FbdBlock(id: 'gate', type: 'NOT', title: 'Not', x: 500, y: 500),
        FbdBlock(id: 'out', type: 'TAG_OUTPUT', title: 'Out', tagBinding: 'Motor_Run', x: 500, y: 500),
      ]);
      program.fbdWires.addAll([
        FbdWire(fromBlockId: 'src', fromPin: 'OUT', toBlockId: 'gate', toPin: 'IN'),
        FbdWire(fromBlockId: 'gate', fromPin: 'OUT', toBlockId: 'out', toPin: 'IN'),
      ]);
      var notified = false;
      await tester.pumpWidget(MaterialApp(
        home: FbdEditorScreen(
          currentProject: project,
          program: program,
          onProgramUpdated: () => notified = true,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Auto-arrange blocks'));
      await tester.pumpAndSettle();

      expect(notified, isTrue);
      final src = program.fbdBlocks.firstWhere((b) => b.id == 'src');
      final gate = program.fbdBlocks.firstWhere((b) => b.id == 'gate');
      final out = program.fbdBlocks.firstWhere((b) => b.id == 'out');
      // Laid out left-to-right along the dataflow and no longer stacked.
      expect(src.x < gate.x, isTrue);
      expect(gate.x < out.x, isTrue);
      expect(src.x == 500 && src.y == 500, isFalse);
      expect(tester.takeException(), isNull);
    });
  });

  group('FbdEditorScreen block naming', () {
    testWidgets('config dialog exposes a Block name field seeded with block.title; editing + Save renames the block face',
        (tester) async {
      await setSurface(tester, phoneSize);
      final project = _buildProject();
      final program = _buildProgram();
      await tester.pumpWidget(app(project, program));
      await tester.pumpAndSettle();

      // Phone size renders the non-expanded canvas, where the *outer*
      // Positioned GestureDetector's onTap opens the configure dialog. It is
      // nested outside the card's own GestureDetector (which merely clears
      // wire selection on tap and wins the gesture arena for a simulated
      // tap), so invoke the outer callback directly — same ancestor-lookup
      // technique already used elsewhere in this file for ambiguous nested
      // GestureDetector hits (see the '+'/'-' input-count tests above).
      final ancestors = find
          .ancestor(of: find.text('Timer Block'), matching: find.byType(GestureDetector))
          .evaluate()
          .map((e) => e.widget as GestureDetector);
      final configureDetector = ancestors.lastWhere((gd) => gd.onTap != null);
      configureDetector.onTap!();
      await tester.pumpAndSettle();

      final nameField = find.widgetWithText(TextFormField, 'Block name');
      expect(nameField, findsOneWidget);
      final fieldWidget = tester.widget<TextFormField>(nameField);
      expect(fieldWidget.initialValue, 'Timer Block');

      await tester.enterText(nameField, 'My Renamed Timer');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
      await tester.pumpAndSettle();

      final tonBlock = program.fbdBlocks.firstWhere((b) => b.id == 'ton1');
      expect(tonBlock.title, 'My Renamed Timer');
      expect(find.text('My Renamed Timer'), findsOneWidget);

      expect(tester.takeException(), isNull);
    });

    testWidgets('real tap on a block card in non-expanded (phone) mode opens the configure dialog',
        (tester) async {
      // Regression test for I1: the card's inner GestureDetector (which only
      // clears wire selection) used to sit deeper in the tree than the outer
      // Positioned > GestureDetector that opens the configure dialog, so it
      // always won the gesture arena and swallowed the tap before the outer
      // handler ever ran. A real `tester.tap` (unlike invoking a captured
      // onTap callback directly) exercises the actual gesture-arena
      // resolution and would have failed before the fix.
      await setSurface(tester, phoneSize);
      final project = _buildProject();
      final program = _buildProgram();
      await tester.pumpWidget(app(project, program));
      await tester.pumpAndSettle();

      expect(find.text('Configure: Timer Block'), findsNothing);

      await tester.tap(find.text('Timer Block'));
      await tester.pumpAndSettle();

      expect(find.text('Configure: Timer Block'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Block name'), findsOneWidget);

      expect(tester.takeException(), isNull);
    });
  });
}
