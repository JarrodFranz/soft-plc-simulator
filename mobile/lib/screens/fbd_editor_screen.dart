import 'package:flutter/material.dart';
import '../models/project_model.dart';

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.program.name} — Function Block Diagram (FBD) Editor'),
        backgroundColor: const Color(0xFF1E293B),
      ),
      body: Row(
        children: [
          // CENTER WORKSPACE: Signal Flow Block Canvas
          Expanded(
            child: Container(
              color: const Color(0xFF0F172A),
              child: Stack(
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
                        onPanUpdate: (details) {
                          setState(() {
                            block.x += details.delta.dx;
                            block.y += details.delta.dy;
                          });
                          widget.onProgramUpdated();
                        },
                        child: _buildFbdBlockCard(block),
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),

          const VerticalDivider(width: 1, color: Colors.white12),

          // RIGHT DOCK: FBD Function Block Autocomplete Palette
          Container(
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
                        onChanged: (v) => setState(() => _searchQuery = v),
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
            onPressed: () => _addFbdBlock(type, title),
          ),
        ),
      ),
    );
  }

  Widget _buildFbdBlockCard(FbdBlock block) {
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

          if (block.type.startsWith('TAG_'))
            DropdownButtonFormField<String>(
              initialValue: block.tagBinding.isNotEmpty ? block.tagBinding : widget.currentProject.tags.first.name,
              isDense: true,
              style: const TextStyle(fontSize: 11, color: Colors.white),
              decoration: const InputDecoration(isDense: true, border: InputBorder.none),
              items: widget.currentProject.tags.map((t) => DropdownMenuItem(value: t.name, child: Text(t.name))).toList(),
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
