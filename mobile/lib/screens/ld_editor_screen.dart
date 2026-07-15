import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../models/project_model.dart';
import '../models/ld_graph.dart';
import '../models/ld_layout.dart';
import '../models/ld_monitor.dart';
import '../models/tag_resolver.dart';
import '../ui/responsive.dart';
import '../widgets/live_tick.dart';
import '../widgets/tag_autocomplete_field.dart';

const double _kContactH = 54.0;
const double _kBlockH = 92.0;
const double _kLaneGap = 10.0;
const double _kRailW = 6.0;
const double _kRungGap = 8.0;

/// Counter block types (preset = count, not time).
const List<String> _kCounterBlockTypes = ['CTU', 'CTD', 'CTUD'];
bool _isCounterBlock(String blockType) => _kCounterBlockTypes.contains(blockType);

/// Below this LOCAL available width, the toolbar wraps and the ladder canvas
/// gets pan/zoom. This is a per-pane decision (LayoutBuilder), never derived
/// from the window/`MediaQuery` width — the editor can be embedded in a
/// narrow center pane even when the overall window is wide (both docks open).
const double _kCompactPaneWidth = 560.0;

class LdEditorScreen extends StatefulWidget {
  final PlcProject currentProject;
  final PlcProgram program;
  final VoidCallback onProgramUpdated;
  final LdMonitor monitor;
  final bool scanRunning;

  const LdEditorScreen({
    super.key,
    required this.currentProject,
    required this.program,
    required this.onProgramUpdated,
    required this.monitor,
    required this.scanRunning,
  });

  @override
  State<LdEditorScreen> createState() => _LdEditorScreenState();
}

/// Grouped block-type picker choices, in display order.
const Map<String, List<String>> _kBlockGroups = {
  'Timers': ['TON', 'TOF', 'TP'],
  'Counters': ['CTU', 'CTD', 'CTUD'],
  'Compare': ['GT', 'LT', 'GE', 'LE', 'EQ', 'NE'],
  'Math': ['ADD', 'SUB', 'MUL', 'DIV', 'MOVE'],
};

const List<String> _kCompareBlockTypes = ['GT', 'LT', 'GE', 'LE', 'EQ', 'NE'];
const List<String> _kMathBlockTypes = ['ADD', 'SUB', 'MUL', 'DIV', 'MOVE'];
bool _isCompareBlock(String blockType) => _kCompareBlockTypes.contains(blockType);
bool _isMathBlock(String blockType) => _kMathBlockTypes.contains(blockType);
bool _isDataBlock(String blockType) => _isCompareBlock(blockType) || _isMathBlock(blockType);

/// Operator glyph shown centred in a compare/math data-block body.
String _blockOperatorGlyph(String blockType) {
  switch (blockType) {
    case 'GT':
      return '>';
    case 'LT':
      return '<';
    case 'GE':
      return '≥';
    case 'LE':
      return '≤';
    case 'EQ':
      return '=';
    case 'NE':
      return '≠';
    case 'ADD':
      return '+';
    case 'SUB':
      return '−';
    case 'MUL':
      return '×';
    case 'DIV':
      return '÷';
    default: // MOVE
      return 'MOVE';
  }
}

class _LdEditorScreenState extends State<LdEditorScreen> {
  String _editMode = 'select'; // 'select' | 'contact' | 'coil' | 'block' | 'branch'
  String _pendingBlockType = 'TON';
  // Key of the picked start junction wire in guided Branch mode, e.g.
  // '0|m0>m1' — namespaced by rung index, since main-line node ids (m0/m1/...)
  // are per-rung and two structurally-identical rungs would otherwise share
  // a key (highlighting/activating the wrong rung's dot).
  String? _branchStartWireKey;
  LdBranchView? _dragBranch;
  bool _dragTapEnd = false; // true = dragging the tap (start) handle; false = merge (end)
  double _dragX = 0;

  // Session-only "Go-Online" live-monitor toggle. When true, wires/elements
  // reflect the last scan's power solve (via widget.monitor); default false so
  // the static editor view is byte-for-byte unchanged. Never persisted.
  bool _online = false;

  // Energized/de-energized palette for the live "online" view.
  static const Color _kEnergized = Colors.greenAccent;
  static const Color _kDeEnergized = Color(0xFF475569); // slate-600

  bool _nodeLit(LdRung rung, LdNode n) =>
      _online &&
      (widget.monitor.nodePower[
              widget.monitor.keyFor(widget.program.name, rung.rungIndex, n.id)] ??
          false);

  // Formats a live tag/path value for a block-face readout. Numeric leaves
  // read via `readPath` (ints as-is, doubles to 1 decimal); a BOOL leaf is
  // shown as '1'/'0' to match the executor's bool->num operand mapping (see
  // `_operandValue` in ld_exec.dart); anything else (unresolvable path,
  // non-numeric value) falls back to an em dash.
  String _liveNum(String path) {
    final v = readPath(widget.currentProject, path);
    if (v is num) {
      return v is int ? '$v' : v.toStringAsFixed(1);
    }
    if (v is bool) {
      return v ? '1' : '0';
    }
    return '—';
  }

