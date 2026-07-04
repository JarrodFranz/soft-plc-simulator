import 'package:flutter/material.dart';
import '../models/project_model.dart';
import '../models/ld_graph.dart';

const double _kColW = 116.0; // column pitch (cell + wire)
const double _kCellW = 66.0; // element cell width
const double _kContactH = 54.0;
const double _kBlockH = 92.0;
const double _kLaneGap = 10.0;
const double _kRailW = 6.0;
const double _kRungGap = 8.0;

class LdEditorScreen extends StatefulWidget {
  final PlcProject currentProject;
  final PlcProgram program;
  final VoidCallback onProgramUpdated;

  const LdEditorScreen({
    super.key,
    required this.currentProject,
    required this.program,
    required this.onProgramUpdated,
  });

  @override
  State<LdEditorScreen> createState() => _LdEditorScreenState();
}

class _LdEditorScreenState extends State<LdEditorScreen> {
  String _editMode = 'select'; // 'select' | 'contact' | 'coil' | 'block' | 'branch'
  LdNode? _branchStart; // first element tapped in branch mode

  @override
  void initState() {
    super.initState();
    _ensureDefaultRungs();
  }

  void _ensureDefaultRungs() {
    if (widget.program.rungs.isEmpty) {
      widget.program.rungs.addAll([
        buildRung(
          index: 0,
          comment: 'Rung 0: Motor Start/Stop Seal-In Circuit',
          main: [
            LdNode(id: '', kind: LdKind.contact, variable: 'Start_PB', comment: 'Start PB'),
            LdNode(id: '', kind: LdKind.contact, variable: 'Stop_PB', modifier: 'negated', comment: 'Stop PB'),
            LdNode(id: '', kind: LdKind.contact, variable: 'Overload_OK', modifier: 'negated', comment: 'Overload'),
            LdNode(id: '', kind: LdKind.coil, variable: 'Motor_Run', comment: 'Starter coil'),
          ],
          branches: [
            BranchSpec(startIndex: 0, endIndex: 0, nodes: [
              LdNode(id: '', kind: LdKind.contact, variable: 'Motor_Run', comment: 'Seal-in aux'),
            ]),
          ],
        ),
        buildRung(
          index: 1,
          comment: 'Rung 1: TON Timer Block (IN, Q, PT, ET)',
          main: [
            LdNode(id: '', kind: LdKind.contact, variable: 'TONTimer.DN', modifier: 'negated', comment: 'Done NC'),
            LdNode(id: '', kind: LdKind.block, blockType: 'TON', variable: 'TONTimer', presetMs: 5000, comment: '5s timer'),
            LdNode(id: '', kind: LdKind.coil, variable: 'MixerMotor', comment: 'Mixer coil'),
          ],
        ),
      ]);
    }
  }

  double _nodeH(LdNode n) => n.kind == LdKind.block ? _kBlockH : _kContactH;

  double _laneHeight(LdRung rung, int lane) {
    double h = _kContactH;
    for (final n in rung.nodes) {
      if (n.row == lane) {
        final nh = _nodeH(n);
        if (nh > h) {
          h = nh;
        }
      }
    }
    return h;
  }

  double _laneTop(LdRung rung, int lane) {
    double y = 0;
    for (int l = 0; l < lane; l++) {
      y += _laneHeight(rung, l) + _kLaneGap;
    }
    return y;
  }

  double _rungHeight(LdRung rung) {
    final lanes = maxLane(rung);
    return _laneTop(rung, lanes) + _laneHeight(rung, lanes);
  }

  double _colX(int col) => col * _kColW;

  double _rungWidth(LdRung rung, Map<String, int> col) {
    int maxc = 0;
    for (final n in rung.nodes) {
      final c = col[n.id] ?? 0;
      if (c > maxc) {
        maxc = c;
      }
    }
    return _colX(maxc);
  }

  double _nodeCenterY(LdRung rung, LdNode n) => _laneTop(rung, n.row) + _laneHeight(rung, n.row) / 2;

