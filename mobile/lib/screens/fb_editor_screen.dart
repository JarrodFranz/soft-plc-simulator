import 'package:flutter/material.dart';
import '../models/fb_name_validation.dart';
import '../models/project_model.dart';
import '../models/tag_resolver.dart';
import '../ui/responsive.dart';
import '../widgets/scalar_value_field.dart';

/// Authoring screen for custom (user-defined) Function Block definitions:
/// create/rename an FB, edit its typed interface (vars: name/dataType/
/// direction/initial value), and edit its Structured-Text body — all routed
/// through `onProjectUpdated` (the same autosave path the struct-def CRUD tab
/// in Memory Manager uses). Structurally an FB definition is a struct (name +
/// typed field list) plus a direction per field plus an ST body, so this
/// mirrors that tab's add/edit/delete row pattern rather than inventing a new
/// one.
class FbEditorScreen extends StatefulWidget {
  final PlcProject currentProject;
  final VoidCallback onProjectUpdated;

  const FbEditorScreen({
    super.key,
    required this.currentProject,
    required this.onProjectUpdated,
  });

  @override
  State<FbEditorScreen> createState() => _FbEditorScreenState();
}

class _FbEditorScreenState extends State<FbEditorScreen> {
  FbDefinition? _selected;
  final TextEditingController _stController = TextEditingController();
  final Map<FbVar, TextEditingController> _varNameControllers = {};

  static const List<String> _scalarAndCompositeTypes = [
    'BOOL', 'INT16', 'INT32', 'INT64', 'FLOAT64', 'STRING',
  ];

  @override
  void initState() {
    super.initState();
    if (widget.currentProject.fbDefinitions.isNotEmpty) {
      _select(widget.currentProject.fbDefinitions.first);
    }
  }