  // Unified horizontal scroll for the non-compact (desktop) rung list, used
  // only when the widest rung exceeds the available pane width. Persistent
  // so the Scrollbar's drag-thumb and scroll position survive rebuilds.
  final ScrollController _hScrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _ensureDefaultRungs();
  }

  @override
  void dispose() {
    _hScrollCtrl.dispose();
    super.dispose();
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
          branches: [
            BranchSpec(startIndex: 0, endIndex: 2, nodes: [
              LdNode(id: '', kind: LdKind.contact, variable: 'TONTimer.DN', comment: 'Done NO'),
              LdNode(id: '', kind: LdKind.coil, variable: 'Arbor1Oiler', comment: 'Arbor oiler coil'),
            ]),
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

  double _colX(int col) => ldColX(col);

  double _nodeCenterY(LdRung rung, LdNode n) => _laneTop(rung, n.row) + _laneHeight(rung, n.row) / 2;

  Offset _outPort(LdRung rung, LdNode n, Map<String, int> col, double width) {
    if (n.kind == LdKind.leftRail) {
      return Offset(0, _nodeCenterY(rung, n));
    }
    return Offset(ldNodeX(n, col[n.id] ?? 0, width) + kLdCellW, _nodeCenterY(rung, n));
  }

  Offset _inPort(LdRung rung, LdNode n, Map<String, int> col, double width) {
    if (n.kind == LdKind.rightRail) {
      return Offset(width, _nodeCenterY(rung, n));
    }
    return Offset(ldNodeX(n, col[n.id] ?? 0, width), _nodeCenterY(rung, n));
  }

  @override
  Widget build(BuildContext context) {
    final short = context.isShort;
    return Scaffold(
      appBar: AppBar(
        title: Text(short
            ? '${widget.program.name} (LD)'
            : '${widget.program.name} — Ladder Diagram (LD) Editor'),
        backgroundColor: const Color(0xFF1E293B),
        toolbarHeight: short ? 46 : null,
        actions: [
          if (_online)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Center(
                child: Text(
                  widget.scanRunning ? 'LIVE' : 'FROZEN',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: widget.scanRunning ? Colors.greenAccent : Colors.amberAccent,
                  ),
                ),
              ),
            ),
          IconButton(
            icon: Icon(Icons.sensors, color: _online ? Colors.greenAccent : Colors.grey),
            tooltip: 'Go Online (live monitor)',
            onPressed: () => setState(() => _online = !_online),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < _kCompactPaneWidth;
          return Column(
            children: [
              _buildToolbar(),
              Expanded(
                child: Container(
                  color: const Color(0xFF0F172A),
                  padding: const EdgeInsets.all(16),
                  child: _buildRungList(compact: compact),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildRungList({required bool compact}) {
    if (!compact) {
      return LayoutBuilder(
        builder: (context, constraints) {
          double maxContentW = 0;
          for (final r in widget.program.rungs) {
            final w = ldMinContentWidth(r, colAssignment(r));
            if (w > maxContentW) {
              maxContentW = w;
            }
          }
          final innerW = constraints.maxWidth - 2 * _kRailW;

          if (maxContentW <= innerW) {
            // Ladder fits the pane — no horizontal scroll needed; keep the
            // existing natural-width layout unchanged.
            return Row(
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
            );
          }

          // Ladder is wider than the pane: scroll the whole rail+rungs
          // assembly horizontally as one unit, with a visible, mouse-draggable
          // scrollbar (a desktop mouse wheel drives the vertical ListView, so
          // per-rung scrolling with no scrollbar left no way to reach the
          // right-hand side — see fix/ld-horizontal-scroll).
          final contentW = maxContentW;
          final rails = Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: _kRailW, color: Colors.greenAccent), // continuous L1
              SizedBox(
                width: contentW,
                child: ListView.separated(
                  itemCount: widget.program.rungs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: _kRungGap),
                  itemBuilder: (context, i) =>
                      _buildRungCanvas(widget.program.rungs[i], i, fixedWidth: contentW),
                ),
              ),
              Container(width: _kRailW, color: Colors.blueAccent), // continuous L2
            ],
          );

          return Scrollbar(
            controller: _hScrollCtrl,
            thumbVisibility: true,
            child: SingleChildScrollView(
              controller: _hScrollCtrl,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: contentW + 2 * _kRailW,
                height: constraints.maxHeight,
                child: rails,
              ),
            ),
          );
        },
      );
    }

    // Compact (narrow local pane, e.g. phone or a squeezed center workspace):
    // pan/zoom the whole ladder canvas so every rung/element is reachable by
    // swiping, instead of relying on the per-rung horizontal scroll (which
    // would fight a single pan gesture across the whole canvas).
    final rungs = widget.program.rungs;
    double contentHeight = 0;
    for (final r in rungs) {
      contentHeight += _rungHeight(r) + 58 /* rung chrome: label + padding */ + _kRungGap;
    }
    double contentWidth = _kCompactPaneWidth;
    for (final r in rungs) {
      final col = colAssignment(r);
      final w = ldMinContentWidth(r, col);
      if (w > contentWidth) {
        contentWidth = w;
      }
    }

    final rails = Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(width: _kRailW, color: Colors.greenAccent), // continuous L1
        Expanded(
          child: ListView.separated(
            physics: const NeverScrollableScrollPhysics(),
            shrinkWrap: true,
            itemCount: rungs.length,
            separatorBuilder: (_, __) => const SizedBox(height: _kRungGap),
            itemBuilder: (context, i) => _buildRungCanvas(rungs[i], i, compact: true),
          ),
        ),
        Container(width: _kRailW, color: Colors.blueAccent), // continuous L2
      ],
    );

    return InteractiveViewer(
      constrained: false,
      minScale: 0.5,
      maxScale: 2.5,
      boundaryMargin: const EdgeInsets.all(200),
      child: SizedBox(
        width: contentWidth,
        height: math.max(contentHeight, 200),
        child: rails,
      ),
    );
  }

  Widget _buildToolbar() {
    Widget modeBtn(String mode, IconData icon, String label, {VoidCallback? onPressed}) {
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
          onPressed: onPressed ??
              () => setState(() {
                    _editMode = mode;
                    _branchStartWireKey = null;
                  }),
        ),
      );
    }

    final modeButtons = [
      modeBtn('select', Icons.near_me, 'Select'),
      modeBtn('contact', Icons.horizontal_rule, 'Contact'),
      modeBtn('coil', Icons.radio_button_unchecked, 'Coil'),
      modeBtn('block', Icons.widgets, 'Block', onPressed: _showBlockTypePicker),
      modeBtn('branch', Icons.account_tree, 'Branch'),
    ];
    final addRungBtn = TextButton.icon(
      icon: const Icon(Icons.add, size: 15, color: Colors.greenAccent),
      label: const Text('Add Rung', style: TextStyle(fontSize: 11, color: Colors.greenAccent)),
      onPressed: _addRung,
    );
    final branchHint = Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Text(
        _branchStartWireKey == null ? 'Tap a start point' : 'Tap an end point (tap the start again to cancel)',
        style: const TextStyle(fontSize: 10, color: Colors.amberAccent),
      ),
    );

    // Decide compact-vs-wide from the toolbar's own LOCAL available width,
    // never the window/MediaQuery width — this editor can be embedded in a
    // narrow center pane even when the overall window is wide (both docks
    // open), which previously caused a RenderFlex overflow in the fixed Row.
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < _kCompactPaneWidth) {
          // Compact: never overflow — wrap the toolbar buttons onto multiple lines.
          return Container(
            color: const Color(0xFF1E293B),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ...modeButtons,
                addRungBtn,
                if (_editMode == 'branch') branchHint,
              ],
            ),
          );
        }

        return Container(
          height: 44,
          color: const Color(0xFF1E293B),
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(children: [
            ...modeButtons,
            const Spacer(),
            addRungBtn,
            if (_editMode == 'branch') branchHint,
          ]),
        );
      },
    );
  }

  /// Opens a grouped picker (Timers / Counters / Compare / Math) for the
  /// "Block" toolbar button. Selecting a type sets [_pendingBlockType] and
  /// switches the editor into block-insert mode.
  Future<void> _showBlockTypePicker() async {
    final selected = await showAdaptiveWidthDialog<String>(
      context,
      desiredWidth: 360,
      child: AlertDialog(
        title: const Text('Insert Block'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final group in _kBlockGroups.entries) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 4),
                    child: Text(group.key,
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.bold, color: Colors.cyanAccent)),
                  ),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final type in group.value)
                        ActionChip(
                          label: Text(type, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                          onPressed: () => Navigator.pop(context, type),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ],
      ),
    );
    if (selected != null) {
      setState(() {
        _pendingBlockType = selected;
        _editMode = 'block';
        _branchStartWireKey = null;
      });
    }
  }

  Widget _rungActionButton({required IconData icon, required Color color, required VoidCallback? onPressed}) {
    return touchable(
      IconButton(
        icon: Icon(icon, size: 16),
        color: color,
        disabledColor: color.withValues(alpha: 0.25),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        onPressed: onPressed,
      ),
    );
  }

  void _moveRungBy(int index, int delta) {
    setState(() => moveRung(widget.program, index, index + delta));
    widget.onProgramUpdated();
  }

  Future<void> _confirmDeleteRung(int index) async {
    final confirmed = await showAdaptiveWidthDialog<bool>(
      context,
      child: AlertDialog(
        title: const Text('Delete Rung'),
        content: Text('Delete RUNG $index? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) {
      setState(() => deleteRung(widget.program, index));
      widget.onProgramUpdated();
    }
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
      // Guarantees rungIndex == list position even if a prior delete/move left
      // gaps (see reindexRungs doc) — avoids two rungs aliasing the same
      // exec/monitor state key.
      reindexRungs(widget.program);
    });
    widget.onProgramUpdated();
  }

  Widget _buildRungCanvas(LdRung rung, int index, {bool compact = false, double? fixedWidth}) {
    final col = colAssignment(rung);
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
            padding: const EdgeInsets.only(left: 8, bottom: 6, right: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text('RUNG $index   ${rung.comment}',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                      overflow: TextOverflow.ellipsis),
                ),
                touchable(
                  IconButton(
                    icon: const Icon(Icons.add, size: 18, color: Colors.cyanAccent),
                    tooltip: 'Add output',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                    onPressed: () => _addOutputCoilAndEdit(rung),
                  ),
                ),
                _rungActionButton(
                  icon: Icons.arrow_upward,
                  color: Colors.cyanAccent,
                  onPressed: index == 0 ? null : () => _moveRungBy(index, -1),
                ),
                _rungActionButton(
                  icon: Icons.arrow_downward,
                  color: Colors.cyanAccent,
                  onPressed: index == widget.program.rungs.length - 1 ? null : () => _moveRungBy(index, 1),
                ),
                _rungActionButton(
                  icon: Icons.delete_outline,
                  color: Colors.redAccent,
                  onPressed: () => _confirmDeleteRung(index),
                ),
              ],
            ),
          ),
          LayoutBuilder(
            builder: (context, constraints) {
              final minW = ldMinContentWidth(rung, col);
              final width = fixedWidth ?? (constraints.maxWidth > minW ? constraints.maxWidth : minW);
              final needsScroll = fixedWidth == null && minW > constraints.maxWidth;
              final canvas = SizedBox(
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
                        .where((n) => n.kind == LdKind.contact ||
                            n.kind == LdKind.coil ||
                            n.kind == LdKind.block ||
                            n.kind == LdKind.link)
                        .map((n) => _positionedNode(rung, n, col, width)),
                    // Insert targets on wires (contact/block modes). Wires
                    // touching a still-open LdKind.link are excluded — an
                    // empty branch is filled ONLY by tapping its slot; a
                    // wire-insert there would splice a new element IN SERIES
                    // with the open link (link -> newNode -> dest), which is
                    // a permanently dead branch (open AND element = open).
                    if (_editMode == 'contact' || _editMode == 'block')
                      ...rung.wires
                          .where((w) => canInsertContactOnWire(rung, w) && !_wireTouchesLink(rung, w))
                          .map((w) => _wireInsertTarget(rung, w, col, width)),
                    // Insert targets on wires (coil mode). Same link-exclusion
                    // as above.
                    if (_editMode == 'coil')
                      ...rung.wires
                          .where((w) => canInsertCoilOnWire(rung, w) && !_wireTouchesLink(rung, w))
                          .map((w) => _wireInsertTarget(rung, w, col, width)),
                    // Guided junction-anchor pick targets (branch mode): one
                    // dot per lane-0 (main-line) wire.
                    if (_editMode == 'branch') ..._branchJunctionDots(rung, index, col, width),
                    // Draggable branch start/end handles.
                    ...findBranches(rung).expand((br) => _branchHandles(rung, br, col, width)),
                  ],
                ),
              );

              // While online, rebuild the rung's Stack (painter + element
              // widgets) on each LiveTick pulse so every scan's power solve is
              // reflected. Off-line, this is a pass-through — the static path
              // is byte-for-byte unchanged.
              Widget wrapLive(Widget child) {
                if (!_online) {
                  return child;
                }
                return ListenableBuilder(
                  listenable: LiveTickScope.of(context),
                  builder: (_, __) => child,
                );
              }

              if (!needsScroll || compact) {
                // On a compact pane the enclosing InteractiveViewer already
                // provides panning across the whole canvas (including any
                // rung wider than the pane) — an inner horizontal scrollable
                // here would fight that single pan gesture, so it's only
                // used on wide/desktop panes.
                return wrapLive(canvas);
              }
              // The rung's minimum content width exceeds the available space
              // (typical on a phone) — let this rung scroll horizontally on
              // its own rather than overflow the enclosing column.
              return wrapLive(SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: canvas,
              ));
            },
          ),
        ],
      ),
    );
  }

  Widget _positionedNode(LdRung rung, LdNode n, Map<String, int> col, double width) {
    final h = _nodeH(n);
    final top = _nodeCenterY(rung, n) - h / 2;
    return Positioned(
      left: ldNodeX(n, col[n.id] ?? 0, width),
      top: top,
      width: kLdCellW,
      height: h,
      child: GestureDetector(
        onTap: () => _onNodeTap(rung, n),
        onDoubleTap: () => _showEditNodeDialog(rung, n),
        child: n.kind == LdKind.block
            ? _buildBlock(n, live: _online, lit: _nodeLit(rung, n))
            : (n.kind == LdKind.link
                ? _buildLink(n)
                : _buildContactCoil(n, live: _online, lit: _nodeLit(rung, n))),
      ),
    );
  }

  /// In an element mode (contact/coil/block), tapping an empty `link` slot
  /// fills it in place (replaces, not inserts in series) and opens its edit
  /// dialog — mirroring `_insertOnWire`'s "insert then edit" flow. In select
  /// mode (or tapping a non-link node), this is a no-op for now — branches
  /// are created via the guided junction-anchor dots in Branch mode, not
  /// element taps.
  void _onNodeTap(LdRung rung, LdNode n) {
    if (n.kind != LdKind.link) {
      return;
    }
    if (_editMode != 'contact' && _editMode != 'coil' && _editMode != 'block') {
      return;
    }
    late final LdNode filled;
    setState(() {
      if (_editMode == 'contact') {
        filled = fillLink(rung, n, LdNode(id: '', kind: LdKind.contact, variable: 'New_Contact'));
      } else if (_editMode == 'coil') {
        filled = fillLink(rung, n, LdNode(id: '', kind: LdKind.coil, variable: 'Output_Coil'));
      } else {
        final blockType = _pendingBlockType;
        filled = fillLink(
          rung,
          n,
          LdNode(
            id: '',
            kind: LdKind.block,
            blockType: blockType,
            variable: 'T1',
            presetMs: 5000,
            operandA: _isDataBlock(blockType) ? '0' : '',
            operandB: _isDataBlock(blockType) ? '0' : '',
          ),
        );
      }
      _editMode = 'select';
    });
    widget.onProgramUpdated();
    _showEditNodeDialog(rung, filled);
  }

  LdNode _nodeById(LdRung rung, String id) => rung.nodes.firstWhere((n) => n.id == id);

  /// True if either endpoint of [w] is a still-open `LdKind.link` (empty
  /// branch placeholder). Such wires must never offer a wire-insert "+" —
  /// the link is filled (replaced) only by tapping its own slot; a series
  /// insert next to an open link would leave the branch permanently dead.
  bool _wireTouchesLink(LdRung rung, LdWire w) =>
      _nodeById(rung, w.fromId).kind == LdKind.link || _nodeById(rung, w.toId).kind == LdKind.link;

  // Junction-wire key is namespaced by rung index — main-line node ids
  // (m0/m1/...) are per-rung, so two structurally-identical rungs would
  // otherwise share a key and a start picked in one rung would highlight
  // (or let you branch into) the same-key dot in the other rung.
  String _wireKey(int rungIndex, LdWire w) => '$rungIndex|${w.fromId}>${w.toId}';

  bool _isLaneZero(LdWire w, LdRung rung) {
    final from = _nodeById(rung, w.fromId);
    final to = _nodeById(rung, w.toId);
    return from.row == 0 && to.row == 0;
  }

  /// Lane-0 (main-line) wires, ordered left-to-right by the source node's
  /// column. Each such wire is a "junction" the user can pick as a branch
  /// start or end in guided Branch mode.
  List<LdWire> _mainLineWires(LdRung rung) {
    final col = colAssignment(rung);
    final wires = rung.wires.where((w) => _isLaneZero(w, rung)).toList()
      ..sort((a, b) => (col[a.fromId] ?? 0).compareTo(col[b.fromId] ?? 0));
    return wires;
  }

  /// One pick-target dot per main-line wire (junction), for guided Branch
  /// mode. Before a start is picked, every dot is active. Once a start is
  /// picked, that dot is highlighted; only dots strictly to its right stay
  /// active (valid end picks) and the rest are dimmed + non-tappable.
  List<Widget> _branchJunctionDots(LdRung rung, int rungIndex, Map<String, int> col, double width) {
    final wires = _mainLineWires(rung);
    LdWire? startWire;
    if (_branchStartWireKey != null) {
      for (final w in wires) {
        if (_wireKey(rungIndex, w) == _branchStartWireKey) {
          startWire = w;
          break;
        }
      }
    }
    return [for (final w in wires) _junctionDot(rung, rungIndex, w, col, width, startWire)];
  }

  Widget _junctionDot(
      LdRung rung, int rungIndex, LdWire w, Map<String, int> col, double width, LdWire? startWire) {
    final src = _nodeById(rung, w.fromId);
    final dst = _nodeById(rung, w.toId);
    final p1 = _outPort(rung, src, col, width);
    final p2 = _inPort(rung, dst, col, width);
    final mid = Offset((p1.dx + p2.dx) / 2, (p1.dy + p2.dy) / 2);
    final isStart = startWire != null && _wireKey(rungIndex, w) == _wireKey(rungIndex, startWire);
    final active = startWire == null || isStart || (col[w.fromId] ?? 0) > (col[startWire.fromId] ?? 0);
    final color = isStart ? Colors.tealAccent : Colors.cyanAccent;
    return Positioned(
      left: mid.dx - 11,
      top: mid.dy - 11,
      width: 22,
      height: 22,
      child: GestureDetector(
        onTap: active ? () => _onJunctionDotTap(rung, rungIndex, w) : null,
        child: Container(
          decoration: BoxDecoration(
            color: active ? color.withValues(alpha: 0.85) : color.withValues(alpha: 0.3),
            shape: BoxShape.circle,
          ),
          child: Icon(isStart ? Icons.check : Icons.circle, size: isStart ? 14 : 8, color: Colors.black),
        ),
      ),
    );
  }

  void _onJunctionDotTap(LdRung rung, int rungIndex, LdWire w) {
    final key = _wireKey(rungIndex, w);
    if (_branchStartWireKey == null) {
      setState(() => _branchStartWireKey = key);
      return;
    }
    if (_branchStartWireKey == key) {
      // Tapping the start dot again cancels the pick.
      setState(() => _branchStartWireKey = null);
      return;
    }
    final wires = _mainLineWires(rung);
    final startWire = wires.firstWhere((ww) => _wireKey(rungIndex, ww) == _branchStartWireKey);
    setState(() {
      addEmptyBranch(rung, startWire.fromId, w.toId);
      _branchStartWireKey = null;
      _editMode = 'select';
    });
    widget.onProgramUpdated();
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

  /// Adds a brand new stacked output coil on a fresh lane, independent of any
  /// existing wire, and opens its edit dialog. Invoked from the rung header's
  /// "Add output" button (available in any editor mode, not just Coil mode).
  void _addOutputCoilAndEdit(LdRung rung) {
    late final LdNode coilNode;
    setState(() {
      coilNode = addOutputCoil(rung);
      _editMode = 'select';
    });
    widget.onProgramUpdated();
    _showEditNodeDialog(rung, coilNode);
  }

  void _insertOnWire(LdRung rung, LdWire w) {
    final LdNode node;
    if (_editMode == 'coil') {
      node = LdNode(id: newNodeId(rung), kind: LdKind.coil, variable: 'Output_Coil');
    } else if (_editMode == 'block') {
      final blockType = _pendingBlockType;
      if (_isCompareBlock(blockType)) {
        node = LdNode(
          id: newNodeId(rung),
          kind: LdKind.block,
          blockType: blockType,
          variable: '',
          operandA: '0',
          operandB: '0',
        );
      } else if (_isMathBlock(blockType)) {
        node = LdNode(
          id: newNodeId(rung),
          kind: LdKind.block,
          blockType: blockType,
          variable: 'Result',
          operandA: '0',
          operandB: '0',
        );
      } else {
        node = LdNode(
          id: newNodeId(rung),
          kind: LdKind.block,
          blockType: blockType,
          variable: _isCounterBlock(blockType) ? 'Counter' : 'Timer',
          presetMs: _isCounterBlock(blockType) ? 10 : 5000,
        );
      }
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
    final handles = <Widget>[
      _handle(startPt,
          onStart: () => _beginBranchDrag(br, true, startPt.dx),
          onUpdate: (dx) => _dragX += dx,
          onEnd: () => _endBranchDrag(rung)),
    ];
    // A coil-terminated branch's output is fixed at the right rail — its end is
    // not re-spannable, so don't offer a merge handle that could make the coil
    // non-terminal.
    if (last.kind != LdKind.coil) {
      final endPt = _outPort(rung, last, col, width);
      handles.add(_handle(endPt,
          onStart: () => _beginBranchDrag(br, false, endPt.dx),
          onUpdate: (dx) => _dragX += dx,
          onEnd: () => _endBranchDrag(rung)));
    }
    return handles;
  }

  Widget _handle(Offset at,
      {required VoidCallback onStart,
      required void Function(double delta) onUpdate,
      required VoidCallback onEnd}) {
    final dot = SizedBox(
      width: 16,
      height: 16,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.tealAccent,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.black, width: 1),
        ),
      ),
    );
    // The visible dot stays 16px, but the touch target is enlarged to the
    // Material minimum (44px) via `touchable`, centered on the wire point.
    return Positioned(
      left: at.dx - kMinTouch / 2,
      top: at.dy - kMinTouch / 2,
      width: kMinTouch,
      height: kMinTouch,
      child: GestureDetector(
        onHorizontalDragStart: (_) => onStart(),
        onHorizontalDragUpdate: (d) => onUpdate(d.delta.dx),
        onHorizontalDragEnd: (_) => onEnd(),
        child: touchable(dot),
      ),
    );
  }

  void _beginBranchDrag(LdBranchView br, bool tapEnd, double startX) {
    _dragBranch = br;
    _dragTapEnd = tapEnd;
    _dragX = startX;
  }

  void _endBranchDrag(LdRung rung) {
    final br = _dragBranch;
    if (br == null) {
      return;
    }
    final col = colAssignment(rung);
    if (_dragTapEnd) {
      final mergeDestId = _branchMergeDestId(rung, br);
      final maxCol = mergeDestId == null ? null : col[mergeDestId];
      final target = _nearestMainNode(rung, col, _dragX, maxColExclusive: maxCol);
      if (target != null) {
        moveBranchTap(rung, br, target);
      }
    } else {
      final tapSrcId = _branchTapSrcId(rung, br);
      final minCol = tapSrcId == null ? null : col[tapSrcId];
      final target = _nearestMainNode(rung, col, _dragX, minColExclusive: minCol);
      if (target != null) {
        moveBranchMerge(rung, br, target);
      }
    }
    setState(() => _dragBranch = null);
    widget.onProgramUpdated();
  }

  String? _branchTapSrcId(LdRung rung, LdBranchView br) {
    for (final w in rung.wires) {
      if (w.toId == br.firstNodeId) {
        final src = rung.nodes.firstWhere((n) => n.id == w.fromId);
        if (src.row < br.lane) {
          return w.fromId;
        }
      }
    }
    return null;
  }

  String? _branchMergeDestId(LdRung rung, LdBranchView br) {
    for (final w in rung.wires) {
      if (w.fromId == br.lastNodeId) {
        final dst = rung.nodes.firstWhere((n) => n.id == w.toId);
        if (dst.row < br.lane) {
          return w.toId;
        }
      }
    }
    return null;
  }

  /// Nearest lane-0 node to pixel [x], optionally constrained to columns
  /// strictly greater than [minColExclusive] and/or strictly less than
  /// [maxColExclusive]. Returns null if no candidate satisfies the bounds.
  LdNode? _nearestMainNode(LdRung rung, Map<String, int> col, double x,
      {int? minColExclusive, int? maxColExclusive}) {
    LdNode? best;
    double bestDist = double.infinity;
    for (final n in rung.nodes) {
      if (n.row != 0) {
        continue;
      }
      final c = col[n.id] ?? 0;
      if (minColExclusive != null && c <= minColExclusive) {
        continue;
      }
      if (maxColExclusive != null && c >= maxColExclusive) {
        continue;
      }
      final nx = _colX(c);
      final d = (nx - x).abs();
      if (d < bestDist) {
        bestDist = d;
        best = n;
      }
    }
    return best;
  }

  void _showEditNodeDialog(LdRung rung, LdNode n) {
    if (n.kind == LdKind.link) {
      // An empty-branch placeholder has no logical content to edit — offer
      // only Delete/Cancel instead of the generic contact-editing UI (which
      // would silently write dead Tag/modifier data onto a slot that still
      // renders as the ghost "+" affordance).
      showAdaptiveWidthDialog(
        context,
        desiredWidth: 420,
        child: AlertDialog(
          title: const Text('Empty Branch Slot'),
          content: const Text(
            'Empty branch slot. Pick the Contact, Coil, or Block tool and tap '
            'this slot to fill it — or delete the branch.',
          ),
          actions: [
            TextButton(
              onPressed: () {
                setState(() {
                  // An open link has no logical content to remove — deleting
                  // it drops the whole (still-empty) branch.
                  collapseLink(rung, n);
                });
                widget.onProgramUpdated();
                Navigator.pop(context);
              },
              child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
            ),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ],
        ),
      );
      return;
    }
    final tagCtrl = TextEditingController(text: n.variable);
    final presetCtrl = TextEditingController(text: n.presetMs.toString());
    final downTagCtrl = TextEditingController(text: n.operandA);
    final operandACtrl = TextEditingController(text: n.operandA);
    final operandBCtrl = TextEditingController(text: n.operandB);
    final compareNameCtrl = TextEditingController(text: n.variable);
    String modifier = n.modifier;
    String blockType = n.blockType;
    final isCoil = n.kind == LdKind.coil;
    final isBlock = n.kind == LdKind.block;
    final isCounter = isBlock && _isCounterBlock(n.blockType);
    final isCtud = isBlock && n.blockType == 'CTUD';
    final isCompare = isBlock && _isCompareBlock(n.blockType);
    final isMath = isBlock && _isMathBlock(n.blockType);
    final isDataBlock = isCompare || isMath;

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
    final compareOpItems = [
      for (final t in _kCompareBlockTypes)
        DropdownMenuItem(value: t, child: Text('$t  (${_blockOperatorGlyph(t)})')),
    ];
    final mathOpItems = [
      for (final t in _kMathBlockTypes)
        DropdownMenuItem(value: t, child: Text('$t  (${_blockOperatorGlyph(t)})')),
    ];

    showAdaptiveWidthDialog(
      context,
      desiredWidth: 420,
      child: StatefulBuilder(
        builder: (context, setDlg) => AlertDialog(
          title: Text('Edit ${isBlock ? n.blockType : (isCoil ? "Coil" : "Contact")}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!isDataBlock)
                  TagAutocompleteField(
                    options: leafAndNodePaths(widget.currentProject),
                    initialValue: tagCtrl.text,
                    label: 'Tag / literal',
                    onChanged: (v) => tagCtrl.text = v,
                  ),
                if (isMath) ...[
                  TagAutocompleteField(
                    options: leafAndNodePaths(widget.currentProject),
                    initialValue: tagCtrl.text,
                    label: 'Output tag',
                    onChanged: (v) => tagCtrl.text = v,
                  ),
                  const SizedBox(height: 12),
                ],
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
                if (isBlock && !isDataBlock) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: presetCtrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: isCounter ? 'Preset Count (PV)' : 'Preset Time (PT) ms',
                    ),
                  ),
                ],
                if (isCtud) ...[
                  const SizedBox(height: 12),
                  TagAutocompleteField(
                    options: leafAndNodePaths(widget.currentProject),
                    initialValue: downTagCtrl.text,
                    label: 'Count-down tag',
                    onChanged: (v) => downTagCtrl.text = v,
                  ),
                ],
                if (isDataBlock) ...[
                  TagAutocompleteField(
                    options: leafAndNodePaths(widget.currentProject),
                    initialValue: operandACtrl.text,
                    label: 'Operand A',
                    onChanged: (v) => operandACtrl.text = v,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: blockType,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Operator'),
                    items: isCompare ? compareOpItems : mathOpItems,
                    onChanged: (v) => setDlg(() => blockType = v!),
                  ),
                  const SizedBox(height: 12),
                  TagAutocompleteField(
                    options: leafAndNodePaths(widget.currentProject),
                    initialValue: operandBCtrl.text,
                    label: 'Operand B',
                    onChanged: (v) => operandBCtrl.text = v,
                  ),
                  if (isCompare) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: compareNameCtrl,
                      decoration: const InputDecoration(labelText: 'Name'),
                    ),
                  ],
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                setState(() {
                  // n.kind == LdKind.link is handled by the early-return
                  // branch above, so only real contact/coil/block nodes
                  // reach here.
                  if (n.row > 0 &&
                      !rung.nodes.any((o) => o.id != n.id && o.row == n.row)) {
                    // Sole element on a branch lane: revert to an open link
                    // (keep the branch) instead of dropping the lane entirely.
                    emptyBranch(rung, n);
                  } else {
                    deleteNode(rung, n);
                  }
                });
                widget.onProgramUpdated();
                Navigator.pop(context);
              },
              child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
            ),
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  if (isDataBlock) {
                    n.blockType = blockType;
                    n.operandA = operandACtrl.text.trim();
                    n.operandB = operandBCtrl.text.trim();
                    if (isMath) {
                      n.variable = tagCtrl.text.trim();
                    } else if (isCompare) {
                      n.variable = compareNameCtrl.text.trim();
                    }
                  } else {
                    n.variable = tagCtrl.text.trim();
                    n.modifier = modifier;
                    n.presetMs = int.tryParse(presetCtrl.text) ?? n.presetMs;
                    if (isCtud) {
                      n.operandA = downTagCtrl.text.trim();
                    }
                  }
                });
                widget.onProgramUpdated();
                Navigator.pop(context);
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
  }

  /// An open (unfilled) branch: a ghosted, low-alpha "＋" slot inviting the
  /// user to tap it in Contact/Coil/Block mode to fill it in place.
  Widget _buildLink(LdNode n) {
    return Container(
      key: const Key('ld_link_slot'),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.cyanAccent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.35), width: 1.5),
      ),
      child: Icon(Icons.add, size: 18, color: Colors.cyanAccent.withValues(alpha: 0.8)),
    );
  }

  Widget _buildContactCoil(LdNode n, {required bool live, required bool lit}) {
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
    // `color` is the static face color (amberAccent for coils, greenAccent for
    // contacts). When live, override it with the energized/de-energized palette.
    final Color faceColor = !live ? color : (lit ? _kEnergized : _kDeEnergized);
    return Container(
      decoration: BoxDecoration(
        color: lit ? _kEnergized.withValues(alpha: 0.12) : const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: faceColor, width: 1.5),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Symbol glyph centred on the cell — the wire (drawn at the cell's
          // vertical centre) passes through it.
          Text(symbol,
              maxLines: 1,
              style: TextStyle(
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: faceColor)),
          // Tag name captioned just above the glyph.
          Positioned(
            top: 4,
            left: 2,
            right: 2,
            child: Text(n.variable,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 9,
                    color: faceColor,
                    fontFamily: 'monospace')),
          ),
        ],
      ),
    );
  }

  Widget _buildBlock(LdNode n, {required bool live, required bool lit}) {
    if (_isCompareBlock(n.blockType) || _isMathBlock(n.blockType)) {
      return _buildDataBlock(n, live: live, lit: lit);
    }
    final Color borderColor =
        !live ? Colors.grey.shade500 : (lit ? _kEnergized : _kDeEnergized);
    final isCounter = _isCounterBlock(n.blockType);
    String topLeft;
    String topRight;
    String bottomLeft;
    String bottomRight;
    String presetLine;
    if (isCounter) {
      presetLine = live
          ? 'CV ${_liveNum('${n.variable}.CV')} / ${n.presetMs}'
          : 'PV ${n.presetMs}';
      switch (n.blockType) {
        case 'CTD':
          topLeft = 'CD';
          topRight = 'QD';
          break;
        case 'CTUD':
          topLeft = 'CU';
          topRight = 'QU';
          break;
        default: // CTU
          topLeft = 'CU';
          topRight = 'QU';
      }
      bottomLeft = 'PV';
      bottomRight = 'CV';
    } else {
      topLeft = 'IN';
      topRight = 'Q';
      presetLine = live
          ? '${_liveNum('${n.variable}.ACC')} / ${n.presetMs} ms'
          : 'PT ${n.presetMs}ms';
      bottomLeft = 'PT';
      bottomRight = 'ET';
    }
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: borderColor, width: 1.5),
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
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.white, fontFamily: 'monospace'),
                textAlign: TextAlign.center),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(n.variable,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 8, color: Colors.cyanAccent, fontFamily: 'monospace')),
                _BlockPinRow(left: topLeft, right: topRight),
                Text(presetLine,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 7, color: Colors.grey)),
                _BlockPinRow(left: bottomLeft, right: bottomRight),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Compare (GT/LT/GE/LE/EQ/NE) and math (ADD/SUB/MUL/DIV/MOVE) blocks share
  /// a two-row operand body: operand A on top, the operator glyph centred,
  /// operand B below — with a left `EN` pin and a right pin (`Q` for
  /// compare, `ENO` for math).
  Widget _buildDataBlock(LdNode n, {required bool live, required bool lit}) {
    final isCompare = _isCompareBlock(n.blockType);
    final rightPin = isCompare ? 'Q' : 'ENO';
    final glyph = _blockOperatorGlyph(n.blockType);
    final Color borderColor =
        !live ? Colors.grey.shade500 : (lit ? _kEnergized : _kDeEnergized);
    String liveOperand(String s) {
      final literal = num.tryParse(s);
      if (literal != null) {
        return s;
      }
      return live ? _liveNum(s) : s;
    }
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: borderColor, width: 1.5),
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
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.white, fontFamily: 'monospace'),
                textAlign: TextAlign.center),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _BlockPinRow(left: 'EN', right: rightPin),
                Text(liveOperand(n.operandA),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 9, color: Colors.white, fontFamily: 'monospace'),
                    textAlign: TextAlign.center),
                Text(glyph,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.amberAccent, fontFamily: 'monospace'),
                    textAlign: TextAlign.center),
                Text(liveOperand(n.operandB),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 9, color: Colors.white, fontFamily: 'monospace'),
                    textAlign: TextAlign.center),
                // Math blocks write a result — surface its destination on the
                // block face for parity with timer/counter blocks (compare
                // blocks have no output tag, so `variable` instead holds an
                // optional user-assigned name — shown only when set so
                // unnamed compare blocks keep their original compact face).
                if (!isCompare)
                  Text(live ? '→ ${n.variable} = ${_liveNum(n.variable)}' : '→ ${n.variable}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 7, color: Colors.cyanAccent, fontFamily: 'monospace'),
                      textAlign: TextAlign.center)
                else if (n.variable.isNotEmpty)
                  Text(n.variable,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 7, color: Colors.cyanAccent, fontFamily: 'monospace'),
                      textAlign: TextAlign.center),
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

    LdNode? nodeById(String id) {
      for (final n in rung.nodes) {
        if (n.id == id) {
          return n;
        }
      }
      return null;
    }

    for (final w in rung.wires) {
      final src = nodeById(w.fromId);
      final dst = nodeById(w.toId);
      if (src == null || dst == null) {
        continue;
      }
      // Live power flow: a wire is energized iff its source node is. Offline,
      // `paint` already carries its initial greenAccent/2.0 values, so there
      // is nothing to reset here.
      if (s._online) {
        final lit = s._nodeLit(rung, src);
        paint.color = lit ? _LdEditorScreenState._kEnergized : _LdEditorScreenState._kDeEnergized;
        paint.strokeWidth = lit ? 3.0 : 2.0;
      }
      final p1 = s._outPort(rung, src, col, width);
      final p2 = s._inPort(rung, dst, col, width);
      final path = Path()..moveTo(p1.dx, p1.dy);
      if (src.row == dst.row) {
        path.lineTo(p2.dx, p2.dy);
      } else if (dst.row > src.row) {
        // Descending into a deeper branch lane: riser centred in the gap
        // BEFORE the branch element (the destination).
        final riserX = ldRiserXBefore(col[dst.id] ?? 0);
        path.lineTo(riserX, p1.dy);
        path.lineTo(riserX, p2.dy);
        path.lineTo(p2.dx, p2.dy);
      } else {
        // Returning to a shallower lane: riser centred in the gap AFTER the
        // branch element (the source).
        final riserX = ldRiserXAfter(col[src.id] ?? 0);
        path.lineTo(riserX, p1.dy);
        path.lineTo(riserX, p2.dy);
        path.lineTo(p2.dx, p2.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _LadderPainter old) => true;
}
