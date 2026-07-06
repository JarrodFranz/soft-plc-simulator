import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_history.dart';

void main() {
  group('ProjectHistory', () {
    test('capture records a change and de-duplicates identical snapshots', () {
      final history = ProjectHistory();
      history.reset('A');
      expect(history.canUndo, isFalse);

      history.capture('B');
      expect(history.canUndo, isTrue);

      // Capturing the same value again must not push a duplicate entry.
      history.capture('B');
      expect(history.undo(), 'A');
      expect(history.canUndo, isFalse);
    });

    test('undo/redo round-trip', () {
      final history = ProjectHistory();
      history.reset('A');
      history.capture('B');
      history.capture('C');

      expect(history.undo(), 'B');
      expect(history.canRedo, isTrue);

      expect(history.undo(), 'A');
      expect(history.canUndo, isFalse);

      expect(history.undo(), isNull);

      expect(history.redo(), 'B');
      expect(history.redo(), 'C');
      expect(history.redo(), isNull);
    });

    test('new capture clears the redo stack', () {
      final history = ProjectHistory();
      history.reset('A');
      history.capture('B');
      history.undo(); // back at A, redo holds B

      history.capture('X');
      expect(history.canRedo, isFalse);
      expect(history.redo(), isNull);
    });

    test('maxDepth caps the undo stack and never throws when exhausted', () {
      final history = ProjectHistory(maxDepth: 3);
      history.reset('s0');
      history.capture('s1');
      history.capture('s2');
      history.capture('s3');
      history.capture('s4');
      history.capture('s5');

      expect(history.canUndo, isTrue);

      // Only the most recent 3 prior states are recoverable; oldest dropped.
      expect(history.undo(), 's4');
      expect(history.undo(), 's3');
      expect(history.undo(), 's2');
      expect(history.canUndo, isFalse);
      expect(history.undo(), isNull);
      expect(history.undo(), isNull);
    });

    test('reset clears both stacks and allows a fresh baseline', () {
      final history = ProjectHistory();
      history.reset('A');
      history.capture('B');
      history.capture('C');
      history.undo();

      expect(history.canUndo, isTrue);
      expect(history.canRedo, isTrue);

      history.reset('Z');
      expect(history.canUndo, isFalse);
      expect(history.canRedo, isFalse);
      expect(history.undo(), isNull);
      expect(history.redo(), isNull);

      history.capture('Y');
      expect(history.canUndo, isTrue);
      expect(history.undo(), 'Z');
    });
  });
}
