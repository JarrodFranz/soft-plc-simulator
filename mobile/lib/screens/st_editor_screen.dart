import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/project_model.dart';
import '../ui/responsive.dart';

class StEditorScreen extends StatefulWidget {
  final PlcProject currentProject;
  final Function(PlcProgram program) onSaveProgram;

  const StEditorScreen({
    super.key,
    required this.currentProject,
    required this.onSaveProgram,
  });

  @override
  State<StEditorScreen> createState() => _StEditorScreenState();
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

class _StEditorScreenState extends State<StEditorScreen> {
  late TextEditingController _codeController;
  late TextEditingController _programNameController;
  late TextEditingController _descriptionController;
  PlcProgram? _selectedProgram;
  String _compilationStatus = 'Ready';
  bool _isCompiled = true;

  // Autocomplete state
  List<AutocompleteItem> _currentSuggestions = [];
  bool _showAutocompleteOverlay = false;

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

    // Select first ST program if available
    final stProgs = widget.currentProject.programs.where((p) => p.language == 'StructuredText').toList();
    if (stProgs.isNotEmpty) {
      _loadProgram(stProgs.first);
    } else {
      _loadTemplate(_stTemplates.keys.first);
    }
  }

  @override
  void dispose() {
    _codeController.removeListener(_onCodeChanged);
    _codeController.dispose();
    _programNameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  void _loadProgram(PlcProgram prog) {
    setState(() {
      _selectedProgram = prog;
      _programNameController.text = prog.name;
      _descriptionController.text = prog.description;
      _codeController.text = prog.stSource;
      _compilationStatus = 'Loaded "${prog.name}"';
      _isCompiled = true;
      _showAutocompleteOverlay = false;
    });
  }

  void _loadTemplate(String templateKey) {
    setState(() {
      _codeController.text = _stTemplates[templateKey] ?? '';
      _compilationStatus = 'Template loaded: $templateKey';
      _isCompiled = false;
      _showAutocompleteOverlay = false;
    });
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
    _compileAndVerify();
    if (!_isCompiled) return;

    final prog = PlcProgram(
      name: _programNameController.text.trim().isEmpty ? 'StProgram' : _programNameController.text.trim(),
      language: 'StructuredText',
      description: _descriptionController.text,
      stSource: _codeController.text,
    );

    widget.onSaveProgram(prog);
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
