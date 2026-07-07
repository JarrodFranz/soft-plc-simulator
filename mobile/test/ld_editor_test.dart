import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/ld_graph.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/ld_editor_screen.dart';
import 'support/responsive_test_utils.dart';

LdNode contact(String v) => LdNode(id: '', kind: LdKind.contact, variable: v);
LdNode coil(String v) => LdNode(id: '', kind: LdKind.coil, variable: v);
LdNode block(String blockType, String v, {int presetMs = 5000, String operandA = ''}) => LdNode(
      id: '',
      kind: LdKind.block,
      blockType: blockType,
      variable: v,
      presetMs: presetMs,
      operandA: operandA,
    );

PlcProject _buildProject(PlcProgram program) {
  return PlcProject(
    id: 'proj_test_ld',
    name: 'Test LD Project',
    controllerName: 'PLC_TEST',
    tags: const [],
    structDefs: const [],
    programs: [program],
    tasks: const [],
    hmis: const [],
  );
}

PlcProgram _twoRungProgram() {
  return PlcProgram(
    name: 'TestProgram',
    language: 'LadderLogic',
    rungs: [
      buildRung(index: 0, comment: 'Rung 0', main: [contact('A'), coil('Q0')]),
      buildRung(index: 1, comment: 'Rung 1', main: [contact('B'), coil('Q1')]),
    ],
  );
}

Widget _app(PlcProgram program) {
  final project = _buildProject(program);
  return MaterialApp(
    home: LdEditorScreen(
      currentProject: project,
      program: program,
      onProgramUpdated: () {},
    ),
  );
}

