import 'package:flutter/material.dart';
import '../models/project_model.dart';
import '../ui/responsive.dart';

class FbdEditorScreen extends StatefulWidget {
  final PlcProject currentProject;
  final PlcProgram program;
  final VoidCallback onProgramUpdated;

  const FbdEditorScreen({
    super.key,
    required this.currentProject,
    required this.program,
    required this.onProgramUpdated,
  });

  @override
  State<FbdEditorScreen> createState() => _FbdEditorScreenState();
}

class _FbdEditorScreenState extends State<FbdEditorScreen> {
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _ensureDefaultFbd();
  }

  void _ensureDefaultFbd() {
    if (widget.program.fbdBlocks.isEmpty) {
      widget.program.fbdBlocks.addAll([
        FbdBlock(id: 'b1', type: 'TAG_INPUT', title: 'Start Pushbutton', tagBinding: 'Start_PB', x: 50, y: 50),
        FbdBlock(id: 'b2', type: 'TAG_INPUT', title: 'Stop Pushbutton', tagBinding: 'Stop_PB', x: 50, y: 160),
        FbdBlock(id: 'b3', type: 'AND', title: 'AND Logic Gate', x: 280, y: 100),
        FbdBlock(id: 'b4', type: 'TAG_OUTPUT', title: 'Motor Output Solenoid', tagBinding: 'Motor_Run', x: 500, y: 100),
      ]);
    }
  }

  void _addFbdBlock(String type, String title) {
    String tag = widget.currentProject.tags.isNotEmpty ? widget.currentProject.tags.first.name : '';

    final newBlock = FbdBlock(
      id: 'b_${DateTime.now().millisecondsSinceEpoch}',
      type: type,
      title: title,
      tagBinding: tag,
      x: 150,
      y: 150,
    );

    setState(() {
      widget.program.fbdBlocks.add(newBlock);
    });
    widget.onProgramUpdated();
  }

  Widget _buildCanvas(bool expanded) {
    final stack = Stack(
      children: [
        // Grid Background Pattern
        const Positioned.fill(
          child: Opacity(
            opacity: 0.1,
            child: GridPaper(color: Colors.cyan, interval: 40),
          ),
        ),

        // FBD Blocks
        ...widget.program.fbdBlocks.map((block) {
          return Positioned(
            left: block.x,
            top: block.y,
            child: GestureDetector(
              onPanUpdate: expanded
                  ? (details) {
                      setState(() {
                        block.x += details.delta.dx;
                        block.y += details.delta.dy;
                      });
                      widget.onProgramUpdated();
                    }
                  : null,
              onTap: expanded ? null : () => _showConfigureBlockDialog(block),
              child: _buildFbdBlockCard(block, showInlineEditors: expanded),
            ),
          );
        }),
      ],
    );

    // Give the canvas a generously large logical area so pan/zoom on compact
    // has room to explore blocks placed far from the origin.
    final content = SizedBox(
      width: 1600,
      height: 1200,
      child: stack,
    );

    return Container(
      color: const Color(0xFF0F172A),
      child: expanded
          ? stack
          : InteractiveViewer(
              constrained: false,
              minScale: 0.4,
              maxScale: 2.5,
              boundaryMargin: const EdgeInsets.all(200),
              child: content,
            ),
    );
  }

  void _openPaletteSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      builder: (ctx) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.75,
            child: StatefulBuilder(
              builder: (context, setSheetState) => _buildPaletteDock(
                onChangedSearch: (v) => setSheetState(() => _searchQuery = v),
              ),
            ),
          ),
        );
      },
    );
  }

  void _showConfigureBlockDialog(FbdBlock block) {
    showAdaptiveWidthDialog(
      context,
      desiredWidth: 400,
      child: StatefulBuilder(
        builder: (context, setDlgState) => AlertDialog(
          title: Text('Configure: ${block.title}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Block Type: ${block.type}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 12),
              if (block.type.startsWith('TAG_'))
                DropdownButtonFormField<String>(
                  initialValue: block.tagBinding.isNotEmpty ? block.tagBinding : widget.currentProject.tags.first.name,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Tag Binding'),
                  items: widget.currentProject.tags.map((t) => DropdownMenuItem(value: t.name, child: Text(t.name))).toList(),
                  onChanged: (val) => setDlgState(() => block.tagBinding = val!),
                )
              else if (block.type == 'CONST')
                TextFormField(
                  initialValue: block.tagBinding,
                  decoration: const InputDecoration(labelText: 'Constant Value'),
                  onChanged: (val) => block.tagBinding = val,
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                setState(() => widget.program.fbdBlocks.removeWhere((b) => b.id == block.id));
                widget.onProgramUpdated();
                Navigator.pop(context);
              },
              child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
            ),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                setState(() {});
                widget.onProgramUpdated();
                Navigator.pop(context);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final expanded = context.isExpanded;

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.program.name} — Function Block Diagram (FBD) Editor'),
        backgroundColor: const Color(0xFF1E293B),
      ),
      floatingActionButton: expanded
          ? null
          : FloatingActionButton.extended(
              onPressed: _openPaletteSheet,
              icon: const Icon(Icons.add),
              label: const Text('Add block'),
            ),
      body: expanded
          ? Row(
              children: [
                // CENTER WORKSPACE: Signal Flow Block Canvas
                Expanded(child: _buildCanvas(true)),

                const VerticalDivider(width: 1, color: Colors.white12),

                // RIGHT DOCK: FBD Function Block Autocomplete Palette
                _buildPaletteDock(onChangedSearch: (v) => setState(() => _searchQuery = v)),
              ],
            )
          : _buildCanvas(false),
    );
  }

  Widget _buildPaletteDock({required ValueChanged<String> onChangedSearch}) {
    return Container(
      width: 260,
      color: const Color(0xFF0F172A),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            color: const Color(0xFF1E293B),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('FBD FUNCTION BLOCK PALETTE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.tealAccent)),
                const SizedBox(height: 8),
                TextField(
                  onChanged: onChangedSearch,
                  decoration: const InputDecoration(
                    hintText: 'Search blocks...',
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 16),
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(8),
              children: [
                _buildBlockPaletteItem('AND', 'AND Logic Gate', Icons.call_split, Colors.blueAccent),
                _buildBlockPaletteItem('OR', 'OR Logic Gate', Icons.alt_route, Colors.purpleAccent),
                _buildBlockPaletteItem('NOT', 'NOT Inverter Gate', Icons.do_not_disturb_on, Colors.redAccent),
                _buildBlockPaletteItem('TON', 'Timer On Delay Block', Icons.timer, Colors.amberAccent),
                _buildBlockPaletteItem('LIMIT', 'Limit Clamp (Min, In, Max)', Icons.tune, Colors.orangeAccent),
                _buildBlockPaletteItem('CONST', 'Constant Value', Icons.pin, Colors.limeAccent),
                _buildBlockPaletteItem('ADD', 'Add (+)', Icons.add, Colors.tealAccent),
                _buildBlockPaletteItem('SUB', 'Subtract (-)', Icons.remove, Colors.tealAccent),
                _buildBlockPaletteItem('MUL', 'Multiply (x)', Icons.close, Colors.tealAccent),
                _buildBlockPaletteItem('DIV', 'Divide (/)', Icons.percent, Colors.tealAccent),
                _buildBlockPaletteItem('GT', 'Greater Than (>)', Icons.chevron_right, Colors.lightBlueAccent),
                _buildBlockPaletteItem('LT', 'Less Than (<)', Icons.chevron_left, Colors.lightBlueAccent),
                _buildBlockPaletteItem('GE', 'Greater or Equal (>=)', Icons.keyboard_double_arrow_right, Colors.lightBlueAccent),
                _buildBlockPaletteItem('LE', 'Less or Equal (<=)', Icons.keyboard_double_arrow_left, Colors.lightBlueAccent),
                _buildBlockPaletteItem('EQ', 'Equal (=)', Icons.drag_handle, Colors.lightBlueAccent),
                _buildBlockPaletteItem('NE', 'Not Equal (<>)', Icons.compare_arrows, Colors.lightBlueAccent),
                _buildBlockPaletteItem('TAG_INPUT', 'Tag Input Pin', Icons.login, Colors.greenAccent),
                _buildBlockPaletteItem('TAG_OUTPUT', 'Tag Output Pin', Icons.logout, Colors.cyanAccent),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBlockPaletteItem(String type, String title, IconData icon, Color color) {
    if (_searchQuery.isNotEmpty && !title.toLowerCase().contains(_searchQuery.toLowerCase())) {
      return const SizedBox.shrink();
    }

    return Card(
      color: const Color(0xFF1E293B),
      margin: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: ListTile(
          dense: true,
          leading: Icon(icon, color: color, size: 18),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
          subtitle: Text('Type: $type', style: const TextStyle(fontSize: 10, color: Colors.grey)),
          trailing: IconButton(
            icon: const Icon(Icons.add, color: Colors.tealAccent, size: 18),
            onPressed: () {
              _addFbdBlock(type, title);
              if (!context.isExpanded && Navigator.of(context).canPop()) {
                Navigator.of(context).pop();
              }
            },
          ),
        ),
      ),
    );
  }

  Widget _buildFbdBlockCard(FbdBlock block, {bool showInlineEditors = true}) {
    Color color = Colors.blueAccent;
    if (block.type == 'TAG_INPUT') color = Colors.greenAccent;
    if (block.type == 'TAG_OUTPUT') color = Colors.amberAccent;
    if (block.type == 'TON') color = Colors.purpleAccent;

    return Container(
      width: 180,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color, width: 2),
        boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 8)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.drag_indicator, size: 16, color: color),
              const SizedBox(width: 4),
              Expanded(child: Text(block.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12))),
              if (showInlineEditors)
                IconButton(
                  icon: const Icon(Icons.close, size: 14, color: Colors.redAccent),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () {
                    setState(() {
                      widget.program.fbdBlocks.removeWhere((b) => b.id == block.id);
                    });
                    widget.onProgramUpdated();
                  },
                ),
            ],
          ),
          const Divider(height: 12),

          if (!showInlineEditors)
            Text('Block Function: ${block.type}\n${block.tagBinding.isNotEmpty ? "Tag/Value: ${block.tagBinding}" : ""}',
                style: const TextStyle(fontSize: 10, color: Colors.grey))
          else if (block.type.startsWith('TAG_'))
            DropdownButtonFormField<String>(
              initialValue: block.tagBinding.isNotEmpty ? block.tagBinding : widget.currentProject.tags.first.name,
              isDense: true,
              isExpanded: true, // fill the card width and ellipsize long tag names
              style: const TextStyle(fontSize: 11, color: Colors.white),
              decoration: const InputDecoration(isDense: true, border: InputBorder.none),
              items: widget.currentProject.tags.map((t) => DropdownMenuItem(value: t.name, child: Text(t.name, overflow: TextOverflow.ellipsis))).toList(),
              onChanged: (val) {
                setState(() => block.tagBinding = val!);
                widget.onProgramUpdated();
              },
            )
          else if (block.type == 'CONST')
            TextFormField(
              initialValue: block.tagBinding,
              style: const TextStyle(fontSize: 11, color: Colors.white),
              decoration: const InputDecoration(isDense: true, border: InputBorder.none, labelText: 'Value'),
              onChanged: (val) {
                block.tagBinding = val;
                widget.onProgramUpdated();
              },
            )
          else
            Text('Block Function: ${block.type}', style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ],
      ),
    );
  }
}
