import 'package:flutter/material.dart';
import '../models/fbd_pins.dart';
import '../models/fbd_layout.dart';
import '../models/fbd_networks.dart';
import '../models/project_model.dart';
import '../ui/responsive.dart';
import '../widgets/tag_autocomplete_field.dart';

const double _kBlockWidth = 180;
// Roomy enough that the 44px pin-dot touch targets don't crowd each other on a
// dense multi-input block at phone widths.
const double _kPinRowHeight = 30;
const double _kHeaderHeight = 40; // icon row + divider, approx.

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

  // Wiring interaction state.
  String? _armedBlockId;
  String? _armedPin;

  // Wire selection state (for delete).
  int? _selectedWireIndex;

  // Comment-field controllers, keyed by the FbdNetwork instance (stable across
  // reorders — `moveFbdNetwork` shuffles the list but keeps the same objects).
  final Map<FbdNetwork, TextEditingController> _commentControllers = {};

  @override
  void initState() {
    super.initState();
    _ensureDefaultFbd();
    _ensureNetworks();
  }

  @override
  void dispose() {
    for (final c in _commentControllers.values) {
      c.dispose();
    }
    super.dispose();
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

  /// Guarantees at least one network lane exists and that every block's
  /// `network` index has a backing header (a directly-constructed program
  /// whose blocks were added after construction may have an empty
  /// `fbdNetworks`). Never notifies — this only backfills structure.
  void _ensureNetworks() {
    final maxNet = widget.program.fbdBlocks
        .fold<int>(-1, (m, b) => b.network > m ? b.network : m);
    final needed = maxNet + 1 < 1 ? 1 : maxNet + 1;
    while (widget.program.fbdNetworks.length < needed) {
      widget.program.fbdNetworks.add(FbdNetwork());
    }
  }

  TextEditingController _commentController(FbdNetwork n) {
    return _commentControllers.putIfAbsent(
        n, () => TextEditingController(text: n.comment));
  }

  FbdBlock? _blockById(String id) {
    for (final b in widget.program.fbdBlocks) {
      if (b.id == id) return b;
    }
    return null;
  }

  void _addFbdBlock(String type, String title, {int network = 0}) {
    String tag = widget.currentProject.tags.isNotEmpty ? widget.currentProject.tags.first.name : '';
    final netCount = widget.program.fbdNetworks.length;
    final targetNet = (network >= 0 && network < netCount) ? network : 0;

    final newBlock = FbdBlock(
      id: 'b_${DateTime.now().millisecondsSinceEpoch}',
      type: type,
      title: title,
      tagBinding: tag,
      x: 150,
      y: 150,
      network: targetNet,
    );

    setState(() {
      widget.program.fbdBlocks.add(newBlock);
    });
    widget.onProgramUpdated();
  }

  // -----------------------------------------------------------------
  // Network CRUD (consumes the pure fbd_networks.dart helpers)
  // -----------------------------------------------------------------

  void _addNetwork() {
    setState(() => addFbdNetwork(widget.program));
    widget.onProgramUpdated();
  }

  void _moveNetwork(int from, int to) {
    setState(() => moveFbdNetwork(widget.program, from, to));
    widget.onProgramUpdated();
  }

  void _confirmDeleteNetwork(int net) {
    showAdaptiveWidthDialog(
      context,
      desiredWidth: 360,
      child: AlertDialog(
        title: Text('Delete Network ${net + 1}?'),
        content: const Text(
            'This removes the network and every block and wire inside it. '
            'This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            key: const Key('fbd_net_del_confirm'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                deleteFbdNetwork(widget.program, net);
                _selectedWireIndex = null;
                _armedBlockId = null;
                _armedPin = null;
              });
              _ensureNetworks();
              widget.onProgramUpdated();
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  // -----------------------------------------------------------------
  // Wiring helpers
  // -----------------------------------------------------------------

  void _cancelArm() {
    if (_armedBlockId != null || _armedPin != null) {
      setState(() {
        _armedBlockId = null;
        _armedPin = null;
      });
    }
  }

  void _selectWire(int? index) {
    setState(() => _selectedWireIndex = index);
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  void _onOutputTap(String blockId, String pin) {
    setState(() {
      _selectedWireIndex = null;
      if (_armedBlockId == blockId && _armedPin == pin) {
        // Tapping the same armed output again cancels the arm.
        _armedBlockId = null;
        _armedPin = null;
      } else {
        _armedBlockId = blockId;
        _armedPin = pin;
      }
    });
  }

  void _onInputTap(String blockId, String pin) {
    if (_armedBlockId == null || _armedPin == null) {
      // No output armed: nothing to do (no-op).
      setState(() => _selectedWireIndex = null);
      return;
    }
    _completeWire(toBlockId: blockId, toPin: pin);
  }

  void _completeWire({required String toBlockId, required String toPin}) {
    final fromBlockId = _armedBlockId!;
    final fromPin = _armedPin!;

    if (fromBlockId == toBlockId) {
      _showSnack('Cannot wire a block to itself.');
      _cancelArm();
      return;
    }

    // Wiring is confined to a single network lane: both endpoints must live in
    // the same network. This closes the runtime "cross-network wire" gap at the
    // source — the editor never lets a user draw one.
    final fromBlock = _blockById(fromBlockId);
    final toBlock = _blockById(toBlockId);
    if (fromBlock == null || toBlock == null || fromBlock.network != toBlock.network) {
      _showSnack('Wires must stay within one network.');
      _cancelArm();
      return;
    }

    setState(() {
      // An input takes at most one wire: replace any existing wire to this pin.
      widget.program.fbdWires.removeWhere((w) => w.toBlockId == toBlockId && w.toPin == toPin);
      widget.program.fbdWires.add(FbdWire(
        fromBlockId: fromBlockId,
        fromPin: fromPin,
        toBlockId: toBlockId,
        toPin: toPin,
      ));
      _armedBlockId = null;
      _armedPin = null;
      _selectedWireIndex = null;
    });
    widget.onProgramUpdated();
  }

  void _deleteWire(int index) {
    setState(() {
      widget.program.fbdWires.removeAt(index);
      _selectedWireIndex = null;
    });
    widget.onProgramUpdated();
  }

  void _deleteBlock(FbdBlock block) {
    setState(() {
      widget.program.fbdBlocks.removeWhere((b) => b.id == block.id);
      widget.program.fbdWires.removeWhere((w) => w.fromBlockId == block.id || w.toBlockId == block.id);
      if (_armedBlockId == block.id) {
        _armedBlockId = null;
        _armedPin = null;
      }
      _selectedWireIndex = null;
    });
    widget.onProgramUpdated();
  }

  void _changeInputCount(FbdBlock block, int delta) {
    final newCount = (block.inputCount + delta).clamp(2, 8);
    if (newCount == block.inputCount) return;
    setState(() {
      block.inputCount = newCount;
      final validPins = fbdInputPins(block.type, inputCount: block.inputCount).toSet();
      widget.program.fbdWires.removeWhere((w) => w.toBlockId == block.id && !validPins.contains(w.toPin));
      _selectedWireIndex = null;
    });
    widget.onProgramUpdated();
  }

  static bool _typeIsExtensible(String type) => type == 'AND' || type == 'OR' || type == 'ADD' || type == 'MUL';

  Color _pinColor(String pin) {
    // Light type hint: BOOL-ish pins (EN/Q/G/IN on binary gates) vs numeric.
    const boolPins = {'Q', 'G', 'EN', 'ENO'};
    if (boolPins.contains(pin)) return Colors.tealAccent;
    return Colors.lightBlueAccent;
  }

  // -----------------------------------------------------------------
  // Lane list + per-network canvas
  // -----------------------------------------------------------------

  /// The vertical stack of network lanes — one bounded pan/zoom canvas per
  /// `program.fbdNetworks` entry — plus a trailing "+ Network" button. This is
  /// the whole editor body (wrapped in an Expanded next to the palette dock on
  /// desktop).
  Widget _buildLaneList(bool expanded) {
    final nets = widget.program.fbdNetworks;
    return Container(
      color: const Color(0xFF0F172A),
      child: ListView(
        padding: const EdgeInsets.all(8),
        children: [
          for (var i = 0; i < nets.length; i++) _buildLane(i, expanded),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const Key('fbd_add_network'),
              onPressed: _addNetwork,
              icon: const Icon(Icons.add),
              label: const Text('Network'),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildLane(int net, bool expanded) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white12),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildNetworkHeader(net),
          SizedBox(
            height: _laneCanvasHeight(net),
            child: _buildLaneCanvas(net, expanded),
          ),
        ],
      ),
    );
  }

  /// A bounded viewport height sized to comfortably contain this network's
  /// blocks (so nothing important sits clipped off-stage), clamped to a sane
  /// range. Panning still reaches the full 1600×1200 logical canvas.
  double _laneCanvasHeight(int net) {
    var maxY = 0.0;
    for (final b in fbdBlocksInNetwork(widget.program, net)) {
      if (b.y > maxY) maxY = b.y;
    }
    // + a generous block-card allowance so a block near the bottom is fully in
    // view (header row + pins + footer editors).
    return (maxY + 220).clamp(260.0, 1200.0);
  }

  Widget _buildNetworkHeader(int net) {
    final n = widget.program.fbdNetworks.length;
    final network = widget.program.fbdNetworks[net];
    Widget iconBtn(String keySuffix, IconData icon, String tooltip, VoidCallback? onPressed) {
      // Shrink-wrapped tap target (not the default 48px) so five buttons plus
      // the label + comment field still fit a 320px-wide phone header.
      return IconButton(
        key: Key('fbd_net_${keySuffix}_$net'),
        icon: Icon(icon, size: 18),
        tooltip: tooltip,
        style: IconButton.styleFrom(
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          minimumSize: const Size(32, 36),
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
        ),
        onPressed: onPressed,
      );
    }

    return Container(
      key: Key('fbd_network_header_$net'),
      color: const Color(0xFF1E293B),
      padding: const EdgeInsets.fromLTRB(8, 2, 2, 2),
      child: Row(
        children: [
          Flexible(
            child: Text(
              'Network ${net + 1}',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 12,
                color: Colors.tealAccent,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              key: Key('fbd_network_comment_$net'),
              controller: _commentController(network),
              style: const TextStyle(fontSize: 12),
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Comment…',
                border: InputBorder.none,
              ),
              onChanged: (v) {
                network.comment = v;
                widget.onProgramUpdated();
              },
            ),
          ),
          iconBtn('addblock', Icons.add_box_outlined, 'Add block to this network',
              () => _openPaletteSheet(network: net)),
          iconBtn('arrange', Icons.auto_awesome_mosaic, 'Auto-arrange this network',
              () => _autoArrangeNetwork(net)),
          iconBtn('up', Icons.arrow_upward, 'Move network up',
              net > 0 ? () => _moveNetwork(net, net - 1) : null),
          iconBtn('down', Icons.arrow_downward, 'Move network down',
              net < n - 1 ? () => _moveNetwork(net, net + 1) : null),
          iconBtn('del', Icons.delete_outline, 'Delete network',
              () => _confirmDeleteNetwork(net)),
        ],
      ),
    );
  }

  Widget _buildLaneCanvas(int net, bool expanded) {
    // Local anchor cache for THIS lane only: 'blockId|IN|pin' / 'blockId|OUT|pin'
    // -> offset within the lane's 1600×1200 canvas content. Kept local (not a
    // shared field) so sibling lanes never clobber each other's anchors.
    final anchors = <String, Offset>{};
    final blocks = fbdBlocksInNetwork(widget.program, net);

    final blockWidgets = blocks.map((block) {
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
    }).toList();

    // Pre-compute pin anchors for the painter (after blocks are laid out with
    // known positions/sizes, purely arithmetic — no need to wait for a frame).
    for (final block in blocks) {
      final inputs = fbdInputPins(block.type, inputCount: block.inputCount);
      final outputs = fbdOutputPins(block.type);
      for (var i = 0; i < inputs.length; i++) {
        final dy = _kHeaderHeight + i * _kPinRowHeight + _kPinRowHeight / 2;
        anchors['${block.id}|IN|${inputs[i]}'] = Offset(block.x, block.y + dy);
      }
      for (var i = 0; i < outputs.length; i++) {
        final dy = _kHeaderHeight + i * _kPinRowHeight + _kPinRowHeight / 2;
        anchors['${block.id}|OUT|${outputs[i]}'] = Offset(block.x + _kBlockWidth, block.y + dy);
      }
    }

    final stack = Stack(
      children: [
        // Grid Background Pattern
        const Positioned.fill(
          child: Opacity(
            opacity: 0.1,
            child: GridPaper(color: Colors.cyan, interval: 40),
          ),
        ),

        // Wires painted beneath the blocks so block cards remain tappable. Only
        // wires whose BOTH endpoints resolve to anchors in THIS lane draw here;
        // any cross-lane wire is simply skipped by the painter.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () {
              if (_armedBlockId != null) {
                _cancelArm();
              } else if (_selectedWireIndex != null) {
                _selectWire(null);
              }
            },
            child: CustomPaint(
              painter: _WirePainter(
                wires: widget.program.fbdWires,
                anchors: anchors,
                selectedIndex: _selectedWireIndex,
              ),
            ),
          ),
        ),

        // Tap targets over each wire midpoint for selection (simple circular
        // hit areas placed at the wire midpoint).
        ..._buildWireHitTargets(anchors),

        // FBD Blocks
        ...blockWidgets,
      ],
    );

    // Give the canvas a generously large logical area so pan/zoom has room to
    // explore blocks placed far from the origin.
    final content = SizedBox(
      width: 1600,
      height: 1200,
      child: stack,
    );

    // The lane pans/zooms on every platform. On desktop (expanded) individual
    // blocks stay draggable via their own pan handler — dragging a block moves
    // the block, dragging the empty background pans the canvas.
    return Container(
      color: const Color(0xFF0F172A),
      child: InteractiveViewer(
        constrained: false,
        minScale: 0.4,
        maxScale: 2.5,
        boundaryMargin: const EdgeInsets.all(400),
        child: content,
      ),
    );
  }

  List<Widget> _buildWireHitTargets(Map<String, Offset> anchors) {
    final widgets = <Widget>[];
    for (var i = 0; i < widget.program.fbdWires.length; i++) {
      final w = widget.program.fbdWires[i];
      final from = anchors['${w.fromBlockId}|OUT|${w.fromPin}'];
      final to = anchors['${w.toBlockId}|IN|${w.toPin}'];
      if (from == null || to == null) continue;
      final mid = Offset((from.dx + to.dx) / 2, (from.dy + to.dy) / 2);
      widgets.add(Positioned(
        left: mid.dx - 16,
        top: mid.dy - 16,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _selectWire(_selectedWireIndex == i ? null : i),
          child: Container(
            key: Key('fbdwire_$i'),
            width: 32,
            height: 32,
            alignment: Alignment.center,
            child: _selectedWireIndex == i
                ? GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _deleteWire(i),
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle),
                      child: const Icon(Icons.close, size: 14, color: Colors.white),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ));
    }
    return widgets;
  }

  void _openPaletteSheet({int network = 0}) {
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
                targetNetwork: network,
              ),
            ),
          ),
        );
      },
    );
  }

  void _showConfigureBlockDialog(FbdBlock block) {
    // Local pending edits so the tag binding / const value only commit
    // (and trigger `onProgramUpdated`) when the dialog is saved, not on
    // every keystroke.
    String pendingTagBinding = block.tagBinding;
    String pendingTitle = block.title;

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
              TextFormField(
                initialValue: block.title,
                decoration: const InputDecoration(labelText: 'Block name'),
                onChanged: (val) => pendingTitle = val,
              ),
              const SizedBox(height: 12),
              if (block.type.startsWith('TAG_'))
                TagAutocompleteField(
                  options: widget.currentProject.tags.map((t) => t.name).toList(),
                  initialValue: pendingTagBinding.isNotEmpty ? pendingTagBinding : (widget.currentProject.tags.isNotEmpty ? widget.currentProject.tags.first.name : ''),
                  label: 'Tag Binding',
                  onChanged: (val) => pendingTagBinding = val,
                )
              else if (block.type == 'CONST')
                TextFormField(
                  initialValue: pendingTagBinding,
                  decoration: const InputDecoration(labelText: 'Constant Value'),
                  onChanged: (val) => pendingTagBinding = val,
                ),
              if (_typeIsExtensible(block.type)) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('Inputs:', style: TextStyle(fontSize: 12, color: Colors.grey)),
                    const SizedBox(width: 8),
                    touchable(
                      const Icon(Icons.remove_circle_outline, size: 20),
                      onTap: () => setDlgState(() => _changeInputCount(block, -1)),
                    ),
                    Text('${block.inputCount}', style: const TextStyle(fontWeight: FontWeight.bold)),
                    touchable(
                      const Icon(Icons.add_circle_outline, size: 20),
                      onTap: () => setDlgState(() => _changeInputCount(block, 1)),
                    ),
                  ],
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                _deleteBlock(block);
                Navigator.pop(context);
              },
              child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
            ),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  block.tagBinding = pendingTagBinding;
                  block.title = pendingTitle.trim().isEmpty ? block.title : pendingTitle.trim();
                });
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

  /// Re-lays ALL blocks into tidy dependency-ordered columns with generous
  /// spacing (non-destructive — blocks stay free-draggable afterward).
  void _autoArrangeBlocks() {
    _applyLayout(autoArrangeFbd(widget.program));
  }

  /// Re-lays only network [net]'s blocks — the per-lane arrange affordance.
  void _autoArrangeNetwork(int net) {
    _applyLayout(autoArrangeFbdNetwork(widget.program, net));
  }

  void _applyLayout(Map<String, ({double x, double y})> layout) {
    if (layout.isEmpty) {
      return;
    }
    setState(() {
      for (final b in widget.program.fbdBlocks) {
        final pos = layout[b.id];
        if (pos != null) {
          b.x = pos.x;
          b.y = pos.y;
        }
      }
    });
    widget.onProgramUpdated();
  }

  @override
  Widget build(BuildContext context) {
    final expanded = context.isExpanded;
    final short = context.isShort;

    return Scaffold(
      appBar: AppBar(
        title: Text(short
            ? '${widget.program.name} (FBD)'
            : '${widget.program.name} — Function Block Diagram (FBD) Editor'),
        backgroundColor: const Color(0xFF1E293B),
        toolbarHeight: short ? 46 : null,
        actions: [
          IconButton(
            tooltip: 'Auto-arrange blocks',
            icon: const Icon(Icons.auto_awesome_mosaic),
            onPressed: _autoArrangeBlocks,
          ),
        ],
      ),
      floatingActionButton: expanded
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _openPaletteSheet(network: 0),
              icon: const Icon(Icons.add),
              label: const Text('Add block'),
            ),
      body: expanded
          ? Row(
              children: [
                // CENTER WORKSPACE: vertical stack of network lanes.
                Expanded(child: _buildLaneList(true)),

                const VerticalDivider(width: 1, color: Colors.white12),

                // RIGHT DOCK: FBD Function Block Autocomplete Palette. Adds
                // land in the first network; per-lane add buttons target any.
                _buildPaletteDock(
                  onChangedSearch: (v) => setState(() => _searchQuery = v),
                  targetNetwork: 0,
                ),
              ],
            )
          : _buildLaneList(false),
    );
  }

  Widget _buildPaletteDock({
    required ValueChanged<String> onChangedSearch,
    required int targetNetwork,
  }) {
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
                _buildBlockPaletteItem('AND', 'AND Logic Gate', Icons.call_split, Colors.blueAccent, targetNetwork),
                _buildBlockPaletteItem('OR', 'OR Logic Gate', Icons.alt_route, Colors.purpleAccent, targetNetwork),
                _buildBlockPaletteItem('NOT', 'NOT Inverter Gate', Icons.do_not_disturb_on, Colors.redAccent, targetNetwork),
                _buildBlockPaletteItem('TON', 'Timer On Delay Block', Icons.timer, Colors.amberAccent, targetNetwork),
                _buildBlockPaletteItem('PID', 'PID Controller', Icons.speed, Colors.pinkAccent, targetNetwork),
                _buildBlockPaletteItem('CTU', 'Count Up', Icons.exposure_plus_1, Colors.amberAccent, targetNetwork),
                _buildBlockPaletteItem('CTD', 'Count Down', Icons.exposure_neg_1, Colors.amberAccent, targetNetwork),
                _buildBlockPaletteItem('CTUD', 'Up/Down Counter', Icons.swap_vert, Colors.amberAccent, targetNetwork),
                _buildBlockPaletteItem('R_TRIG', 'Rising Edge (R_TRIG)', Icons.trending_up, Colors.amberAccent, targetNetwork),
                _buildBlockPaletteItem('F_TRIG', 'Falling Edge (F_TRIG)', Icons.trending_down, Colors.amberAccent, targetNetwork),
                _buildBlockPaletteItem('TP', 'Pulse Timer (TP)', Icons.bolt, Colors.amberAccent, targetNetwork),
                _buildBlockPaletteItem('LIMIT', 'Limit Clamp (Min, In, Max)', Icons.tune, Colors.orangeAccent, targetNetwork),
                _buildBlockPaletteItem('CONST', 'Constant Value', Icons.pin, Colors.limeAccent, targetNetwork),
                _buildBlockPaletteItem('ADD', 'Add (+)', Icons.add, Colors.tealAccent, targetNetwork),
                _buildBlockPaletteItem('SUB', 'Subtract (-)', Icons.remove, Colors.tealAccent, targetNetwork),
                _buildBlockPaletteItem('MUL', 'Multiply (x)', Icons.close, Colors.tealAccent, targetNetwork),
                _buildBlockPaletteItem('DIV', 'Divide (/)', Icons.percent, Colors.tealAccent, targetNetwork),
                _buildBlockPaletteItem('GT', 'Greater Than (>)', Icons.chevron_right, Colors.lightBlueAccent, targetNetwork),
                _buildBlockPaletteItem('LT', 'Less Than (<)', Icons.chevron_left, Colors.lightBlueAccent, targetNetwork),
                _buildBlockPaletteItem('GE', 'Greater or Equal (>=)', Icons.keyboard_double_arrow_right, Colors.lightBlueAccent, targetNetwork),
                _buildBlockPaletteItem('LE', 'Less or Equal (<=)', Icons.keyboard_double_arrow_left, Colors.lightBlueAccent, targetNetwork),
                _buildBlockPaletteItem('EQ', 'Equal (=)', Icons.drag_handle, Colors.lightBlueAccent, targetNetwork),
                _buildBlockPaletteItem('NE', 'Not Equal (<>)', Icons.compare_arrows, Colors.lightBlueAccent, targetNetwork),
                _buildBlockPaletteItem('TAG_INPUT', 'Tag Input Pin', Icons.login, Colors.greenAccent, targetNetwork),
                _buildBlockPaletteItem('TAG_OUTPUT', 'Tag Output Pin', Icons.logout, Colors.cyanAccent, targetNetwork),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBlockPaletteItem(String type, String title, IconData icon, Color color, int targetNetwork) {
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
              _addFbdBlock(type, title, network: targetNetwork);
              if (!context.isExpanded && Navigator.of(context).canPop()) {
                Navigator.of(context).pop();
              }
            },
          ),
        ),
      ),
    );
  }

  Widget _buildPinDot(FbdBlock block, String pin, {required bool isInput}) {
    final color = _pinColor(pin);
    final armed = !isInput && _armedBlockId == block.id && _armedPin == pin;
    final key = Key('fbdpin_${block.id}_${isInput ? 'in' : 'out'}_$pin');

    final dot = Container(
      key: key,
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: armed ? Colors.white : color,
        shape: BoxShape.circle,
        border: Border.all(color: armed ? Colors.orangeAccent : Colors.black45, width: armed ? 2 : 1),
      ),
    );

    void onTap() {
      if (isInput) {
        _onInputTap(block.id, pin);
      } else {
        _onOutputTap(block.id, pin);
      }
    }

    Widget dotWidget = touchable(dot, onTap: onTap);

    // Desktop: also support drag-from-output to input, alongside tap-tap.
    if (context.isExpanded) {
      if (isInput) {
        dotWidget = DragTarget<Map<String, String>>(
          onWillAcceptWithDetails: (details) => details.data['blockId'] != block.id,
          onAcceptWithDetails: (details) {
            setState(() {
              _armedBlockId = details.data['blockId'];
              _armedPin = details.data['pin'];
            });
            _completeWire(toBlockId: block.id, toPin: pin);
          },
          builder: (context, candidateData, rejectedData) => touchable(dot, onTap: onTap),
        );
      } else {
        dotWidget = Draggable<Map<String, String>>(
          data: {'blockId': block.id, 'pin': pin},
          feedback: Material(color: Colors.transparent, child: dot),
          childWhenDragging: Opacity(opacity: 0.4, child: touchable(dot, onTap: onTap)),
          onDragStarted: () => setState(() {
            _armedBlockId = block.id;
            _armedPin = pin;
          }),
          child: touchable(dot, onTap: onTap),
        );
      }
    }

    Widget row = Row(
      mainAxisSize: MainAxisSize.min,
      children: isInput
          ? [
              dotWidget,
              const SizedBox(width: 2),
              Text(pin, style: const TextStyle(fontSize: 9, color: Colors.grey)),
            ]
          : [
              Text(pin, style: const TextStyle(fontSize: 9, color: Colors.grey)),
              const SizedBox(width: 2),
              dotWidget,
            ],
    );

    return SizedBox(height: _kPinRowHeight, child: row);
  }

  Widget _buildFbdBlockCard(FbdBlock block, {bool showInlineEditors = true}) {
    Color color = Colors.blueAccent;
    if (block.type == 'TAG_INPUT') color = Colors.greenAccent;
    if (block.type == 'TAG_OUTPUT') color = Colors.amberAccent;
    if (block.type == 'TON') color = Colors.purpleAccent;

    final inputs = fbdInputPins(block.type, inputCount: block.inputCount);
    final outputs = fbdOutputPins(block.type);
    final maxPinRows = inputs.length > outputs.length ? inputs.length : outputs.length;
    final extensible = _typeIsExtensible(block.type);

    return GestureDetector(
      // Only claim the tap gesture in expanded/inline mode (where the outer
      // card GestureDetector's onTap is null and drag is enabled). In
      // non-expanded (phone) mode this must stay null so the outer
      // Positioned > GestureDetector's onTap (opens the configure dialog)
      // wins the gesture arena instead of being shadowed by this inner one.
      onTap: showInlineEditors
          ? () {
              if (_selectedWireIndex != null) _selectWire(null);
            }
          : null,
      child: Container(
        width: _kBlockWidth,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color, width: 2),
          boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 8)],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.drag_indicator, size: 16, color: color),
                const SizedBox(width: 4),
                Expanded(child: Text(block.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12), overflow: TextOverflow.ellipsis)),
                if (showInlineEditors)
                  IconButton(
                    icon: const Icon(Icons.close, size: 14, color: Colors.redAccent),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () => _deleteBlock(block),
                  ),
              ],
            ),
            const Divider(height: 10),

            // Pin rows: input names/dots on the left, output names/dots on
            // the right, aligned by row index.
            for (var i = 0; i < maxPinRows; i++)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  i < inputs.length ? _buildPinDot(block, inputs[i], isInput: true) : const SizedBox(height: _kPinRowHeight),
                  i < outputs.length ? _buildPinDot(block, outputs[i], isInput: false) : const SizedBox(height: _kPinRowHeight),
                ],
              ),

            if (extensible)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('Inputs', style: TextStyle(fontSize: 9, color: Colors.grey)),
                  touchable(
                    const Icon(Icons.remove_circle_outline, size: 16),
                    onTap: () => _changeInputCount(block, -1),
                  ),
                  Text('${block.inputCount}', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                  touchable(
                    const Icon(Icons.add_circle_outline, size: 16),
                    onTap: () => _changeInputCount(block, 1),
                  ),
                ],
              ),

            const SizedBox(height: 2),
            if (!showInlineEditors)
              Text(
                'Block Function: ${block.type}\n${block.tagBinding.isNotEmpty ? "Tag/Value: ${block.tagBinding}" : ""}',
                style: const TextStyle(fontSize: 10, color: Colors.grey),
              )
            else if (block.type.startsWith('TAG_') || block.type == 'CONST')
              Row(
                children: [
                  Expanded(
                    child: Text(
                      block.tagBinding.isNotEmpty ? block.tagBinding : '(unset)',
                      style: const TextStyle(fontSize: 10, color: Colors.grey),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  touchable(
                    const Icon(Icons.edit, size: 14, color: Colors.tealAccent),
                    onTap: () => _showConfigureBlockDialog(block),
                  ),
                ],
              )
            else
              Text('Block Function: ${block.type}', style: const TextStyle(fontSize: 10, color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}

/// Paints straight lines between each wire's source output-pin anchor and
/// target input-pin anchor. The selected wire (if any) is highlighted.
class _WirePainter extends CustomPainter {
  final List<FbdWire> wires;
  final Map<String, Offset> anchors;
  final int? selectedIndex;

  _WirePainter({required this.wires, required this.anchors, required this.selectedIndex});

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < wires.length; i++) {
      final w = wires[i];
      final from = anchors['${w.fromBlockId}|OUT|${w.fromPin}'];
      final to = anchors['${w.toBlockId}|IN|${w.toPin}'];
      if (from == null || to == null) continue;

      final selected = selectedIndex == i;
      final paint = Paint()
        ..color = selected ? Colors.orangeAccent : Colors.tealAccent.withValues(alpha: 0.8)
        ..strokeWidth = selected ? 3 : 2
        ..style = PaintingStyle.stroke;

      final path = Path()..moveTo(from.dx, from.dy);
      final dx = (to.dx - from.dx).abs().clamp(24.0, 120.0);
      path.cubicTo(from.dx + dx, from.dy, to.dx - dx, to.dy, to.dx, to.dy);
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WirePainter oldDelegate) {
    return oldDelegate.wires != wires || oldDelegate.anchors != anchors || oldDelegate.selectedIndex != selectedIndex;
  }
}
