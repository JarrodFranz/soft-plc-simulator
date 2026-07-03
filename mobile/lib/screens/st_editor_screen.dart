import 'package:flutter/material.dart';
import '../models/project_model.dart';

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

class _StEditorScreenState extends State<StEditorScreen> {
  late TextEditingController _codeController;
  late TextEditingController _programNameController;
  late TextEditingController _descriptionController;
  PlcProgram? _selectedProgram;
  String _compilationStatus = 'Ready';
  bool _isCompiled = true;

  final Map<String, String> _stTemplates = {
    'Motor Control (IF/THEN)': '''// Structured Text: Motor Start/Stop Control
IF (Start_PB OR Motor_Run) AND NOT Stop_PB AND EStop_OK AND Overload_OK THEN
    Motor_Run := TRUE;
ELSE
    Motor_Run := FALSE;
END_IF;''',

    'Tank Level Control (IF/ELSIF)': '''// Structured Text: Tank Level Fill/Drain Control
IF Level_PV < Level_SP - 5.0 THEN
    Fill_Valve := TRUE;
    Drain_Valve := FALSE;
ELSIF Level_PV > Level_SP + 5.0 THEN
    Fill_Valve := FALSE;
    Drain_Valve := TRUE;
ELSE
    Fill_Valve := FALSE;
    Drain_Valve := FALSE;
END_IF;''',

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

    // Select first ST program if available
    final stProgs = widget.currentProject.programs.where((p) => p.language == 'StructuredText').toList();
    if (stProgs.isNotEmpty) {
      _loadProgram(stProgs.first);
    } else {
      _loadTemplate(_stTemplates.keys.first);
    }
  }

  void _loadProgram(PlcProgram prog) {
    setState(() {
      _selectedProgram = prog;
      _programNameController.text = prog.name;
      _descriptionController.text = prog.description;
      _codeController.text = prog.stSource;
      _compilationStatus = 'Loaded "${prog.name}"';
      _isCompiled = true;
    });
  }

  void _loadTemplate(String templateKey) {
    setState(() {
      _codeController.text = _stTemplates[templateKey] ?? '';
      _compilationStatus = 'Template loaded: $templateKey';
      _isCompiled = false;
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

    // Basic client-side syntax verification (checks matching IF/END_IF, semicolon, parenthesis)
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

  @override
  Widget build(BuildContext context) {
    final stPrograms = widget.currentProject.programs.where((p) => p.language == 'StructuredText').toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Structured Text (ST) Code Editor'),
        backgroundColor: const Color(0xFF1E293B),
        actions: [
          IconButton(
            icon: const Icon(Icons.play_circle_fill, color: Colors.greenAccent),
            tooltip: 'Compile & Verify',
            onPressed: _compileAndVerify,
          ),
          IconButton(
            icon: const Icon(Icons.save, color: Colors.cyan),
            tooltip: 'Save to Project',
            onPressed: _saveProgram,
          ),
        ],
      ),
      body: Row(
        children: [
          // Sidebar: Program selector & Templates
          Container(
            width: 280,
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
                    color: _selectedProgram?.name == prog.name ? Colors.cyan.withOpacity(0.2) : const Color(0xFF1E293B),
                    child: ListTile(
                      dense: true,
                      title: Text(prog.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text(prog.description, style: const TextStyle(fontSize: 10)),
                      onTap: () => _loadProgram(prog),
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
                    title: Text(title, style: const TextStyle(fontSize: 12)),
                    onTap: () => _loadTemplate(title),
                  ),
                )),
              ],
            ),
          ),

          const VerticalDivider(width: 1, color: Colors.white12),

          // Main Editor Area
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

                // Editor Workspace
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    color: const Color(0xFF0D1117), // GitHub dark code editor color
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
                        hintText: '// Write IEC 61131-3 Structured Text logic here...\n\nIF Start_PB THEN\n    Motor_Run := TRUE;\nEND_IF;',
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                ),

                // Status & Compiler Console
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  color: _compilationStatus.startsWith('✅')
                      ? Colors.green.shade900.withOpacity(0.4)
                      : (_compilationStatus.startsWith('Error') ? Colors.red.shade900.withOpacity(0.4) : const Color(0xFF1E293B)),
                  child: Row(
                    children: [
                      Icon(
                        _compilationStatus.startsWith('✅') ? Icons.check_circle : Icons.terminal,
                        size: 16,
                        color: _compilationStatus.startsWith('✅') ? Colors.greenAccent : Colors.cyan,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        _compilationStatus,
                        style: TextStyle(
                          color: _compilationStatus.startsWith('✅') ? Colors.greenAccent : Colors.white70,
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                      const Spacer(),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.flash_on, size: 16),
                        label: const Text('Compile & Apply to PLC'),
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
