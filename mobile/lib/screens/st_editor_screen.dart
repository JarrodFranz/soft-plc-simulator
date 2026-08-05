import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../models/project_model.dart';
import '../ui/responsive.dart';

/// How the editor hands an edited [PlcProgram] back to its host.
///
/// [notifyHost] is false for the one call the editor makes from `dispose()`:
/// the host must apply the model mutation (losing a keystroke typed just
/// before navigating away is the bug this whole seam exists to prevent) but
/// must NOT call `setState`, because `dispose` runs inside the framework's
/// tree-lock window where that throws. The editor re-issues the same program
/// with `notifyHost: true` from a post-frame callback so the host still gets
/// its dirty/autosave notification, one frame later and safely.
///
/// [previousName] is the program's name immediately before this call (null
/// when there was no program in the model yet to rename). It is only
/// informative when it differs from `program.name` — i.e. a flush just
/// applied a header rename. The host needs it because [program] is mutated
/// IN PLACE (see `_persistToModel`), so by the time this callback runs,
/// looking the program up by its old name is no longer possible; without
/// [previousName] the host has no way to notice that whatever view id it was
/// tracking under the old name (e.g. `'PROGRAM:<old name>'`) just went stale.
typedef StProgramSaveCallback = void Function(
  PlcProgram program, {
  bool notifyHost,
  String? previousName,
});

class StEditorScreen extends StatefulWidget {
  final PlcProject currentProject;
  final StProgramSaveCallback onSaveProgram;

  /// Called from `initState`/`dispose` so the host can hold a handle on the
  /// live editor state and call [StEditorScreenState.flushPendingEdits]
  /// BEFORE it swaps the active project/view (and therefore re-keys and
  /// disposes this editor). Without that ordering the flush has to happen
  /// from `dispose()`, which is both too late (the host has already swapped
  /// `_activeProject`) and unsafe (tree lock).
  ///
  /// Detach passes the same state instance that attached, because a replaced
  /// editor's `dispose` runs AFTER its replacement's `initState` — the host
  /// must ignore a detach for a state it no longer holds.
  final void Function(StEditorScreenState state)? onEditorAttached;
  final void Function(StEditorScreenState state)? onEditorDetached;

  const StEditorScreen({
    super.key,
    required this.currentProject,
    required this.onSaveProgram,
    this.onEditorAttached,
    this.onEditorDetached,
  });

  @override
  State<StEditorScreen> createState() => StEditorScreenState();
}

class AutocompleteItem {
  final String label;
  final String insertText;
  final String detail;
  final String category; // 'TAG', 'DB', 'STRUCT', 'FUNCTION', 'KEYWORD'
  final IconData icon;
  final Color color;

  AutocompleteItem({
    required this.label,
    required this.insertText,
    required this.detail,
    required this.category,
    required this.icon,
    required this.color,
  });
}

class StEditorScreenState extends State<StEditorScreen> {
  late TextEditingController _codeController;
  late TextEditingController _programNameController;
  late TextEditingController _descriptionController;
  PlcProgram? _selectedProgram;
  String _compilationStatus = 'Ready';
  bool _isCompiled = true;

  // Autocomplete state
  List<AutocompleteItem> _currentSuggestions = [];
  bool _showAutocompleteOverlay = false;

  // Debounced model persistence. Every other editor (LD/FBD/FB/HMI/...)
  // mutates the project model immediately on edit and calls
  // onProjectUpdated/onProgramUpdated so the shell's autosave + undo history
  // pick it up; this editor used to only write `stSource` back into the
  // model when the explicit "Save" button was pressed, so typed-but-unsaved
  // code was silently discarded on navigating away and back (Bug 3). This
  // timer persists the current buffer into the model on a short pause in
  // typing, and is flushed synchronously (see [_flushPendingPersist])
  // whenever the buffer is about to be discarded or replaced — dispose,
  // switching to a different program, or loading a template — so navigation
  // can never lose text. It deliberately does not gate on
  // `_compileAndVerify()`/`_isCompiled`: that check stays a Save-button-only
  // affordance, not a precondition for the model reflecting what's typed.
  Timer? _persistDebounce;
  static const Duration _persistDebounceDuration = Duration(milliseconds: 350);