  Offset _outPort(LdRung rung, LdNode n, Map<String, int> col, double width) {
    if (n.kind == LdKind.leftRail) {
      return Offset(0, _nodeCenterY(rung, n));
    }
    final x = _colX(col[n.id] ?? 0) + _kCellW;
    return Offset(x, _nodeCenterY(rung, n));
  }

  Offset _inPort(LdRung rung, LdNode n, Map<String, int> col, double width) {
    if (n.kind == LdKind.rightRail) {
      return Offset(width, _nodeCenterY(rung, n));
    }
    return Offset(_colX(col[n.id] ?? 0), _nodeCenterY(rung, n));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.program.name} — Ladder Diagram (LD) Editor'),
        backgroundColor: const Color(0xFF1E293B),
      ),
      body: Column(
        children: [
          _buildToolbar(),
          Expanded(
            child: Container(
              color: const Color(0xFF0F172A),
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(width: _kRailW, color: Colors.greenAccent), // continuous L1
                  Expanded(
                    child: ListView.separated(
                      itemCount: widget.program.rungs.length,
                      separatorBuilder: (_, __) => const SizedBox(height: _kRungGap),
                      itemBuilder: (context, i) => _buildRungCanvas(widget.program.rungs[i], i),
                    ),
                  ),
                  Container(width: _kRailW, color: Colors.blueAccent), // continuous L2
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    Widget modeBtn(String mode, IconData icon, String label) {
      final active = _editMode == mode;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: TextButton.icon(
          icon: Icon(icon, size: 15, color: active ? Colors.black : Colors.cyanAccent),
          label: Text(label, style: TextStyle(fontSize: 11, color: active ? Colors.black : Colors.cyanAccent)),
          style: TextButton.styleFrom(
            backgroundColor: active ? Colors.cyanAccent : Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          ),
          onPressed: () => setState(() {
            _editMode = mode;
            _branchStart = null;
          }),
        ),
      );
    }

    return Container(
      height: 44,
      color: const Color(0xFF1E293B),
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        modeBtn('select', Icons.near_me, 'Select'),
        modeBtn('contact', Icons.horizontal_rule, 'Contact'),
        modeBtn('coil', Icons.radio_button_unchecked, 'Coil'),
        modeBtn('block', Icons.widgets, 'Block'),
        modeBtn('branch', Icons.account_tree, 'Branch'),
        const Spacer(),
        TextButton.icon(
          icon: const Icon(Icons.add, size: 15, color: Colors.greenAccent),
          label: const Text('Add Rung', style: TextStyle(fontSize: 11, color: Colors.greenAccent)),
          onPressed: _addRung,
        ),
        if (_editMode == 'branch')
          const Padding(
            padding: EdgeInsets.only(left: 8),
            child: Text('Tap span start, then span end', style: TextStyle(fontSize: 10, color: Colors.amberAccent)),
          ),
      ]),
    );
  }

  void _addRung() {
    setState(() {
      widget.program.rungs.add(buildRung(
        index: widget.program.rungs.length,
        comment: 'New Rung',
        main: [
          LdNode(id: '', kind: LdKind.contact, variable: 'New_Contact'),
          LdNode(id: '', kind: LdKind.coil, variable: 'Output_Coil'),
        ],
      ));
    });
    widget.onProgramUpdated();
  }

  Widget _buildRungCanvas(LdRung rung, int index) {
    final col = colAssignment(rung);
    final width = _rungWidth(rung, col);
    final height = _rungHeight(rung);

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF111C30),
        border: Border.all(color: Colors.white10),
        borderRadius: BorderRadius.circular(4),
      ),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 6),
            child: Text('RUNG $index   ${rung.comment}',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ),
          SizedBox(
            height: height,
            width: width,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Wires + branch brackets, drawn behind the elements.
                Positioned.fill(
                  child: CustomPaint(painter: _LadderPainter(this, rung, col, width)),
                ),
                // Element widgets.
                ...rung.nodes
                    .where((n) => n.kind == LdKind.contact || n.kind == LdKind.coil || n.kind == LdKind.block)
                    .map((n) => _positionedNode(rung, n, col)),
                // Insert targets on wires (contact/coil/block modes).
                if (_editMode == 'contact' || _editMode == 'coil' || _editMode == 'block')
                  ...rung.wires.map((w) => _wireInsertTarget(rung, w, col, width)),
                // Draggable branch start/end handles.
                ...findBranches(rung).expand((br) => _branchHandles(rung, br, col, width)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _positionedNode(LdRung rung, LdNode n, Map<String, int> col) {
    final h = _nodeH(n);
    final top = _nodeCenterY(rung, n) - h / 2;
    return Positioned(
      left: _colX(col[n.id] ?? 0),
      top: top,
      width: _kCellW,
      height: h,
      child: GestureDetector(
        onTap: () => _onNodeTap(rung, n),
        onDoubleTap: () => _showEditNodeDialog(rung, n),
        child: n.kind == LdKind.block ? _buildBlock(n) : _buildContactCoil(n),
      ),
    );
  }

  void _onNodeTap(LdRung rung, LdNode n) {
    if (_editMode == 'branch') {
      if (_branchStart == null) {
        setState(() => _branchStart = n);
      } else {
        final start = _branchStart!;
        final col = colAssignment(rung);
        // order the two picks left-to-right by column
        final a = (col[start.id] ?? 0) <= (col[n.id] ?? 0) ? start : n;
        final b = identical(a, start) ? n : start;
        setState(() {
          addParallelBranch(rung, a, b);
          _branchStart = null;
          _editMode = 'select';
        });
        widget.onProgramUpdated();
      }
      return;
    }
    // select mode: single tap selects (highlight handled via _branchStart reuse is avoided)
  }

  Widget _wireInsertTarget(LdRung rung, LdWire w, Map<String, int> col, double width) {
    final src = rung.nodes.firstWhere((n) => n.id == w.fromId);
    final dst = rung.nodes.firstWhere((n) => n.id == w.toId);
    final p1 = _outPort(rung, src, col, width);
    final p2 = _inPort(rung, dst, col, width);
    final mid = Offset((p1.dx + p2.dx) / 2, (p1.dy + p2.dy) / 2);
    return Positioned(
      left: mid.dx - 11,
      top: mid.dy - 11,
      width: 22,
      height: 22,
      child: GestureDetector(
        onTap: () => _insertOnWire(rung, w),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.cyanAccent.withValues(alpha: 0.85),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.add, size: 14, color: Colors.black),
        ),
      ),
    );
  }

  void _insertOnWire(LdRung rung, LdWire w) {
    final LdNode node;
    if (_editMode == 'coil') {
      node = LdNode(id: newNodeId(rung), kind: LdKind.coil, variable: 'Output_Coil');
    } else if (_editMode == 'block') {
      node = LdNode(id: newNodeId(rung), kind: LdKind.block, blockType: 'TON', variable: 'Timer', presetMs: 5000);
    } else {
      node = LdNode(id: newNodeId(rung), kind: LdKind.contact, variable: 'New_Contact');
    }
    setState(() {
      insertContactOnWire(rung, w, node);
      _editMode = 'select';
    });
    widget.onProgramUpdated();
    _showEditNodeDialog(rung, node);
  }

  List<Widget> _branchHandles(LdRung rung, LdBranchView br, Map<String, int> col, double width) {
    final first = rung.nodes.firstWhere((n) => n.id == br.firstNodeId);
    final last = rung.nodes.firstWhere((n) => n.id == br.lastNodeId);
    final startPt = _inPort(rung, first, col, width);
    final endPt = _outPort(rung, last, col, width);
    return [
      _handle(startPt, Colors.tealAccent, (dx) => _dragBranchTap(rung, br, dx)),
      _handle(endPt, Colors.tealAccent, (dx) => _dragBranchMerge(rung, br, dx)),
    ];
  }

  Widget _handle(Offset at, Color color, void Function(double globalDx) onDrag) {
    return Positioned(
      left: at.dx - 8,
      top: at.dy - 8,
      width: 16,
      height: 16,
      child: GestureDetector(
        onHorizontalDragUpdate: (d) => onDrag(d.localPosition.dx + at.dx - 8),
        child: Container(
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.black, width: 1),
          ),
        ),
      ),
    );
  }

  /// Finds the lane-0 node whose column boundary is nearest to pixel x.
  LdNode _nearestMainNode(LdRung rung, Map<String, int> col, double x) {
    LdNode best = rung.nodes.firstWhere((n) => n.kind == LdKind.leftRail);
    double bestDist = double.infinity;
    for (final n in rung.nodes) {
      if (n.row != 0) {
        continue;
      }
      final nx = _colX(col[n.id] ?? 0);
      final d = (nx - x).abs();
      if (d < bestDist) {
        bestDist = d;
        best = n;
      }
    }
    return best;
  }

  void _dragBranchTap(LdRung rung, LdBranchView br, double x) {
    final col = colAssignment(rung);
    final target = _nearestMainNode(rung, col, x);
    setState(() => moveBranchTap(rung, br, target));
    widget.onProgramUpdated();
  }

  void _dragBranchMerge(LdRung rung, LdBranchView br, double x) {
    final col = colAssignment(rung);
    final target = _nearestMainNode(rung, col, x);
    setState(() => moveBranchMerge(rung, br, target));
    widget.onProgramUpdated();
  }

  void _showEditNodeDialog(LdRung rung, LdNode n) {
    final tagCtrl = TextEditingController(text: n.variable);
    final presetCtrl = TextEditingController(text: n.presetMs.toString());
    String modifier = n.modifier;
    final isCoil = n.kind == LdKind.coil;
    final isBlock = n.kind == LdKind.block;

    const contactMods = [
      DropdownMenuItem(value: 'normal', child: Text('Normally Open  -| |-')),
      DropdownMenuItem(value: 'negated', child: Text('Normally Closed  -|/|-')),
      DropdownMenuItem(value: 'rising', child: Text('Rising Edge  -|P|-')),
      DropdownMenuItem(value: 'falling', child: Text('Falling Edge  -|N|-')),
    ];
    const coilMods = [
      DropdownMenuItem(value: 'normal', child: Text('Coil  -( )-')),
      DropdownMenuItem(value: 'negated', child: Text('Negated  -(/)-')),
      DropdownMenuItem(value: 'set', child: Text('Set / Latch  -(S)-')),
      DropdownMenuItem(value: 'reset', child: Text('Reset / Unlatch  -(R)-')),
      DropdownMenuItem(value: 'rising', child: Text('Rising  -(P)-')),
      DropdownMenuItem(value: 'falling', child: Text('Falling  -(N)-')),
    ];

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlg) => AlertDialog(
          title: Text('Edit ${isBlock ? n.blockType : (isCoil ? "Coil" : "Contact")}'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: widget.currentProject.tags.any((t) => t.name == n.variable) ? n.variable : null,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Tag'),
                  items: widget.currentProject.tags
                      .map((t) => DropdownMenuItem(value: t.name, child: Text('${t.name} [${t.dataType}]', overflow: TextOverflow.ellipsis)))
                      .toList(),
                  onChanged: (v) => tagCtrl.text = v ?? tagCtrl.text,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: tagCtrl,
                  decoration: const InputDecoration(labelText: 'Tag / literal', isDense: true, border: OutlineInputBorder()),
                ),
                if (!isBlock) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: modifier,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Type'),
                    items: isCoil ? coilMods : contactMods,
                    onChanged: (v) => setDlg(() => modifier = v!),
                  ),
                ],
                if (isBlock) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: presetCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Preset Time (PT) ms'),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                setState(() => deleteNode(rung, n));
                widget.onProgramUpdated();
                Navigator.pop(ctx);
              },
              child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
            ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  n.variable = tagCtrl.text.trim();
                  n.modifier = modifier;
                  n.presetMs = int.tryParse(presetCtrl.text) ?? n.presetMs;
                });
                widget.onProgramUpdated();
                Navigator.pop(ctx);
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContactCoil(LdNode n) {
    final isCoil = n.kind == LdKind.coil;
    String symbol;
    Color color;
    if (isCoil) {
      color = Colors.amberAccent;
      switch (n.modifier) {
        case 'negated':
          symbol = '-(/)-';
          break;
        case 'set':
          symbol = '-(S)-';
          break;
        case 'reset':
          symbol = '-(R)-';
          break;
        case 'rising':
          symbol = '-(P)-';
          break;
        case 'falling':
          symbol = '-(N)-';
          break;
        default:
          symbol = '-( )-';
      }
    } else {
      color = Colors.greenAccent;
      switch (n.modifier) {
        case 'negated':
          symbol = '-|/|-';
          break;
        case 'rising':
          symbol = '-|P|-';
          break;
        case 'falling':
          symbol = '-|N|-';
          break;
        default:
          symbol = '-| |-';
      }
    }
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color, width: 1.5),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(n.variable,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 9, color: color, fontFamily: 'monospace'),
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text(symbol,
              style: TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold, fontSize: 14, color: color)),
        ],
      ),
    );
  }

  Widget _buildBlock(LdNode n) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.grey.shade500, width: 1.5),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            decoration: const BoxDecoration(
              color: Color(0xFF334155),
              borderRadius: BorderRadius.only(topLeft: Radius.circular(3), topRight: Radius.circular(3)),
            ),
            child: Text(n.blockType,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.white, fontFamily: 'monospace'),
                textAlign: TextAlign.center),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(n.variable,
                    style: const TextStyle(fontSize: 8, color: Colors.cyanAccent, fontFamily: 'monospace'),
                    overflow: TextOverflow.ellipsis),
                const _BlockPinRow(left: 'IN', right: 'Q'),
                Text('PT ${n.presetMs}ms',
                    style: const TextStyle(fontSize: 7, color: Colors.grey), overflow: TextOverflow.ellipsis),
                const _BlockPinRow(left: 'PT', right: 'ET'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BlockPinRow extends StatelessWidget {
  final String left;
  final String right;
  const _BlockPinRow({required this.left, required this.right});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(left, style: const TextStyle(fontSize: 8, color: Colors.greenAccent, fontFamily: 'monospace')),
        Text(right, style: const TextStyle(fontSize: 8, color: Colors.greenAccent, fontFamily: 'monospace')),
      ],
    );
  }
}

class _LadderPainter extends CustomPainter {
  final _LdEditorScreenState s;
  final LdRung rung;
  final Map<String, int> col;
  final double width;

  _LadderPainter(this.s, this.rung, this.col, this.width);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.greenAccent
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    LdNode nodeById(String id) => rung.nodes.firstWhere((n) => n.id == id);

    for (final w in rung.wires) {
      final src = nodeById(w.fromId);
      final dst = nodeById(w.toId);
      final p1 = s._outPort(rung, src, col, width);
      final p2 = s._inPort(rung, dst, col, width);
      final path = Path()..moveTo(p1.dx, p1.dy);
      if (src.row == dst.row) {
        path.lineTo(p2.dx, p2.dy);
      } else if (dst.row > src.row) {
        // going into a deeper branch lane: vertical at source's right boundary
        path.lineTo(p1.dx, p2.dy);
        path.lineTo(p2.dx, p2.dy);
      } else {
        // returning to a shallower lane: vertical at destination's left boundary
        path.lineTo(p2.dx, p1.dy);
        path.lineTo(p2.dx, p2.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _LadderPainter old) => true;
}
