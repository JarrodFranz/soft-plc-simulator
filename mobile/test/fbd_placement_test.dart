import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/fbd_layout.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/screens/fbd_editor_screen.dart';

import 'support/responsive_test_utils.dart';

/// QA #14 — a block added from the palette always landed on the same fixed
/// anchor, so every add after the first dropped on top of an existing block.
/// `findFreeFbdBlockSlot` scans outward from the anchor for a slot whose bounds
/// clear every block already in that network.

FbdBlock _b(String id, String type, {double x = 0, double y = 0, int network = 0, int inputCount = 2}) =>
    FbdBlock(id: id, type: type, title: id, x: x, y: y, network: network, inputCount: inputCount);

PlcProject _project({List<FbDefinition>? fbs}) => PlcProject(
      id: 'p',
      name: 'P',
      controllerName: 'C',
      tags: [PlcTag(name: 'Motor_Run', path: 'Motor_Run', dataType: 'BOOL', value: false, ioType: 'Internal')],
      structDefs: [],
      programs: [],
      tasks: [],
      hmis: [],
      fbDefinitions: fbs ?? [],
    );

PlcProgram _prog(List<FbdBlock> blocks) => PlcProgram(
      name: 'F',
      language: 'FunctionBlockDiagram',
      fbdBlocks: blocks,
    );

/// True when the two blocks' rendered rectangles overlap at all.
bool _overlaps(PlcProject p, FbdBlock a, FbdBlock b) =>
    a.x < b.x + kFbdBlockWidth &&
    b.x < a.x + kFbdBlockWidth &&
    a.y < b.y + fbdBlockHeightFor(p, b) &&
    b.y < a.y + fbdBlockHeightFor(p, a);