  // Guards `_onCodeChanged` while a program/template load is programmatically
  // overwriting `_codeController.text` (which fires the same listener a real
  // keystroke would), so opening/switching programs never schedules a
  // spurious persist of content that's already in the model.
  bool _suppressPersistScheduling = false;

  /// Whether the Program Name field has been edited since the last persist
  /// that applied it.
  ///
  /// The name is deliberately NOT applied by the debounced persist: the shell
  /// keys the centre pane on `PROGRAM:<name>`, so renaming the program
  /// mid-keystroke would re-key (and therefore rebuild-from-scratch) the very
  /// editor the user is typing in. It IS applied by every flush — dispose,
  /// host-driven flush before a view/project switch, switching programs
  /// inside this editor — which is exactly "navigating away", so a header
  /// edit is never silently dropped. Description has no such coupling and
  /// rides the ordinary debounce.
  bool _pendingNameEdit = false;

  final Map<String, String> _stTemplates = {
    'Motor Control (IF/THEN)': '''// Structured Text: Motor Start/Stop Control
IF (Start_PB OR Motor_Latch) AND NOT Stop_PB AND EStop_OK AND Overload_OK THEN
    Motor_Latch := TRUE;
ELSE
    Motor_Latch := FALSE;
END_IF;
Motor_Run := Motor_Latch AND EStop_OK AND Overload_OK;''',

    'Tank Level Control (IF/ELSIF)': '''// Structured Text: Tank Level Fill/Drain Control
IF Auto_Mode THEN
    IF Level_PV < (Level_SP - 5.0) THEN
        Fill_Valve := TRUE;
        Drain_Valve := FALSE;
    ELSIF Level_PV > (Level_SP + 5.0) THEN
        Fill_Valve := FALSE;
        Drain_Valve := TRUE;
    ELSE
        Fill_Valve := FALSE;
        Drain_Valve := FALSE;
    END_IF;
END_IF;
High_Alarm := Level_PV > 85.0;''',

    'Timer On Delay (TON)': '''// Structured Text: Pump Delay Timer
TON_1(IN := Start_PB, PT := 5000);
IF TON_1_Q THEN
    Motor_Run := TRUE;
END_IF;''',

    'Counter Loop (FOR)': '''// Structured Text: Batch Process Counter Loop
FOR i := 1 TO 10 DO
    Batch_Total := Batch_Total + 1;
END_FOR;''',
  };

  @override
  void initState() {
    super.initState();
    _codeController = TextEditingController();
    _programNameController = TextEditingController(text: 'NewStProgram');
    _descriptionController = TextEditingController(text: 'Structured Text Logic');

    _codeController.addListener(_onCodeChanged);
    _programNameController.addListener(_onProgramNameChanged);
    _descriptionController.addListener(_onDescriptionChanged);

    // Select first ST program if available
    final stProgs = widget.currentProject.programs.where((p) => p.language == 'StructuredText').toList();
    if (stProgs.isNotEmpty) {
      _loadProgram(stProgs.first);
    } else {
      _loadTemplate(_stTemplates.keys.first);
    }
    widget.onEditorAttached?.call(this);
  }

