/// App-wide DELETE-CONFIRMATION POLICY (QA §3.1).
///
/// Before this policy, delete affordances were split arbitrarily: struct
/// (DUT), folder, LD-rung, FBD-network and project deletes all raised a
/// blocking "…this cannot be undone" dialog, while tag, FB-var, FBD-block,
/// FBD-wire, HMI-component, SFC-step/transition, sim-rule, trend-pen,
/// protocol-map-row, task and program deletes fired instantly with no
/// feedback at all. Nothing about the *risk* of the action explained which
/// group a delete landed in.
///
/// Now that the shell's undo history actually restores state, the single
/// question that decides the treatment is **"can undo bring it back?"**:
///
/// * **Undoable** — the delete mutates `PlcProject` state (anything
///   `PlcProject.toJson()` serializes) and reports it through the screen's
///   project-changed callback, so the shell's JSON-snapshot history can
///   restore it. These get **no blocking dialog**. They complete immediately
///   and show [showDeleteUndoSnackBar]: a non-modal "Deleted <thing>"
///   SnackBar with an **UNDO** action wired to the shell's undo via
///   [UndoScope]. Cheap to trigger, cheap to reverse.
/// * **Not undoable** — the delete reaches outside the active project (the
///   project catalog itself, the logger's ring buffer, a full
///   reset-to-defaults) so no history snapshot can bring it back. These keep
///   (or gain) an explicit blocking confirmation dialog stating that the
///   action cannot be undone.
///
/// A third, deliberately-untouched group: removals staged **inside an open
/// dialog** (a struct field in the DUT editor, a condition clause in the sim
/// rule editor, a pen checkbox in the HMI chart editor). Those are not
/// committed until the dialog's Save button, so the dialog's own Cancel is
/// already the undo. They get neither a confirmation nor a SnackBar.
///
/// When adding a new delete affordance, classify it with the question above
/// and use [showDeleteUndoSnackBar] or a confirmation dialog accordingly.
library;

import 'package:flutter/material.dart';

import 'responsive.dart';

/// Exposes the shell's undo entry point to any descendant, so a delete
/// performed deep inside an editor can offer "UNDO" without every screen
/// having to thread an extra callback through its constructor.
///
/// [WorkspaceShell] installs exactly one of these above the whole scaffold.
/// Absent an ancestor (e.g. a screen pumped standalone in a widget test) the
/// SnackBar still shows, just without the action button.
class UndoScope extends InheritedWidget {
  const UndoScope({
    super.key,
    required this.onUndo,
    required super.child,
  });

  /// Invoked when the user taps UNDO on a delete SnackBar. Wired to the
  /// shell's `_undo`, i.e. exactly what Ctrl+Z / the toolbar button do.
  final VoidCallback onUndo;

  static UndoScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UndoScope>();

  @override
  bool updateShouldNotify(UndoScope oldWidget) => onUndo != oldWidget.onUndo;
}

/// Key on the SnackBar's UNDO action, for tests.
const Key kDeleteUndoActionKey = Key('delete_undo_action');

/// Confirms an *undoable* delete after the fact: a non-modal SnackBar reading
/// "Deleted <[what]>" with an UNDO action that calls the shell's undo.
///
/// [what] should name the thing in lower case, including its identity where
/// one exists — e.g. `'tag "Pump_Run"'`, `'FBD block ADD_1'`,
/// `'folder "ramp1" (12 tags)'`.
///
/// Call this AFTER the delete has been applied and the project-changed
/// callback has fired.
void showDeleteUndoSnackBar(BuildContext context, String what) {
  final scope = UndoScope.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  // Only ever one delete SnackBar at a time — a stale one still queued would
  // undo the wrong edit if tapped later.
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text('Deleted $what'),
      duration: const Duration(seconds: 5),
      action: scope == null
          ? null
          : SnackBarAction(
              key: kDeleteUndoActionKey,
              label: 'UNDO',
              onPressed: () {
                messenger.hideCurrentSnackBar();
                scope.onUndo();
              },
            ),
    ),
  );
}

/// Blocking confirmation for a delete that the undo history CANNOT reverse.
///
/// Returns true only if the user explicitly confirms. [message] should say
/// plainly that the action cannot be undone.
Future<bool> confirmUnrecoverableDelete(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Delete',
}) async {
  final result = await showAdaptiveWidthDialog<bool>(
    context,
    child: AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}