void main() {
  group('findFreeFbdBlockSlot', () {
    test('an empty network places the block on the default anchor', () {
      final proj = _project();
      final prog = _prog([]);
      final slot = findFreeFbdBlockSlot(proj, prog, _b('new', 'AND'));
      expect(slot.x, kFbdDefaultBlockX);
      expect(slot.y, kFbdDefaultBlockY);
    });

    test('a block already on the anchor pushes the new one to a clear slot', () {
      final proj = _project();
      final existing = _b('a', 'AND', x: kFbdDefaultBlockX, y: kFbdDefaultBlockY);
      final prog = _prog([existing]);
      final candidate = _b('new', 'AND');

      final slot = findFreeFbdBlockSlot(proj, prog, candidate);
      expect(slot.x == kFbdDefaultBlockX && slot.y == kFbdDefaultBlockY, isFalse);

      candidate
        ..x = slot.x
        ..y = slot.y;
      expect(_overlaps(proj, candidate, existing), isFalse);
    });

    test('the slot clears EVERY block in the network, not just the first', () {
      final proj = _project();
      final existing = [
        _b('a', 'AND', x: 150, y: 150),
        _b('b', 'OR', x: 350, y: 150),
        _b('c', 'ADD', x: 550, y: 150),
        _b('d', 'NOT', x: 150, y: 330),
        _b('e', 'NOT', x: 350, y: 330),
      ];
      final prog = _prog(existing);
      final candidate = _b('new', 'AND');

      final slot = findFreeFbdBlockSlot(proj, prog, candidate);
      candidate
        ..x = slot.x
        ..y = slot.y;
      for (final other in existing) {
        expect(_overlaps(proj, candidate, other), isFalse, reason: 'overlaps ${other.id}');
      }
    });

    test('placement lands on the grid step', () {
      final proj = _project();
      final prog = _prog([_b('a', 'AND', x: 150, y: 150)]);
      final slot = findFreeFbdBlockSlot(proj, prog, _b('new', 'AND'));
      expect((slot.x - kFbdDefaultBlockX) % kFbdGridStep, 0);
      expect((slot.y - kFbdDefaultBlockY) % kFbdGridStep, 0);
    });

    test('blocks in OTHER networks are ignored', () {
      final proj = _project();
      // The anchor is occupied, but only in network 1.
      final prog = _prog([_b('a', 'AND', x: kFbdDefaultBlockX, y: kFbdDefaultBlockY, network: 1)]);
      final slot = findFreeFbdBlockSlot(proj, prog, _b('new', 'AND'));
      expect(slot.x, kFbdDefaultBlockX);
      expect(slot.y, kFbdDefaultBlockY);
    });

    test('taller blocks (more pins) are cleared by their real height', () {
      final proj = _project();
      final tall = _b('a', 'AND', x: 150, y: 150, inputCount: 8);
      final prog = _prog([tall]);
      final candidate = _b('new', 'AND');

      final slot = findFreeFbdBlockSlot(proj, prog, candidate,
          // Force the scan down a single column so only height can resolve it.
          maxColumns: 0);
      candidate
        ..x = slot.x
        ..y = slot.y;
      expect(_overlaps(proj, candidate, tall), isFalse);
      expect(slot.y, greaterThanOrEqualTo(150 + fbdBlockHeightFor(proj, tall)));
    });

    test('a saturated scan falls back to a stacking offset instead of throwing', () {
      final proj = _project();
      final existing = _b('a', 'AND', x: kFbdDefaultBlockX, y: kFbdDefaultBlockY);
      final prog = _prog([existing]);
      // No room to scan at all.
      final slot = findFreeFbdBlockSlot(proj, prog, _b('new', 'AND'),
          maxColumns: 0, maxRows: 0);
      expect(slot.x, isNot(kFbdDefaultBlockX));
      expect(slot.y, isNot(kFbdDefaultBlockY));
    });

    test('a non-positive grid step is guarded (falls back to the default step)', () {
      final proj = _project();
      final prog = _prog([_b('a', 'AND', x: kFbdDefaultBlockX, y: kFbdDefaultBlockY)]);
      final slot = findFreeFbdBlockSlot(proj, prog, _b('new', 'AND'), gridStep: 0);
      expect(slot.x == kFbdDefaultBlockX && slot.y == kFbdDefaultBlockY, isFalse);
    });

    test('a custom function block is measured by its own var count', () {
      final fb = FbDefinition(
        name: 'MyFB',
        vars: [
          FbVar(name: 'A', dataType: 'BOOL', direction: FbVarDir.input),
          FbVar(name: 'B', dataType: 'BOOL', direction: FbVarDir.input),
          FbVar(name: 'C', dataType: 'BOOL', direction: FbVarDir.input),
          FbVar(name: 'D', dataType: 'BOOL', direction: FbVarDir.input),
          FbVar(name: 'Q', dataType: 'BOOL', direction: FbVarDir.output),
        ],
      );
      final proj = _project(fbs: [fb]);
      final instance = _b('a', 'MyFB', x: 150, y: 150);
      // 4 pin rows, not the built-in registry's fallback of 1.
      expect(fbdBlockHeightFor(proj, instance),
          greaterThan(fbdBlockHeightFor(proj, _b('x', 'NOT'))));

      final prog = _prog([instance]);
      final candidate = _b('new', 'AND');
      final slot = findFreeFbdBlockSlot(proj, prog, candidate, maxColumns: 0);
      candidate
        ..x = slot.x
        ..y = slot.y;
      expect(_overlaps(proj, candidate, instance), isFalse);
    });
  });

  group('palette add', () {
    testWidgets('a block added from the palette does not land on an existing block',
        (tester) async {
      await setSurface(tester, desktopSize);
      final proj = _project();
      final existing = _b('a', 'AND', x: kFbdDefaultBlockX, y: kFbdDefaultBlockY);
      final prog = _prog([existing]);
      proj.programs.add(prog);

      await tester.pumpWidget(MaterialApp(
        home: FbdEditorScreen(
          currentProject: proj,
          program: prog,
          onProgramUpdated: () {},
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('fbd_net_addblock_0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.add).last);
      await tester.pumpAndSettle();

      expect(prog.fbdBlocks.length, 2);
      final added = prog.fbdBlocks.last;
      expect(_overlaps(proj, added, existing), isFalse,
          reason: 'a palette add must not drop on top of an existing block');
      expect(tester.takeException(), isNull);
    });
  });
}