void main() {
  group('LdEditorScreen rung actions', () {
    for (final size in [desktopSize, smallPhoneSize]) {
      testWidgets('up-arrow disabled on rung 0, down-arrow disabled on last rung (${size.width.toInt()}px)',
          (tester) async {
        await setSurface(tester, size);
        final program = _twoRungProgram();
        await tester.pumpWidget(_app(program));
        await tester.pumpAndSettle();

        final upButtons = find.byIcon(Icons.arrow_upward);
        final downButtons = find.byIcon(Icons.arrow_downward);
        expect(upButtons, findsNWidgets(2));
        expect(downButtons, findsNWidgets(2));

        IconButton iconButtonAt(Finder iconFinder, int index) {
          return tester.widget<IconButton>(
            find.ancestor(of: iconFinder.at(index), matching: find.byType(IconButton)).first,
          );
        }

        // Rung 0's up-arrow is disabled; rung 1 (last)'s down-arrow is disabled.
        expect(iconButtonAt(upButtons, 0).onPressed, isNull);
        expect(iconButtonAt(downButtons, 1).onPressed, isNull);
        // Rung 0's down-arrow and rung 1's up-arrow are enabled.
        expect(iconButtonAt(downButtons, 0).onPressed, isNotNull);
        expect(iconButtonAt(upButtons, 1).onPressed, isNotNull);

        expect(tester.takeException(), isNull);
      });

      testWidgets('tapping down-arrow on rung 0 reorders rungs (${size.width.toInt()}px)', (tester) async {
        await setSurface(tester, size);
        final program = _twoRungProgram();
        await tester.pumpWidget(_app(program));
        await tester.pumpAndSettle();

        expect(find.textContaining('RUNG 0   Rung 0'), findsOneWidget);
        expect(find.textContaining('RUNG 1   Rung 1'), findsOneWidget);

        // At the compact (phone) width the ladder canvas sits inside an
        // InteractiveViewer, so the rung may be panned/scaled out of the
        // visible viewport — invoke the button's callback directly (same
        // production code path as a tap) rather than fighting hit-testing
        // through an arbitrary pan/zoom transform.
        final downButtons = find.byIcon(Icons.arrow_downward);
        final downButton0 = tester.widget<IconButton>(
          find.ancestor(of: downButtons.at(0), matching: find.byType(IconButton)).first,
        );
        downButton0.onPressed!();
        await tester.pumpAndSettle();

        // Order swapped: what was "Rung 1" (index 1) is now index 0.
        expect(find.textContaining('RUNG 0   Rung 1'), findsOneWidget);
        expect(find.textContaining('RUNG 1   Rung 0'), findsOneWidget);
        expect(program.rungs[0].comment, 'Rung 1');
        expect(program.rungs[1].comment, 'Rung 0');

        expect(tester.takeException(), isNull);
      });

      testWidgets('Coil mode shows add-output affordance and tapping it adds a coil (${size.width.toInt()}px)',
          (tester) async {
        await setSurface(tester, size);
        final program = _twoRungProgram();
        await tester.pumpWidget(_app(program));
        await tester.pumpAndSettle();

        final nodesBefore = program.rungs[0].nodes.length;

        await tester.tap(find.text('Coil'));
        await tester.pumpAndSettle();

        // The add-output affordance is a cyan "+" icon. Icons.add is also
        // used by the toolbar's "Add Rung" button (built first in the tree),
        // so the per-rung add-output targets follow it in document order:
        // index 0 = Add Rung, index 1 = rung 0's add-output, index 2 = rung 1's.
        final addTargets = find.byIcon(Icons.add);
        expect(addTargets, findsNWidgets(3));

        // At the compact (phone) width the ladder canvas sits inside an
        // InteractiveViewer, so the affordance may be panned/scaled out of
        // the visible viewport — invoke its GestureDetector.onTap directly
        // (same production code path as a tap) rather than fighting
        // hit-testing through an arbitrary pan/zoom transform.
        final addOutputTarget = tester.widget<GestureDetector>(
          find.ancestor(of: addTargets.at(1), matching: find.byType(GestureDetector)).first,
        );
        addOutputTarget.onTap!();
        await tester.pumpAndSettle();

        expect(program.rungs[0].nodes.length, greaterThan(nodesBefore));
        expect(program.rungs[0].nodes.any((n) => n.kind == LdKind.coil && n.variable == 'Output_Coil'), isTrue);
        // The edit dialog opens after adding.
        expect(find.text('Edit Coil'), findsOneWidget);

        expect(tester.takeException(), isNull);
      });
    }
  });

  group('Counter/timer block edit dialog + rendering', () {
    for (final size in [desktopSize, smallPhoneSize]) {
      testWidgets('CTU block edit dialog shows Preset Count (PV), not Preset Time (${size.width.toInt()}px)',
          (tester) async {
        await setSurface(tester, size);
        final program = PlcProgram(
          name: 'TestProgram',
          language: 'LadderLogic',
          rungs: [
            buildRung(index: 0, comment: 'Rung 0', main: [block('CTU', 'Ctr1', presetMs: 10)]),
          ],
        );
        await tester.pumpWidget(_app(program));
        await tester.pumpAndSettle();

        await tester.tap(find.text('CTU'));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.text('CTU'));
        await tester.pumpAndSettle();

        expect(find.text('Preset Count (PV)'), findsOneWidget);
        expect(find.text('Preset Time (PT) ms'), findsNothing);

        expect(tester.takeException(), isNull);
      });

      testWidgets('CTUD block edit dialog additionally shows a Count-down tag field (${size.width.toInt()}px)',
          (tester) async {
        await setSurface(tester, size);
        final program = PlcProgram(
          name: 'TestProgram',
          language: 'LadderLogic',
          rungs: [
            buildRung(index: 0, comment: 'Rung 0', main: [block('CTUD', 'Ctr2', presetMs: 10)]),
          ],
        );
        await tester.pumpWidget(_app(program));
        await tester.pumpAndSettle();

        await tester.tap(find.text('CTUD'));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.text('CTUD'));
        await tester.pumpAndSettle();

        expect(find.text('Preset Count (PV)'), findsOneWidget);
        expect(find.text('Count-down tag'), findsOneWidget);

        expect(tester.takeException(), isNull);
      });

      testWidgets('CTU block renders CU/QU pins with no overflow (${size.width.toInt()}px)', (tester) async {
        await setSurface(tester, size);
        final program = PlcProgram(
          name: 'TestProgram',
          language: 'LadderLogic',
          rungs: [
            buildRung(index: 0, comment: 'Rung 0', main: [block('CTU', 'Ctr1', presetMs: 10)]),
          ],
        );
        await tester.pumpWidget(_app(program));
        await tester.pumpAndSettle();

        expect(find.text('CTU'), findsOneWidget);
        expect(find.text('CU'), findsOneWidget);
        expect(find.text('QU'), findsOneWidget);

        expect(tester.takeException(), isNull);
      });
    }
  });

  group('Block-type picker + data blocks', () {
    for (final size in [desktopSize, smallPhoneSize]) {
      testWidgets('tapping Block opens a picker listing all four groups and their types (${size.width.toInt()}px)',
          (tester) async {
        await setSurface(tester, size);
        final program = _twoRungProgram();
        await tester.pumpWidget(_app(program));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Block'));
        await tester.pumpAndSettle();

        // Groups.
        expect(find.text('Timers'), findsOneWidget);
        expect(find.text('Counters'), findsOneWidget);
        expect(find.text('Compare'), findsOneWidget);
        expect(find.text('Math'), findsOneWidget);

        // Types.
        for (final t in ['TON', 'TOF', 'TP', 'CTU', 'CTD', 'CTUD', 'GT', 'LT', 'GE', 'LE', 'EQ', 'NE', 'ADD', 'SUB', 'MUL', 'DIV', 'MOVE']) {
          expect(find.text(t), findsOneWidget, reason: 'expected type $t in picker');
        }

        expect(tester.takeException(), isNull);
      });

      testWidgets('picking GT then tapping a wire insert-target inserts a GT block and opens its dialog '
          '(${size.width.toInt()}px)', (tester) async {
        await setSurface(tester, size);
        final program = _twoRungProgram();
        await tester.pumpWidget(_app(program));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Block'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('GT'));
        await tester.pumpAndSettle();

        // Insert targets are the small cyan "+" GestureDetectors on wires.
        final addTargets = find.byIcon(Icons.add);
        // index 0 = Add Rung button; subsequent ones are per-rung wire targets.
        final insertTarget = tester.widget<GestureDetector>(
          find.ancestor(of: addTargets.at(1), matching: find.byType(GestureDetector)).first,
        );
        insertTarget.onTap!();
        await tester.pumpAndSettle();

        final inserted = program.rungs[0].nodes.where((n) => n.kind == LdKind.block && n.blockType == 'GT');
        expect(inserted.length, 1);

        // Its edit dialog opened.
        expect(find.text('Edit GT'), findsOneWidget);

        expect(tester.takeException(), isNull);
      });

      testWidgets('GT edit dialog shows operand A, operator dropdown, operand B, no preset field '
          '(${size.width.toInt()}px)', (tester) async {
        await setSurface(tester, size);
        final program = PlcProgram(
          name: 'TestProgram',
          language: 'LadderLogic',
          rungs: [
            buildRung(index: 0, comment: 'Rung 0', main: [
              LdNode(id: '', kind: LdKind.block, blockType: 'GT', variable: '', operandA: '10', operandB: '20'),
            ]),
          ],
        );
        await tester.pumpWidget(_app(program));
        await tester.pumpAndSettle();

        await tester.tap(find.text('GT'));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.text('GT'));
        await tester.pumpAndSettle();

        expect(find.text('Edit GT'), findsOneWidget);
        expect(find.text('Operand A'), findsOneWidget);
        expect(find.text('Operand B'), findsOneWidget);
        expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
        expect(find.text('Preset Count (PV)'), findsNothing);
        expect(find.text('Preset Time (PT) ms'), findsNothing);

        expect(tester.takeException(), isNull);
      });

      testWidgets('Math ADD edit dialog shows output-tag + A + operator + B (${size.width.toInt()}px)',
          (tester) async {
        await setSurface(tester, size);
        final program = PlcProgram(
          name: 'TestProgram',
          language: 'LadderLogic',
          rungs: [
            buildRung(index: 0, comment: 'Rung 0', main: [
              LdNode(id: '', kind: LdKind.block, blockType: 'ADD', variable: 'Result', operandA: '1', operandB: '2'),
            ]),
          ],
        );
        await tester.pumpWidget(_app(program));
        await tester.pumpAndSettle();

        await tester.tap(find.text('ADD'));
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.text('ADD'));
        await tester.pumpAndSettle();

        expect(find.text('Edit ADD'), findsOneWidget);
        expect(find.text('Output tag'), findsOneWidget);
        expect(find.text('Operand A'), findsOneWidget);
        expect(find.text('Operand B'), findsOneWidget);
        expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);

        expect(tester.takeException(), isNull);
      });

      testWidgets('GT block renders A, >, B without overflow (${size.width.toInt()}px)', (tester) async {
        await setSurface(tester, size);
        final program = PlcProgram(
          name: 'TestProgram',
          language: 'LadderLogic',
          rungs: [
            buildRung(index: 0, comment: 'Rung 0', main: [
              LdNode(id: '', kind: LdKind.block, blockType: 'GT', variable: '', operandA: 'Speed', operandB: '100'),
            ]),
          ],
        );
        await tester.pumpWidget(_app(program));
        await tester.pumpAndSettle();

        expect(find.text('GT'), findsOneWidget);
        expect(find.text('Speed'), findsOneWidget);
        expect(find.text('>'), findsOneWidget);
        expect(find.text('100'), findsOneWidget);

        expect(tester.takeException(), isNull);
      });

      testWidgets('Math block face shows its output tag with no overflow (${size.width.toInt()}px)', (tester) async {
        await setSurface(tester, size);
        final program = PlcProgram(
          name: 'TestProgram',
          language: 'LadderLogic',
          rungs: [
            buildRung(index: 0, comment: 'Rung 0', main: [
              LdNode(id: '', kind: LdKind.block, blockType: 'ADD', variable: 'Total', operandA: 'A', operandB: 'B'),
            ]),
          ],
        );
        await tester.pumpWidget(_app(program));
        await tester.pumpAndSettle();

        // Parity with timer/counter blocks: the result destination must be
        // visible on the block face, not only in the edit dialog.
        expect(find.textContaining('Total'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('Guided branch mode (junction-anchor picking)', () {
    // Junction dots render an Icon.circle (unpicked) or Icon.check (the
    // picked start), always in main-line (left-to-right) wire order — so
    // indexing into this combined finder is stable across a pick.
    Finder junctionDots() =>
        find.byWidgetPredicate((w) => w is Icon && (w.icon == Icons.circle || w.icon == Icons.check));

    Future<void> tapDot(WidgetTester tester, int index) async {
      final dot = junctionDots().at(index);
      final gd = tester.widget<GestureDetector>(
        find.ancestor(of: dot, matching: find.byType(GestureDetector)).first,
      );
      gd.onTap?.call();
      await tester.pump();
    }

    PlcProgram threeElementProgram() => PlcProgram(
          name: 'TestProgram',
          language: 'LadderLogic',
          rungs: [
            buildRung(index: 0, comment: 'Rung 0', main: [contact('A'), contact('B'), coil('Q0')]),
          ],
        );

    for (final size in [desktopSize, smallPhoneSize]) {
      testWidgets('Branch mode shows N+1 junction dots for N main elements (${size.width.toInt()}px)',
          (tester) async {
        await setSurface(tester, size);
        final program = threeElementProgram(); // N = 3 main elements
        await tester.pumpWidget(_app(program));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Branch'));
        await tester.pumpAndSettle();

        expect(junctionDots(), findsNWidgets(4)); // N + 1 = 4 lane-0 wires
        expect(find.text('Tap a start point'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('start dot then a valid end dot to its right creates a link branch (${size.width.toInt()}px)',
          (tester) async {
        await setSurface(tester, size);
        final program = threeElementProgram();
        await tester.pumpWidget(_app(program));
        await tester.pumpAndSettle();
        final rung = program.rungs[0];

        await tester.tap(find.text('Branch'));
        await tester.pumpAndSettle();
        final branchesBefore = findBranches(rung).length;

        // Pick the first junction (L -> A) as the start.
        await tapDot(tester, 0);
        await tester.pumpAndSettle();
        expect(find.text('Tap an end point (tap the start again to cancel)'), findsOneWidget);

        // Pick the third junction (B -> Q0) as the end (strictly to the right).
        await tapDot(tester, 2);
        await tester.pumpAndSettle();

        expect(findBranches(rung).length, branchesBefore + 1);
        final newLane = findBranches(rung)
            .map((br) => br.lane)
            .reduce((a, b) => a > b ? a : b);
        final linkNode = rung.nodes.firstWhere((n) => n.row == newLane);
        expect(linkNode.kind, LdKind.link);

        final inWire = rung.wires.firstWhere((w) => w.toId == linkNode.id);
        final outWire = rung.wires.firstWhere((w) => w.fromId == linkNode.id);
        expect(inWire.fromId, kLeftRailId);
        final coilNode = rung.nodes.firstWhere((n) => n.variable == 'Q0');
        expect(outWire.toId, coilNode.id);

        // Guided pick is a one-shot flow: it resets to select mode afterward.
        expect(find.text('Tap a start point'), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('tapping the start dot again cancels the pick, no branch created (${size.width.toInt()}px)',
          (tester) async {
        await setSurface(tester, size);
        final program = threeElementProgram();
        await tester.pumpWidget(_app(program));
        await tester.pumpAndSettle();
        final rung = program.rungs[0];

        await tester.tap(find.text('Branch'));
        await tester.pumpAndSettle();
        final branchesBefore = findBranches(rung).length;

        await tapDot(tester, 1);
        await tester.pumpAndSettle();
        expect(find.text('Tap an end point (tap the start again to cancel)'), findsOneWidget);

        // Tap the very same (now-highlighted) start dot again to cancel.
        await tapDot(tester, 1);
        await tester.pumpAndSettle();

        expect(find.text('Tap a start point'), findsOneWidget);
        expect(findBranches(rung).length, branchesBefore);
        expect(tester.takeException(), isNull);
      });

      testWidgets('a right-rail end junction produces a branch merging at the right rail (${size.width.toInt()}px)',
          (tester) async {
        await setSurface(tester, size);
        final program = _twoRungProgram(); // rung 0: main = [contact('A'), coil('Q0')]
        await tester.pumpWidget(_app(program));
        await tester.pumpAndSettle();
        final rung = program.rungs[0];

        await tester.tap(find.text('Branch'));
        await tester.pumpAndSettle();

        // Dots: 0 = L->A, 1 = A->Q0, 2 = Q0->R. Pick the last (right-rail) as end.
        await tapDot(tester, 0);
        await tester.pumpAndSettle();
        await tapDot(tester, 2);
        await tester.pumpAndSettle();

        final newLane = findBranches(rung)
            .map((br) => br.lane)
            .reduce((a, b) => a > b ? a : b);
        final linkNode = rung.nodes.firstWhere((n) => n.row == newLane);
        expect(linkNode.kind, LdKind.link);
        final outWire = rung.wires.firstWhere((w) => w.fromId == linkNode.id);
        expect(outWire.toId, kRightRailId);

        expect(tester.takeException(), isNull);
      });
    }
  });

  group('Empty-branch link rendering + fill/delete (WS22 Task 3)', () {
    // The link slot is identified by a distinct Key regardless of viewport —
    // Icons.add alone is ambiguous (also used by Add Rung / wire-insert /
    // add-output affordances).
    Finder linkSlot() => find.byKey(const Key('ld_link_slot'));

    GestureDetector nodeGestureDetector(WidgetTester tester, Finder target) {
      return tester.widget<GestureDetector>(
        find.ancestor(of: target, matching: find.byType(GestureDetector)).first,
      );
    }

    for (final size in [desktopSize, smallPhoneSize]) {
      testWidgets('a link renders a ghosted + slot with no overflow (${size.width.toInt()}px)', (tester) async {
        await setSurface(tester, size);
        final program = _twoRungProgram();
        final rung = program.rungs[0];
        final coilQ0 = rung.nodes.firstWhere((n) => n.variable == 'Q0');
        addEmptyBranch(rung, kLeftRailId, coilQ0.id);

        await tester.pumpWidget(_app(program));
        await tester.pumpAndSettle();

        expect(linkSlot(), findsOneWidget);
        expect(find.byIcon(Icons.add), findsWidgets); // includes the link's + affordance
        expect(tester.takeException(), isNull);
      });

      testWidgets('Contact mode tapping a link REPLACES it with a contact (${size.width.toInt()}px)',
          (tester) async {
        await setSurface(tester, size);
        final program = _twoRungProgram();
        final rung = program.rungs[0];
        final coilQ0 = rung.nodes.firstWhere((n) => n.variable == 'Q0');
        final link = addEmptyBranch(rung, kLeftRailId, coilQ0.id);

        await tester.pumpWidget(_app(program));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Contact'));
        await tester.pumpAndSettle();

        final slot = linkSlot();
        expect(slot, findsOneWidget);
        nodeGestureDetector(tester, slot).onTap!();
        await tester.pumpAndSettle();

        // No LdKind.link remains on that lane; the id was reused by a contact.
        expect(rung.nodes.where((n) => n.row == link.row && n.kind == LdKind.link), isEmpty);
        final filled = rung.nodes.firstWhere((n) => n.id == link.id);
        expect(filled.kind, LdKind.contact);
        expect(find.text('Edit Contact'), findsOneWidget);

        expect(tester.takeException(), isNull);
      });

      testWidgets('Coil mode tapping a right-rail-merged link fills it with a coil (${size.width.toInt()}px)',
          (tester) async {
        await setSurface(tester, size);
        final program = _twoRungProgram();
        final rung = program.rungs[0];
        final contactA = rung.nodes.firstWhere((n) => n.variable == 'A');
        final link = addEmptyBranch(rung, contactA.id, kRightRailId);

        await tester.pumpWidget(_app(program));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Coil'));
        await tester.pumpAndSettle();

        final slot = linkSlot();
        expect(slot, findsOneWidget);
        nodeGestureDetector(tester, slot).onTap!();
        await tester.pumpAndSettle();

        final filled = rung.nodes.firstWhere((n) => n.id == link.id);
        expect(filled.kind, LdKind.coil);
        expect(find.text('Edit Coil'), findsOneWidget);

        expect(tester.takeException(), isNull);
      });

      testWidgets('Block mode (pending TON) tapping a link fills it with a block (${size.width.toInt()}px)',
          (tester) async {
        await setSurface(tester, size);
        final program = _twoRungProgram();
        final rung = program.rungs[0];
        final coilQ0 = rung.nodes.firstWhere((n) => n.variable == 'Q0');
        final link = addEmptyBranch(rung, kLeftRailId, coilQ0.id);

        await tester.pumpWidget(_app(program));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Block'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('TON'));
        await tester.pumpAndSettle();

        final slot = linkSlot();
        expect(slot, findsOneWidget);
        nodeGestureDetector(tester, slot).onTap!();
        await tester.pumpAndSettle();

        final filled = rung.nodes.firstWhere((n) => n.id == link.id);
        expect(filled.kind, LdKind.block);
        expect(filled.blockType, 'TON');
        expect(find.text('Edit TON'), findsOneWidget);

        expect(tester.takeException(), isNull);
      });

      testWidgets('deleting the sole element of a branch reverts it to a link (${size.width.toInt()}px)',
          (tester) async {
        await setSurface(tester, size);
        final program = _twoRungProgram();
        final rung = program.rungs[0];
        final contactA = rung.nodes.firstWhere((n) => n.variable == 'A');
        final coilQ0 = rung.nodes.firstWhere((n) => n.variable == 'Q0');
        final br = addParallelBranch(rung, contactA, coilQ0);
        final branchesBefore = findBranches(rung).length;

        await tester.pumpWidget(_app(program));
        await tester.pumpAndSettle();

        final nodeText = find.text('New_Contact');
        expect(nodeText, findsOneWidget);
        nodeGestureDetector(tester, nodeText).onDoubleTap!();
        await tester.pumpAndSettle();
        expect(find.text('Delete'), findsOneWidget);
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();

        // The branch lane persists (reverted to a link), not removed.
        expect(findBranches(rung).length, branchesBefore);
        final reverted = rung.nodes.firstWhere((n) => n.id == br.firstNodeId);
        expect(reverted.kind, LdKind.link);

        expect(tester.takeException(), isNull);
      });

      testWidgets('deleting a link removes the branch (${size.width.toInt()}px)', (tester) async {
        await setSurface(tester, size);
        final program = _twoRungProgram();
        final rung = program.rungs[0];
        final coilQ0 = rung.nodes.firstWhere((n) => n.variable == 'Q0');
        addEmptyBranch(rung, kLeftRailId, coilQ0.id);
        final branchesBefore = findBranches(rung).length;

        await tester.pumpWidget(_app(program));
        await tester.pumpAndSettle();

        final slot = linkSlot();
        expect(slot, findsOneWidget);
        nodeGestureDetector(tester, slot).onDoubleTap!();
        await tester.pumpAndSettle();
        expect(find.text('Delete'), findsOneWidget);
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();

        expect(findBranches(rung).length, branchesBefore - 1);

        expect(tester.takeException(), isNull);
      });

      testWidgets(
          'link edit dialog is delete/cancel-only, no dead Apply (${size.width.toInt()}px)',
          (tester) async {
        await setSurface(tester, size);
        final program = _twoRungProgram();
        final rung = program.rungs[0];
        final coilQ0 = rung.nodes.firstWhere((n) => n.variable == 'Q0');
        addEmptyBranch(rung, kLeftRailId, coilQ0.id);
        final branchesBefore = findBranches(rung).length;

        await tester.pumpWidget(_app(program));
        await tester.pumpAndSettle();

        final slot = linkSlot();
        expect(slot, findsOneWidget);
        nodeGestureDetector(tester, slot).onDoubleTap!();
        await tester.pumpAndSettle();

        // An empty-branch placeholder has no logical content to edit — the
        // dialog must not offer the generic contact-editing UI (Tag field,
        // modifier dropdown, Apply button), only Delete/Cancel.
        expect(find.text('Apply'), findsNothing);
        expect(find.text('Tag / literal'), findsNothing);
        expect(find.text('Delete'), findsOneWidget);
        expect(find.text('Cancel'), findsOneWidget);

        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();

        expect(findBranches(rung).length, branchesBefore - 1);
        expect(rung.nodes.any((n) => n.kind == LdKind.link), isFalse);

        expect(tester.takeException(), isNull);
      });
    }
  });
}