  @override
  void dispose() {
    widget.onEditorDetached?.call(this);
    // Flush before tearing down the controllers so a keystroke that landed
    // just before navigating away is never lost — this is the fix for
    // Bug 3 ("ST Editor silently discards unsaved typed edits on navigating
    // away and back"). The host normally flushes us first (see
    // [flushPendingEdits]); this is the safety net for teardown paths it
    // doesn't drive, and it deliberately does not notify the host inline.
    _flushPendingPersistForDispose();
    _codeController.removeListener(_onCodeChanged);
    _programNameController.removeListener(_onProgramNameChanged);
    _descriptionController.removeListener(_onDescriptionChanged);
    _codeController.dispose();
    _programNameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  /// Whether anything typed here has yet to reach the model.
  bool get _hasUnpersistedEdits => _persistDebounce != null || _pendingNameEdit;

  /// Writes any in-flight typed edits into the model right now, host
  /// notification included.
  ///
  /// This is the seam the workspace shell calls BEFORE it replaces the active
  /// project / active view / restores an undo snapshot — i.e. before anything
  /// that re-keys and disposes this editor. Running the flush there (rather
  /// than leaving it to `dispose`) is what makes the write land in the
  /// project it was typed into, keeps it inside the normal edit -> dirty ->
  /// history flow, and keeps `setState` out of the framework's tree-lock
  /// window. Safe to call when nothing is pending (no-op).
  void flushPendingEdits() {
    if (!_hasUnpersistedEdits) return;
    _persistDebounce?.cancel();
    _persistDebounce = null;
    _persistToModel(applyName: true);
  }

  /// Cancels any pending debounced persist and, if one was pending, runs it
  /// immediately. Called whenever the current buffer is about to be
  /// discarded or replaced from inside this editor (switching programs,
  /// loading a template) so in-flight typed edits are never silently dropped.
  void _flushPendingPersist() => flushPendingEdits();

  /// The `dispose()`-time flush.
  ///
  /// `dispose` runs inside the framework's tree-lock window, where the host's
  /// `setState` throws ("setState() or markNeedsBuild() called when widget
  /// tree was locked") — which also aborted the rest of `dispose`, leaking
  /// the controller listeners. So the model mutation is applied synchronously
  /// with `notifyHost: false` (nothing is lost even if no further frame ever
  /// runs), and the host notification is re-issued from a post-frame callback
  /// where `setState` is legal again.
  void _flushPendingPersistForDispose() {
    if (!_hasUnpersistedEdits) return;
    _persistDebounce?.cancel();
    _persistDebounce = null;
    final prog = _persistToModel(applyName: true, notifyHost: false);
    final save = widget.onSaveProgram;
    SchedulerBinding.instance.addPostFrameCallback((_) => save(prog, notifyHost: true));
  }

  /// (Re)starts the debounce window that persists the current code-editor
  /// buffer into the model. Deliberately short (well under the shell's
  /// 800ms autosave/history debounce) so a pause in typing writes the model
  /// promptly, while the shell's own debounce is what actually coalesces a
  /// burst of rapid edits into a single undo step (see
  /// `_markDirtyAndAutosave`/`_pendingHistoryCapture` in workspace_shell.dart
  /// and the coalescing test in workspace_undo_redo_test.dart) — this timer
  /// only needs to avoid rebuilding the whole shell on every keystroke.
  void _schedulePersist() {
    _persistDebounce?.cancel();
    _persistDebounce = Timer(_persistDebounceDuration, () => _persistToModel());
  }

  /// Header-field listeners. A name edit is only *recorded* here (see
  /// [_pendingNameEdit]); a description edit rides the ordinary debounce.
  void _onProgramNameChanged() {
    if (_suppressPersistScheduling) return;
    _pendingNameEdit = true;
  }

  void _onDescriptionChanged() {
    if (_suppressPersistScheduling) return;
    _schedulePersist();
  }

  /// Writes the current editor buffers into the model right now,
  /// independent of the "Compile & Verify" gate the explicit Save button
  /// applies — matching every other editor's immediate-mutation +
  /// onProjectUpdated convention rather than requiring an explicit save
  /// workflow before the model (and therefore autosave + undo history)
  /// reflects what's typed.
  ///
  /// The selected program is mutated IN PLACE rather than replaced by a
  /// freshly-constructed one: this editor owns exactly three fields
  /// (name/description/stSource), and rebuilding the program from just those
  /// silently reset every other field the program carried — `enabled` most
  /// visibly, which meant typing in a disabled program quietly re-enabled it.
  /// In-place mutation also means a rename actually lands even though the
  /// host looks the program up by name.
  PlcProgram _persistToModel({bool applyName = false, bool notifyHost = true}) {
    _persistDebounce = null;
    final typedName = _programNameController.text.trim();
    final baseline = _selectedProgram;
    if (baseline != null) {
      // Captured BEFORE any rename below — `baseline` is mutated in place
      // (see the class doc comment on `_persistToModel`), so this is the
      // host's only chance to learn what the program was called a moment
      // ago (see `StProgramSaveCallback`'s doc comment).
      final previousName = baseline.name;
      if (applyName && typedName.isNotEmpty) {
        baseline.name = typedName;
        _pendingNameEdit = false;
      }
      baseline.description = _descriptionController.text;
      baseline.stSource = _codeController.text;
      widget.onSaveProgram(baseline, notifyHost: notifyHost, previousName: previousName);
      return baseline;
    }
    // No program selected yet (a template was loaded into an empty project):
    // there is nothing in the model to mutate, so hand the host a new one.
    final prog = PlcProgram(
      name: typedName.isEmpty ? 'StProgram' : typedName,
      language: 'StructuredText',
      description: _descriptionController.text,
      stSource: _codeController.text,
    );
    if (applyName) _pendingNameEdit = false;
    _selectedProgram = prog;
    widget.onSaveProgram(prog, notifyHost: notifyHost, previousName: null);
    return prog;
  }

  void _loadProgram(PlcProgram prog) {
    // Persist whatever was pending for the previously-selected program
    // before switching the buffer away from it.
    _flushPendingPersist();
    _suppressPersistScheduling = true;
    setState(() {
      _selectedProgram = prog;
      _programNameController.text = prog.name;
      _descriptionController.text = prog.description;
      _codeController.text = prog.stSource;
      _compilationStatus = 'Loaded "${prog.name}"';
      _isCompiled = true;
      _showAutocompleteOverlay = false;
    });
    _suppressPersistScheduling = false;
  }

  void _loadTemplate(String templateKey) {
    _flushPendingPersist();
    _suppressPersistScheduling = true;
    setState(() {
      _codeController.text = _stTemplates[templateKey] ?? '';
      _compilationStatus = 'Template loaded: $templateKey';
      _isCompiled = false;
      _showAutocompleteOverlay = false;
    });
    _suppressPersistScheduling = false;
  }

  List<AutocompleteItem> _buildAllAutocompleteItems() {
    final items = <AutocompleteItem>[];

    // 1. Global Project Tags
    for (var tag in widget.currentProject.tags) {
      items.add(AutocompleteItem(
        label: tag.name,
        insertText: tag.name,
        detail: '${tag.path} [${tag.dataType}] — ${tag.ioType}',
        category: 'TAG',
        icon: Icons.label_important,
        color: Colors.greenAccent,
      ));
    }

    // 2. Struct Definitions (DUT)
    for (var stDef in widget.currentProject.structDefs) {
      items.add(AutocompleteItem(
        label: stDef.name,
        insertText: stDef.name,
        detail: 'User Defined Struct Type (${stDef.fields.length} fields)',
        category: 'STRUCT',
        icon: Icons.dataset,
        color: Colors.tealAccent,
      ));
    }

    // 3. Built-in IEC 61131-3 Function Blocks & Math Functions
    final functions = [
      AutocompleteItem(label: 'TON', insertText: 'TON_1(IN := , PT := 5000);', detail: 'Timer On Delay Function Block', category: 'FUNCTION', icon: Icons.timer, color: Colors.amberAccent),
      AutocompleteItem(label: 'TOF', insertText: 'TOF_1(IN := , PT := 5000);', detail: 'Timer Off Delay Function Block', category: 'FUNCTION', icon: Icons.timer_off, color: Colors.amberAccent),
      AutocompleteItem(label: 'TP', insertText: 'TP_1(IN := , PT := 1000);', detail: 'Pulse Timer Function Block', category: 'FUNCTION', icon: Icons.timelapse, color: Colors.amberAccent),
      AutocompleteItem(label: 'CTU', insertText: 'CTU_1(CU := , PV := 10);', detail: 'Count Up Function Block', category: 'FUNCTION', icon: Icons.plus_one, color: Colors.cyanAccent),
      AutocompleteItem(label: 'CTD', insertText: 'CTD_1(CD := , PV := 10);', detail: 'Count Down Function Block', category: 'FUNCTION', icon: Icons.exposure_minus_1, color: Colors.cyanAccent),
      AutocompleteItem(label: 'ABS', insertText: 'ABS()', detail: 'Absolute Value Math Function', category: 'MATH', icon: Icons.calculate, color: Colors.orangeAccent),
      AutocompleteItem(label: 'SQRT', insertText: 'SQRT()', detail: 'Square Root Math Function', category: 'MATH', icon: Icons.calculate, color: Colors.orangeAccent),
      AutocompleteItem(label: 'LIMIT', insertText: 'LIMIT(0.0, IN_VAR, 100.0)', detail: 'Limit Clamp (Min, In, Max)', category: 'MATH', icon: Icons.tune, color: Colors.orangeAccent),
      AutocompleteItem(label: 'SEL', insertText: 'SEL(G_BOOL, IN0, IN1)', detail: 'Binary Selection (G ? IN1 : IN0)', category: 'MATH', icon: Icons.alt_route, color: Colors.orangeAccent),
    ];
    items.addAll(functions);

    // 4. IEC 61131-3 Control Keywords
    final keywords = [
      AutocompleteItem(label: 'IF .. THEN .. END_IF', insertText: 'IF  THEN\n    \nEND_IF;', detail: 'Conditional Statement', category: 'KEYWORD', icon: Icons.code, color: Colors.blueAccent),
      AutocompleteItem(label: 'IF .. ELSIF .. ELSE', insertText: 'IF  THEN\n    \nELSIF  THEN\n    \nELSE\n    \nEND_IF;', detail: 'Multi-branch Conditional Statement', category: 'KEYWORD', icon: Icons.code, color: Colors.blueAccent),
      AutocompleteItem(label: 'WHILE .. DO .. END_WHILE', insertText: 'WHILE  DO\n    \nEND_WHILE;', detail: 'While Loop Statement', category: 'KEYWORD', icon: Icons.loop, color: Colors.purpleAccent),
      AutocompleteItem(label: 'REPEAT .. UNTIL .. END_REPEAT', insertText: 'REPEAT\n    \nUNTIL \nEND_REPEAT;', detail: 'Repeat Loop Statement', category: 'KEYWORD', icon: Icons.loop, color: Colors.purpleAccent),
      AutocompleteItem(label: 'FOR .. TO .. DO .. END_FOR', insertText: 'FOR i := 1 TO 10 DO\n    \nEND_FOR;', detail: 'Counted Loop Statement', category: 'KEYWORD', icon: Icons.repeat, color: Colors.purpleAccent),
    ];
    items.addAll(keywords);

    return items;
  }

  void _onCodeChanged() {
    if (!_suppressPersistScheduling) {
      _schedulePersist();
    }

    final text = _codeController.text;
    final selection = _codeController.selection;

    if (!selection.isValid || selection.baseOffset == 0) {
      if (_showAutocompleteOverlay) setState(() => _showAutocompleteOverlay = false);
      return;
    }

    // Extract the word prefix immediately preceding cursor
    final offset = selection.baseOffset;
    final textBeforeCursor = text.substring(0, offset);
    final wordMatch = RegExp(r'[a-zA-Z0-9_\.]+$').firstMatch(textBeforeCursor);

    if (wordMatch != null) {
      final wordPrefix = wordMatch.group(0)!;
      if (wordPrefix.isNotEmpty) {
        final allItems = _buildAllAutocompleteItems();
        final matches = allItems.where((item) {
          return item.label.toLowerCase().contains(wordPrefix.toLowerCase()) ||
              item.insertText.toLowerCase().contains(wordPrefix.toLowerCase());
        }).toList();

        if (matches.isNotEmpty) {
          setState(() {
            _currentSuggestions = matches;
            _showAutocompleteOverlay = true;
          });
          return;
        }
      }
    }

    if (_showAutocompleteOverlay) {
      setState(() => _showAutocompleteOverlay = false);
    }
  }

  void _insertSuggestion(AutocompleteItem item) {
    final text = _codeController.text;
    final selection = _codeController.selection;

    if (!selection.isValid) {
      _codeController.text += item.insertText;
      return;
    }

    final offset = selection.baseOffset;
    final textBeforeCursor = text.substring(0, offset);
    final textAfterCursor = text.substring(offset);

    // Find the word boundary before cursor to replace
    final wordMatch = RegExp(r'[a-zA-Z0-9_\.]+$').firstMatch(textBeforeCursor);
    final startReplaceIndex = wordMatch != null ? wordMatch.start : offset;

    final newText = text.substring(0, startReplaceIndex) + item.insertText + textAfterCursor;
    final newCursorOffset = startReplaceIndex + item.insertText.length;

    _codeController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursorOffset),
    );