  @override
  void dispose() {
    _stController.dispose();
    for (final c in _varNameControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _select(FbDefinition fb) {
    for (final c in _varNameControllers.values) {
      c.dispose();
    }
    _varNameControllers.clear();
    setState(() {
      _selected = fb;
      _stController.text = fb.stSource;
    });
  }

  void _selectAndMaybeClose(BuildContext context, FbDefinition fb) {
    if (!context.isExpanded && Navigator.of(context).canPop()) {
      Navigator.pop(context);
    }
    _select(fb);
  }

  TextEditingController _varNameCtrl(FbVar v) =>
      _varNameControllers.putIfAbsent(v, () => TextEditingController(text: v.name));

  List<String> _availableTypes() => [
        ..._scalarAndCompositeTypes,
        ...builtinCompositeNames(),
        ...widget.currentProject.structDefs.map((s) => s.name),
      ];

  void _showAddFbDialog() {
    showDialog(
      context: context,
      builder: (ctx) {
        final nameCtrl = TextEditingController();
        String? errorText;
        return StatefulBuilder(
          builder: (context, setDlgState) => AlertDialog(
            title: const Text('New Function Block'),
            content: TextField(
              key: const Key('fb_new_name_field'),
              controller: nameCtrl,
              autofocus: true,
              decoration: InputDecoration(labelText: 'FB Name', errorText: errorText),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                key: const Key('fb_new_confirm'),
                onPressed: () {
                  final name = nameCtrl.text.trim();
                  final error = fbNameValidationError(widget.currentProject, name);
                  if (error != null) {
                    setDlgState(() => errorText = error);
                    return;
                  }
                  final fb = FbDefinition(name: name);
                  setState(() {
                    widget.currentProject.fbDefinitions.add(fb);
                  });
                  _select(fb);
                  widget.onProjectUpdated();
                  Navigator.pop(ctx);
                },
                child: const Text('Create'),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showRenameFbDialog(FbDefinition fb) {
    showDialog(
      context: context,
      builder: (ctx) {
        final nameCtrl = TextEditingController(text: fb.name);
        String? errorText;
        return StatefulBuilder(
          builder: (context, setDlgState) => AlertDialog(
            title: const Text('Rename Function Block'),
            content: TextField(
              key: const Key('fb_rename_name_field'),
              controller: nameCtrl,
              autofocus: true,
              decoration: InputDecoration(labelText: 'FB Name', errorText: errorText),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                key: const Key('fb_rename_confirm'),
                onPressed: () {
                  final name = nameCtrl.text.trim();
                  if (name == fb.name) {
                    Navigator.pop(ctx);
                    return;
                  }
                  final error = fbNameValidationError(widget.currentProject, name, excluding: fb);
                  if (error != null) {
                    setDlgState(() => errorText = error);
                    return;
                  }
                  setState(() => renameFbDefinition(widget.currentProject, fb.name, name));
                  widget.onProjectUpdated();
                  Navigator.pop(ctx);
                },
                child: const Text('Save'),
              ),
            ],
          ),
        );
      },
    );
  }

  void _addVar() {
    final fb = _selected;
    if (fb == null) return;
    setState(() {
      fb.vars.add(FbVar(
        name: 'Var${fb.vars.length + 1}',
        dataType: 'BOOL',
        direction: FbVarDir.internal,
        initialValue: false,
      ));
    });
    widget.onProjectUpdated();
  }

  void _deleteVar(FbVar v) {
    final fb = _selected;
    if (fb == null) return;
    setState(() {
      fb.vars.remove(v);
    });
    _varNameControllers.remove(v)?.dispose();
    widget.onProjectUpdated();
  }

  Widget _buildVarRow(int i, FbVar v) {
    final availableTypes = _availableTypes();
    final currentType = availableTypes.contains(v.dataType) ? v.dataType : availableTypes.first;
    final isScalar = lookupComposite(widget.currentProject, v.dataType) == null;
    return Card(
      key: Key('fb_var_row_$i'),
      color: const Color(0xFF1E293B),
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: Key('fb_var_name_$i'),
                    controller: _varNameCtrl(v),
                    decoration: const InputDecoration(labelText: 'Name', isDense: true),
                    onChanged: (val) {
                      v.name = val;
                      widget.onProjectUpdated();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  key: Key('fb_var_delete_$i'),
                  icon: const Icon(Icons.remove_circle, color: Colors.redAccent, size: 20),
                  tooltip: 'Remove Var',
                  onPressed: () => _deleteVar(v),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: Key('fb_var_type_$i'),
                    initialValue: currentType,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Type', isDense: true),
                    items: availableTypes
                        .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                        .toList(),
                    onChanged: (val) {
                      setState(() {
                        v.dataType = val!;
                        // Reset the stale default so it is recomputed for the
                        // new type (mirrors the struct-def field editor).
                        v.initialValue = null;
                      });
                      widget.onProjectUpdated();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButtonFormField<FbVarDir>(
                    key: Key('fb_var_dir_$i'),
                    initialValue: v.direction,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Direction', isDense: true),
                    items: FbVarDir.values
                        .map((d) => DropdownMenuItem(value: d, child: Text(d.name)))
                        .toList(),
                    onChanged: (val) {
                      setState(() => v.direction = val!);
                      widget.onProjectUpdated();
                    },
                  ),
                ),
              ],
            ),
            if (isScalar) ...[
              const SizedBox(height: 8),
              ScalarValueField(
                dataType: v.dataType,
                value: v.initialValue,
                onChanged: (val) {
                  v.initialValue = val;
                  widget.onProjectUpdated();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSidebar(BuildContext context) {
    final fbs = widget.currentProject.fbDefinitions;
    return Container(
      color: const Color(0xFF0F172A),
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('FUNCTION BLOCKS', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.grey)),
            ),
          ),
          Expanded(
            child: fbs.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Text('No function blocks yet.', style: TextStyle(fontSize: 12, color: Colors.grey)),
                  )
                : ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    children: fbs.map((fb) {
                      final isSelected = fb == _selected;
                      return Card(
                        color: isSelected ? Colors.cyan.withValues(alpha: 0.2) : const Color(0xFF1E293B),
                        child: ListTile(
                          dense: true,
                          title: Text(fb.name, style: TextStyle(fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
                          subtitle: Text('${fb.vars.length} vars', style: const TextStyle(fontSize: 10)),
                          onTap: () => _selectAndMaybeClose(context, fb),
                        ),
                      );
                    }).toList(),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: OutlinedButton.icon(
              key: const Key('fb_new_button'),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('New FB'),
              onPressed: _showAddFbDialog,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMainContent(FbDefinition fb) {
    return ListView(
      key: const Key('fb_editor_content'),
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(fb.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            ),
            IconButton(
              key: const Key('fb_rename_button'),
              icon: const Icon(Icons.edit, color: Colors.cyanAccent, size: 20),
              tooltip: 'Rename Function Block',
              onPressed: () => _showRenameFbDialog(fb),
            ),
          ],
        ),
        const Divider(height: 24),
        const Text('INTERFACE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.tealAccent)),
        const SizedBox(height: 8),
        for (final entry in fb.vars.asMap().entries) _buildVarRow(entry.key, entry.value),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('fb_add_var'),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add Var'),
            onPressed: _addVar,
          ),
        ),
        const Divider(height: 32),
        const Text('ST BODY', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.tealAccent)),
        const SizedBox(height: 8),
        SizedBox(
          height: 320,
          child: Container(
            padding: const EdgeInsets.all(8),
            color: const Color(0xFF0D1117),
            child: TextField(
              key: const Key('fb_st_body'),
              controller: _stController,
              maxLines: null,
              expands: true,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13, color: Color(0xFFE6EDE3), height: 1.5),
              decoration: const InputDecoration(
                border: InputBorder.none,
                hintText: '// Structured Text body for this Function Block...',
              ),
              onChanged: (val) {
                fb.stSource = val;
                widget.onProjectUpdated();
              },
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final expanded = context.isExpanded;
    final fb = _selected;
    return Scaffold(
      key: const Key('fb_editor'),
      appBar: AppBar(
        title: const Text('Function Blocks'),
        backgroundColor: const Color(0xFF1E293B),
      ),
      drawer: expanded ? null : Drawer(child: _buildSidebar(context)),
      body: Row(
        children: [
          if (expanded) ...[
            SizedBox(width: 280, child: _buildSidebar(context)),
            const VerticalDivider(width: 1, color: Colors.white12),
          ],
          Expanded(
            child: fb == null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('No function blocks defined yet.', style: TextStyle(color: Colors.grey)),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.add),
                          label: const Text('Create Function Block'),
                          onPressed: _showAddFbDialog,
                        ),
                      ],
                    ),
                  )
                : _buildMainContent(fb),
          ),
        ],
      ),
    );
  }
}
