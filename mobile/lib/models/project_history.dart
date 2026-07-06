/// Pure, Flutter-free undo/redo history for a project's serialized JSON
/// snapshots.
///
/// Holds a current `baseline` snapshot plus two stacks of prior snapshots:
/// one for undo (older states) and one for redo (states undone away from).
/// Callers are expected to serialize their project state to a `String`
/// (e.g. via `PlcProject.toJson`) and hand it to [capture]; this class does
/// not interpret the snapshot contents in any way, it only compares them for
/// equality to avoid recording no-op changes.
///
/// All operations are guarded against empty stacks / an unset baseline and
/// never throw.
class ProjectHistory {
  ProjectHistory({this.maxDepth = 50});

  /// Maximum number of undoable snapshots retained. When exceeded, the
  /// oldest entry is dropped.
  final int maxDepth;

  final List<String> _undo = [];
  final List<String> _redo = [];
  String? _baseline;

  /// Whether there is a prior snapshot to [undo] to.
  bool get canUndo => _undo.isNotEmpty;

  /// Whether there is a snapshot to [redo] to.
  bool get canRedo => _redo.isNotEmpty;

  /// Sets [snapshot] as the new baseline and clears both the undo and redo
  /// stacks. Use this when loading/replacing a project outright.
  void reset(String snapshot) {
    _baseline = snapshot;
    _undo.clear();
    _redo.clear();
  }

  /// Records [current] as the new baseline if it differs from the existing
  /// one.
  ///
  /// If there is no baseline yet, [current] simply becomes the baseline. If
  /// [current] is identical to the existing baseline, this is a no-op (no
  /// duplicate entry is recorded). Otherwise the old baseline is pushed onto
  /// the undo stack (dropping the oldest entry if [maxDepth] is exceeded),
  /// the redo stack is cleared, and [current] becomes the new baseline.
  void capture(String current) {
    final baseline = _baseline;
    if (baseline == null) {
      _baseline = current;
      return;
    }
    if (current == baseline) {
      return;
    }
    _undo.add(baseline);
    if (_undo.length > maxDepth) {
      _undo.removeAt(0);
    }
    _redo.clear();
    _baseline = current;
  }

  /// Moves one step back in history, returning the new baseline snapshot,
  /// or `null` if there is nothing to undo.
  String? undo() {
    if (_undo.isEmpty) {
      return null;
    }
    _redo.add(_baseline!);
    _baseline = _undo.removeLast();
    return _baseline;
  }

  /// Moves one step forward in history, returning the new baseline
  /// snapshot, or `null` if there is nothing to redo.
  String? redo() {
    if (_redo.isEmpty) {
      return null;
    }
    _undo.add(_baseline!);
    _baseline = _redo.removeLast();
    return _baseline;
  }
}