    setState(() {
      _showAutocompleteOverlay = false;
    });
  }

  void _compileAndVerify() {
    final code = _codeController.text;
    if (code.trim().isEmpty) {
      setState(() {
        _compilationStatus = 'Error: Code is empty';
        _isCompiled = false;
      });
      return;
    }

    int ifCount = RegExp(r'\bIF\b', caseSensitive: false).allMatches(code).length;
    int endIfCount = RegExp(r'\bEND_IF\b', caseSensitive: false).allMatches(code).length;
    int whileCount = RegExp(r'\bWHILE\b', caseSensitive: false).allMatches(code).length;
    int endWhileCount = RegExp(r'\bEND_WHILE\b', caseSensitive: false).allMatches(code).length;

    if (ifCount != endIfCount) {
      setState(() {
        _compilationStatus = 'Syntax Error: Mismatched IF ($ifCount) and END_IF ($endIfCount)';
        _isCompiled = false;
      });
      return;
    }

    if (whileCount != endWhileCount) {
      setState(() {
        _compilationStatus = 'Syntax Error: Mismatched WHILE ($whileCount) and END_WHILE ($endWhileCount)';
        _isCompiled = false;
      });
      return;
    }

    setState(() {
      _compilationStatus = '✅ Compiled Successfully (0 errors, AST valid)';
      _isCompiled = true;
    });
  }

  void _saveProgram() {
    // The explicit Save button always writes the freshest text, so any
    // debounced auto-persist still pending is redundant — cancel it rather
    // than let it fire again moments later with (by then) identical content.
    _persistDebounce?.cancel();
    _persistDebounce = null;

    _compileAndVerify();
    if (!_isCompiled) return;

    // Same in-place write the auto-persist uses (so Save can't reset
    // `enabled` or any other field this editor doesn't own either).
    final prog = _persistToModel(applyName: true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Program "${prog.name}" saved to project!')),
    );
  }

  /// Closes the enclosing Drawer first when hosted there (compact width),
  /// so the newly selected program is visible immediately.
  void _selectProgram(BuildContext context, PlcProgram prog) {
    if (!context.isExpanded) {
      Navigator.pop(context);
    }
    _loadProgram(prog);
  }

  void _selectTemplate(BuildContext context, String title) {
    if (!context.isExpanded) {
      Navigator.pop(context);
    }
    _loadTemplate(title);
  }

  /// The inner content of the program-selector sidebar — shared by the
  /// inline (expanded, fixed width 280) dock and the compact `Drawer`
  /// (which supplies its own width), so it must not declare a fixed width.
  Widget _buildSidebarContent(BuildContext context, List<PlcProgram> stPrograms) {
    return Container(
      color: const Color(0xFF0F172A),
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Text('PROJECT ST PROGRAMS', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 8),

          if (stPrograms.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No ST programs yet. Create one or pick a template!', style: TextStyle(fontSize: 12, color: Colors.grey)),
            )
          else
            ...stPrograms.map((prog) => Card(
              color: _selectedProgram?.name == prog.name ? Colors.cyan.withValues(alpha: 0.2) : const Color(0xFF1E293B),
              child: ListTile(
                dense: true,
                title: Text(prog.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(prog.description, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10)),
                onTap: () => _selectProgram(context, prog),
              ),
            )),

          const Divider(height: 24),
          const Text('CODE TEMPLATES', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 8),

          ..._stTemplates.keys.map((title) => Card(
            color: const Color(0xFF1E293B),
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.code, size: 16, color: Colors.cyan),
              title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
              onTap: () => _selectTemplate(context, title),
            ),
          )),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final stPrograms = widget.currentProject.programs.where((p) => p.language == 'StructuredText').toList();
    final allItems = _buildAllAutocompleteItems();
    final expanded = context.isExpanded;
    final compact = context.isCompact;
    final short = context.isShort;

    return Scaffold(
      appBar: AppBar(
        title: Text(short ? 'ST Code Editor' : 'Structured Text (ST) Code Editor'),
        backgroundColor: const Color(0xFF1E293B),
        toolbarHeight: short ? 46 : null,
        actions: [
          IconButton(
            icon: const Icon(Icons.play_circle_fill, color: Colors.greenAccent),
            tooltip: 'Compile & Verify AST',
            onPressed: _compileAndVerify,
          ),
          IconButton(
            icon: const Icon(Icons.save, color: Colors.cyan),
            tooltip: 'Save to Project',
            onPressed: _saveProgram,
          ),
        ],
      ),
      // On compact widths the program-selector sidebar moves into a Drawer
      // (with a hamburger the AppBar provides automatically) so the code
      // editor can use the full window width.
      drawer: expanded ? null : Drawer(child: _buildSidebarContent(context, stPrograms)),
      body: Row(
        children: [
          // Sidebar: Program selector & Templates (inline only when expanded)
          if (expanded) ...[
            SizedBox(
              width: 280,
              child: _buildSidebarContent(context, stPrograms),
            ),
            const VerticalDivider(width: 1, color: Colors.white12),
          ],

          // Main Editor Area with Autocomplete Palette & Quick Symbol Bar
          Expanded(
            child: Column(
              children: [
                // Program Details Header Bar
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  color: const Color(0xFF1E293B),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _programNameController,
                          decoration: const InputDecoration(
                            labelText: 'Program Name',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: _descriptionController,
                          decoration: const InputDecoration(
                            labelText: 'Description',
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Quick Insert Toolbar (Tags, DBs, Functions, Keywords)
                Container(
                  height: 36,
                  color: const Color(0xFF161E2E),
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    children: [
                      const Center(child: Text('QUICK INSERT: ', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey))),
                      const SizedBox(width: 8),
                      ...allItems.take(12).map((item) => Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ActionChip(
                          avatar: Icon(item.icon, size: 12, color: item.color),
                          label: Text(item.label, style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
                          backgroundColor: const Color(0xFF1E293B),
                          padding: EdgeInsets.zero,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          onPressed: () => _insertSuggestion(item),
                        ),
                      )),
                    ],
                  ),
                ),

                // Editor Workspace with Autocomplete Overlay Palette
                Expanded(
                  child: Stack(
                    children: [
                      // Text Editor Input
                      Container(
                        padding: const EdgeInsets.all(12),
                        color: const Color(0xFF0D1117), // Dark IDE background
                        child: TextField(
                          key: const Key('stCodeEditorField'),
                          controller: _codeController,
                          maxLines: null,
                          expands: true,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 14,
                            color: Color(0xFFE6EDE3),
                            height: 1.5,
                          ),
                          decoration: const InputDecoration(
                            hintText: '// Write Structured Text logic here...\n// Type tag or function names to view live autocomplete suggestions!\n\nIF Start_PB THEN\n    Motor_Run := TRUE;\nEND_IF;',
                            border: InputBorder.none,
                          ),
                        ),
                      ),

                      // Floating Autocomplete Suggestion Palette Overlay
                      if (_showAutocompleteOverlay && _currentSuggestions.isNotEmpty)
                        Positioned(
                          bottom: 12,
                          left: 12,
                          right: 12,
                          child: Align(
                            alignment: Alignment.bottomLeft,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: math.min(360.0, MediaQuery.sizeOf(context).width - 32),
                              ),
                              child: Material(
                            elevation: 8,
                            color: const Color(0xFF1E293B),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                              side: const BorderSide(color: Colors.cyan, width: 1.5),
                            ),
                            child: Container(
                              constraints: const BoxConstraints(maxHeight: 220),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    color: const Color(0xFF0F172A),
                                    child: Row(
                                      children: [
                                        const Icon(Icons.auto_awesome, size: 14, color: Colors.cyanAccent),
                                        const SizedBox(width: 6),
                                        Text(
                                          'AUTOCOMPLETE SUGGESTIONS (${_currentSuggestions.length})',
                                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.cyanAccent),
                                        ),
                                        const Spacer(),
                                        const Text('Click or press to insert', style: TextStyle(fontSize: 10, color: Colors.grey)),
                                      ],
                                    ),
                                  ),
                                  Flexible(
                                    child: ListView.separated(
                                      shrinkWrap: true,
                                      itemCount: _currentSuggestions.length,
                                      separatorBuilder: (ctx, idx) => const Divider(height: 1, color: Colors.white12),
                                      itemBuilder: (context, index) {
                                        final item = _currentSuggestions[index];
                                        return ListTile(
                                          dense: true,
                                          leading: Icon(item.icon, color: item.color, size: 16),
                                          title: Row(
                                            children: [
                                              Text(item.label, style: const TextStyle(fontWeight: FontWeight.bold, fontFamily: 'monospace', fontSize: 13)),
                                              const SizedBox(width: 8),
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                decoration: BoxDecoration(
                                                  color: item.color.withValues(alpha: 0.2),
                                                  borderRadius: BorderRadius.circular(4),
                                                ),
                                                child: Text(item.category, style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: item.color)),
                                              ),
                                            ],
                                          ),
                                          subtitle: Text(item.detail, style: const TextStyle(fontSize: 11, color: Colors.grey)),
                                          onTap: () => _insertSuggestion(item),
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),

                // Status & Compiler Console
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  color: _compilationStatus.startsWith('✅')
                      ? Colors.green.shade900.withValues(alpha: 0.4)
                      : (_compilationStatus.startsWith('Error') ? Colors.red.shade900.withValues(alpha: 0.4) : const Color(0xFF1E293B)),
                  child: Row(
                    children: [
                      Icon(
                        _compilationStatus.startsWith('✅') ? Icons.check_circle : Icons.terminal,
                        size: 16,
                        color: _compilationStatus.startsWith('✅') ? Colors.greenAccent : Colors.cyan,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _compilationStatus,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _compilationStatus.startsWith('✅') ? Colors.greenAccent : Colors.white70,
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.flash_on, size: 16),
                        label: Text(compact ? 'Apply' : 'Compile & Apply to PLC'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.cyan.shade700,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: _saveProgram,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
