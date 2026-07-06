# Undo / Redo (WS15) — Design Spec

**Date:** 2026-07-06
**Status:** Approved by delegation (user: "start undo/redo"). Design made
autonomously; the design choices are called out below so they can be vetoed.
**Author:** Claude (pairing with Jarrod)

Adds project-wide **undo/redo** to the editors. Because the app already has
lossless `PlcProject` serialization (WS6) and a single mutation funnel in the
workspace shell, this is done with a **snapshot history** rather than per-action
command objects — dramatically simpler, uniform across every editor, and
low-risk.

## Approach: snapshot history (not command pattern)

Every editor (LD, FBD, SFC, ST, Memory/tags, Simulated I/O, HMI builder) mutates
`_activeProject` in place and calls back into the shell's single funnel
`_markDirtyAndAutosave` → debounced `_runAutosave`. We hang undo/redo off that
same funnel:

- A `ProjectHistory` holds JSON **snapshots** of committed project states (an
  undo stack and a redo stack) plus a `baseline` = the last committed snapshot.
- On the debounced autosave tick, the shell serializes the project once
  (`jsonEncode(project.toJson())`) and `capture(...)`s it: if it differs from the
  baseline, the old baseline is pushed onto the undo stack, the redo stack is
  cleared, and the baseline becomes the new snapshot.
- **Undo** restores the previous snapshot (moving the current one to redo);
  **redo** re-applies it. Restoring = `PlcProject.fromJson` + swap into
  `_activeProject`/`_allProjects` + clear runtimes + persist.

Why snapshots win here: the WS6 serialization is already proven lossless and
round-trip-exact (the scan-equivalence guard), projects are tiny (KB-scale JSON),
and it needs **zero** per-editor plumbing — a command approach would require
refactoring every mutating action in seven editors into do/undo pairs (large
surface, easy to miss actions, high risk).

### Design choices (conventional defaults — vetoable)
- **Coalesced granularity:** history captures on the autosave debounce
  (~800 ms quiet window), so a continuous drag or a burst of quick edits becomes
  **one** undo step, and discrete actions separated by a pause become separate
  steps. Predictable and matches most drawing tools.
- **Scope = within-project edits.** Undo/redo operates on the active project's
  content. It does **not** undo project create/duplicate/delete/rename/reset —
  those reset the history (a different axis).
- **Depth cap 50** snapshots (oldest dropped) — bounded memory.
- **In-memory only** — history does not persist across app restarts (standard).
- **Shortcuts:** Ctrl+Z = undo, Ctrl+Y and Ctrl+Shift+Z = redo (plus ⌘ on
  macOS), and toolbar buttons. A focused text field keeps its own native text
  undo (it consumes Ctrl+Z first) — acceptable.

## The history unit (pure, testable)

`mobile/lib/models/project_history.dart` — pure Dart, no Flutter:
```
class ProjectHistory {
  ProjectHistory({int maxDepth = 50});
  void reset(String snapshot);      // on project load/switch: baseline, clear stacks
  void capture(String current);     // commit if != baseline; clears redo; caps depth
  bool get canUndo;                 // undo stack non-empty
  bool get canRedo;                 // redo stack non-empty
  String? undo();                   // -> snapshot to restore, or null
  String? redo();                   // -> snapshot to restore, or null
}
```
`capture` compares strings, so identical (no-op) rebuilds don't create history
entries. `undo`/`redo` move the baseline between the stacks and return the
snapshot to load (null when the respective stack is empty).

## Shell integration (`workspace_shell.dart`)

- Add `final ProjectHistory _history = ProjectHistory();` and an
  `int _editorRevision = 0;`.
- **Seed/reset:** in boot (after `_activeProject` is set) and in
  `_switchActiveProject` (and the create/duplicate/delete/reset/import paths),
  call `_history.reset(jsonEncode(_activeProject.toJson()))` and bump
  `_editorRevision`.
- **Capture:** at the top of `_runAutosave` (before the `repo == null` early
  return, so it works even when storage is unavailable) call
  `_history.capture(jsonEncode(_activeProject.toJson()))`. Because `_runAutosave`
  is the debounced target and `_flushPendingAutosave` runs it immediately, this
  coalesces bursts and is flushed before any project switch.
- **Undo/redo methods:** cancel the autosave timer, `capture` the current state
  (so the baseline == current), then `final snap = _history.undo()` (or `redo()`);
  if non-null, `_applySnapshot(snap)`.
- **`_applySnapshot(String json)`:** `PlcProject.fromJson(jsonDecode(json))`, then
  `setState`: replace the matching entry in `_allProjects`, set `_activeProject`,
  bump `_editorRevision`, clear all runtimes (`_simRuntime.byRuleId.clear()`,
  `_ldRuntime/_fbdRuntime/_sfcRuntime/_stRuntime.clear()`) since restored state
  may not reference the same blocks/rules, and keep `_activeViewId` valid (fall
  back to a still-existing view). Then persist (autosave). The restored snapshot
  equals the new baseline, so the persist's capture is a no-op.
- **Editor rebuild:** key the center-workspace subtree with `_editorRevision`
  (e.g. `KeyedSubtree(key: ValueKey('editor-$_editorRevision-$_activeViewId'), ...)`)
  so undo/redo/switch discard stale editor `State` and rebuild from the restored
  project, while ordinary in-place edits (which don't bump the revision) keep the
  editor's live state (selection, scroll, controllers).
- **Toolbar:** add undo and redo `IconButton`s to `_buildAppBarActions`, each
  enabled only when `_history.canUndo` / `canRedo` (disabled = greyed).
- **Shortcuts:** wrap the shell body in `CallbackShortcuts` (Ctrl/⌘+Z → undo,
  Ctrl/⌘+Y and Ctrl/⌘+Shift+Z → redo) with a focused subtree.

## Testing

- **`ProjectHistory` unit tests** (pure): `capture` only records real changes
  (identical string = no-op); undo then redo returns the exact intermediate
  snapshots; a new `capture` after an undo clears the redo stack; `maxDepth` caps
  the undo stack (oldest dropped) while the most recent N remain; `reset` clears
  both stacks and sets the baseline; `canUndo`/`canRedo` reflect the stacks.
- **Shell widget tests:** starting state has undo/redo disabled; after an editor
  edit (mutate a tag/block + fire the callback) and the debounce, undo is
  enabled and pressing it restores the prior project state (a tag value / block
  count reverts); redo re-applies it; a rapid burst of edits within one debounce
  window collapses to a single undo step; switching projects clears the history
  (undo disabled); the editor subtree rebuilds on undo (no stale-state
  exception). `takeException()` null at 360/320/1400.
- **Serialization safety:** undo/redo round-trips through the same
  `toJson`/`fromJson` as WS6, so the existing `serialization_roundtrip_test.dart`
  continues to guard losslessness; no new persisted field is added.
- Full suite green; `flutter analyze` zero; `flutter build web --release`.

## Global constraints

No third-party/reference-editor branding. Dark theme; responsive (WS5). `flutter
analyze` zero. Pure logic (`ProjectHistory`) in `mobile/lib/models` (UI-free);
never throws. Lossless persistence preserved (undo/redo reuses WS6
serialization). No RenderFlex overflow at 360/320/1400. Additive — no change to
editor mutation code; the shell gains history alongside the existing autosave.

## Out of scope (deferred)
- Per-action (fine-grained) undo labels ("Undo move block") — the snapshot model
  is coarse-but-coalesced; naming steps would need command metadata.
- Undoing project-level CRUD (create/delete/rename) and cross-project history.
- Persisting the undo history across app restarts.
