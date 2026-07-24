import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import '../models/fb_instance.dart';
import '../models/fbd_monitor.dart';
import '../models/fbd_pins.dart';
import '../models/fbd_layout.dart';
import '../models/fbd_networks.dart';
import '../models/project_model.dart';
import '../ui/responsive.dart';
import '../widgets/live_tick.dart';
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

  /// Live per-block pin-value tap populated by the scan (Task 2). Read only
  /// when the session-only Go-Online toggle is on; otherwise the editor is
  /// fully static. Optional (and `scanRunning` defaults false) so existing
  /// call sites/tests that predate the online overlay keep compiling.
  final FbdMonitor? monitor;

  /// Whether the scan is actually running (mirrors the LD/SFC editors'
  /// `scanRunning`). Drives the LIVE / FROZEN badge; when false the monitored
  /// values simply stop changing (frozen view).
  final bool scanRunning;

  const FbdEditorScreen({
    super.key,
    required this.currentProject,
    required this.program,
    required this.onProgramUpdated,
    this.monitor,
    this.scanRunning = false,
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

  // Session-only "Go-Online" live-monitor toggle. When true, wires/pins
  // reflect the last scan's values (via widget.monitor); default false so the
  // static editor view is byte-for-byte unchanged. Never persisted.
  bool _online = false;

  // Fallback repaint pulse used only when no [LiveTickScope] is present in the
  // ancestor tree (e.g. widget tests that pump the editor standalone). In the
  // app the shell provides the real scan-driven tick.
  final LiveTick _fallbackTick = LiveTick();

  // Energized/de-energized palette for the live "online" view (mirrors the
  // LD/SFC editors).
  static const Color _kEnergized = Colors.greenAccent;
  static const Color _kDeEnergized = Color(0xFF475569); // slate-600

  // Lane-list scrolling + the network navigator rail. One stable GlobalKey per
  // lane (grown/trimmed in [_buildLaneList] to match the network count) lets the
  // rail scroll a given lane into view; [_activeNet] tracks which lane is at the
  // top so the rail can highlight it.
  final ScrollController _laneScroll = ScrollController();
  final List<GlobalKey> _laneKeys = [];
  int _activeNet = 0;

  @override
  void initState() {
    super.initState();
    _ensureDefaultFbd();
    _ensureNetworks();
    _laneScroll.addListener(_onLaneScroll);
  }

  @override
  void dispose() {
    for (final c in _commentControllers.values) {
      c.dispose();
    }
    _laneScroll.removeListener(_onLaneScroll);
    _laneScroll.dispose();
    _fallbackTick.dispose();
    super.dispose();
  }

  /// The scroll offset at which lane [i]'s leading edge aligns with the viewport
  /// top, or null if the lane isn't laid out yet. Used both to detect the active
  /// lane and to jump to it.
  double? _laneRevealOffset(int i) {
    if (i < 0 || i >= _laneKeys.length) {
      return null;
    }
    final ctx = _laneKeys[i].currentContext;
    final ro = ctx?.findRenderObject();
    if (ro == null || !ro.attached) {
      return null;
    }
    return RenderAbstractViewport.of(ro).getOffsetToReveal(ro, 0).offset;
  }

  /// Track which lane sits at the top of the viewport so the rail highlights it:
  /// the last lane whose reveal offset has scrolled to (or above) the current
  /// position. Defensive — never throws during layout churn.
  void _onLaneScroll() {
    if (!_laneScroll.hasClients) {
      return;
    }
    final pos = _laneScroll.offset;
    var active = 0;
    for (var i = 0; i < _laneKeys.length; i++) {
      final reveal = _laneRevealOffset(i);
      if (reveal != null && reveal <= pos + 8) {
        active = i;
      }
    }
    if (active != _activeNet && mounted) {
      setState(() => _activeNet = active);
    }
  }

  // Approximate fixed chrome around each lane's canvas (network header row +
  // bottom margin + border), used to compute a lane's scroll offset without
  // needing the (possibly not-yet-built) off-screen lane's render box.
  static const double _kLaneHeaderChrome = 40; // header row
  static const double _kLaneOuterChrome = 12 + 2; // bottom margin + border

  double _laneOuterHeight(int net) =>
      _kLaneHeaderChrome + _laneCanvasHeight(net) + _kLaneOuterChrome;

  /// The scroll offset that brings lane [net]'s top to the viewport top,
  /// computed from cumulative lane heights (works even when the target lane is
  /// off-screen and hence not built — a lazy ListView won't have its context).
  double _laneTopOffset(int net) {
    var y = 8.0; // ListView top padding
    for (var k = 0; k < net && k < _laneKeys.length; k++) {
      y += _laneOuterHeight(k);
    }
    return y;
  }

  /// Scroll lane [net] to the top of the viewport (rail tap target).
  void _scrollToNetwork(int net) {
    if (!_laneScroll.hasClients || net < 0) {
      return;
    }
    final target = _laneTopOffset(net).clamp(0.0, _laneScroll.position.maxScrollExtent);
    _laneScroll.animateTo(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
    if (mounted) {
      setState(() => _activeNet = net);
    }
  }

  // -----------------------------------------------------------------
  // Live-value overlay helpers (Task 6)
  // -----------------------------------------------------------------

  /// The monitored value at (blockId, pin), or null if not online / no
  /// monitor / never recorded.
  dynamic _pinMonitorValue(String blockId, String pin) {
    if (!_online) return null;
    final m = widget.monitor;
    if (m == null) return null;
    return m.pinValue[m.keyFor(widget.program.name, blockId, pin)];
  }

  /// Resolves a wire's effective source output pin, falling back to the
  /// source block's first output pin when the wire predates pin-addressing.
  /// Mirrors `_resolvedFromPin` in `fbd_exec.dart` (private there, so this is
  /// a local copy over the same pure `fbdOutputPins` registry).
  String _resolvedWireFromPin(FbdWire w, FbdBlock? fromBlock) {
    if (w.fromPin.isNotEmpty) return w.fromPin;
    if (fromBlock == null) return '';
    final outs = fbdOutputPins(fromBlock.type);
    return outs.isNotEmpty ? outs.first : '';
  }

  /// Compact live-value text: bools as TRUE/FALSE, ints as-is, other numbers
  /// to 2dp.
  String _formatMonitorValue(dynamic v) {
    if (v is bool) return v ? 'TRUE' : 'FALSE';
    if (v is int) return '$v';
    if (v is num) return v.toStringAsFixed(2);
    return v?.toString() ?? '';
  }

  /// Every wire's carried value, keyed by its index in `program.fbdWires`
  /// (empty map when offline).
  Map<int, dynamic> _wireValues() {
    if (!_online) return const {};
    final result = <int, dynamic>{};
    final wires = widget.program.fbdWires;
    for (var i = 0; i < wires.length; i++) {
      final w = wires[i];
      final fromBlock = _blockById(w.fromBlockId);
      final fromPin = _resolvedWireFromPin(w, fromBlock);
      if (fromPin.isEmpty) continue;
      final v = _pinMonitorValue(w.fromBlockId, fromPin);
      if (v != null) result[i] = v;
    }
    return result;
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
  ///
  /// Also self-heals two forms of corrupt/hand-edited project data that can
  /// only reach the editor via untrusted JSON (no in-app path produces
  /// them): a block `network` index far beyond any reasonable header count
  /// (capped at `kMaxFbdNetworks`, mirroring
  /// `PlcProgram._normalizeFbdNetworks`, so this can't OOM/hang either), and
  /// a wire whose endpoints ended up in different networks (pruned via
  /// `pruneCrossNetworkWires` so it doesn't linger and survive re-save).
  void _ensureNetworks() {
    final maxNet = widget.program.fbdBlocks
        .fold<int>(-1, (m, b) => b.network > m ? b.network : m);
    final rawNeeded = maxNet + 1 < 1 ? 1 : maxNet + 1;
    final needed =
        rawNeeded > kMaxFbdNetworks ? kMaxFbdNetworks : rawNeeded;
    while (widget.program.fbdNetworks.length < needed) {
      widget.program.fbdNetworks.add(FbdNetwork());
    }
    // A corrupt block network index can still exceed the capped header list
    // built above; clamp it into range so every block.network stays a valid
    // index (never throws, never leaves a dangling reference).
    final maxIndex = widget.program.fbdNetworks.length - 1;
    if (maxIndex >= 0) {
      for (final b in widget.program.fbdBlocks) {
        if (b.network < 0 || b.network > maxIndex) {
          b.network = maxIndex;
        }
      }
    }
    pruneCrossNetworkWires(widget.program);
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

  /// Adds a new instance of custom function block [fb]: a uniquely-named
  /// backing tag (`dataType == fb.name`, struct-shaped default value — see
  /// `fb_instance.dart`) plus an `FbdBlock` whose `type` is the FB's name and
  /// whose `tagBinding` points at that new tag. Mirrors `_addFbdBlock` above
  /// but, unlike it, always creates a fresh instance tag rather than
  /// re-binding an existing one — each FB instance needs its own private
  /// backing storage (EN/DN/CV-equivalents), so reusing another tag would
  /// alias two unrelated instances together.
  void _addFbBlockInstance(FbDefinition fb, {int network = 0}) {
    final netCount = widget.program.fbdNetworks.length;
    final targetNet = (network >= 0 && network < netCount) ? network : 0;
    final tag = createFbInstanceTag(widget.currentProject, fb);

    final newBlock = FbdBlock(
      id: 'b_${DateTime.now().millisecondsSinceEpoch}',
      type: fb.name,
      title: fb.name,
      tagBinding: tag.name,
      x: 150,
      y: 150,
      network: targetNet,
    );

    setState(() {
      widget.currentProject.tags.add(tag);
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
              final removedNetwork = widget.program.fbdNetworks[net];
              setState(() {
                deleteFbdNetwork(widget.program, net);
                _selectedWireIndex = null;
                _armedBlockId = null;
                _armedPin = null;
              });
              // The deleted network's comment controller is no longer bound to
              // any TextField — dispose it now instead of leaving it to linger
              // (keyed by instance) until the whole screen is disposed.
              _commentControllers.remove(removedNetwork)?.dispose();
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
    // Keep one stable GlobalKey per lane so the rail can scroll each into view.
    while (_laneKeys.length < nets.length) {
      _laneKeys.add(GlobalKey());
    }
    if (_laneKeys.length > nets.length) {
      _laneKeys.removeRange(nets.length, _laneKeys.length);
    }
    final list = Container(
      color: const Color(0xFF0F172A),
      child: ListView(
        controller: _laneScroll,
        padding: const EdgeInsets.all(8),
        children: [
          for (var i = 0; i < nets.length; i++) _buildLane(i, expanded, _laneKeys[i]),
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
    // The network navigator rail is only useful with more than one network.
    if (nets.length < 2) {
      return list;
    }
    return Row(
      children: [
        _buildNetworkRail(nets.length),
        const VerticalDivider(width: 1, color: Colors.white12),
        Expanded(child: list),
      ],
    );
  }

  /// A slim vertical rail of network numbers; tapping one scrolls that network's
  /// lane to the top. The current (topmost) lane is highlighted. Itself
  /// scrollable so it copes with many networks.
  Widget _buildNetworkRail(int count) {
    return Container(
      key: const Key('fbd_network_rail'),
      width: 46,
      color: const Color(0xFF162032),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: count,
        itemBuilder: (_, i) {
          final active = i == _activeNet;
          return Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
            child: Tooltip(
              message: 'Go to Network ${i + 1}',
              child: InkWell(
                key: Key('fbd_rail_$i'),
                onTap: () => _scrollToNetwork(i),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: active
                        ? Colors.tealAccent.withValues(alpha: 0.18)
                        : Colors.transparent,
                    border: Border.all(
                      color: active ? Colors.tealAccent : Colors.white24,
                    ),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: active ? Colors.tealAccent : Colors.white70,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildLane(int net, bool expanded, [Key? key]) {
    // While online, rebuild just this lane's canvas on each LiveTick pulse so
    // its wire/pin values track the scan — the header (name/comment/arrange
    // buttons) never needs to repaint per-tick, so only the canvas child is
    // wrapped. Offline, this is a pass-through and the static path is
    // byte-for-byte unchanged.
    Widget canvas = _buildLaneCanvas(net, expanded);
    if (_online) {
      final tick =
          context.getInheritedWidgetOfExactType<LiveTickScope>()?.notifier ?? _fallbackTick;
      canvas = ListenableBuilder(
        listenable: tick,
        builder: (_, __) => _buildLaneCanvas(net, expanded),
      );
    }
    return Container(
      key: key,
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
            child: canvas,
          ),
        ],
      ),
    );
  }

  /// A bounded viewport height sized to comfortably contain this network's
  /// blocks (so nothing important sits clipped off-stage), clamped to a sane
  /// range. Panning still reaches the full content canvas (see
  /// [fbdCanvasGeometry]) and beyond via the unbounded pan margin.
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
    // -> offset within the lane's canvas content. Kept local (not a shared
    // field) so sibling lanes never clobber each other's anchors.
    final anchors = <String, Offset>{};
    final blocks = fbdBlocksInNetwork(widget.program, net);

    // Canvas geometry: an offset that pulls blocks placed at negative
    // coordinates back inside the positive, hit-testable, gridded box (so an
    // off-grid block can still be dragged rather than panning the page), plus
    // the box size. Block/anchor render positions add this offset; the stored
    // block coordinates are untouched.
    final geo = fbdCanvasGeometry(widget.program, net);
    final ox = geo.offsetX;
    final oy = geo.offsetY;

    final blockWidgets = blocks.map((block) {
      return Positioned(
        left: block.x + ox,
        top: block.y + oy,
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
    // Anchors are in canvas space, so they include the render offset too.
    for (final block in blocks) {
      final inputs = fbdInputPinsFor(widget.currentProject, block);
      final outputs = fbdOutputPinsFor(widget.currentProject, block);
      for (var i = 0; i < inputs.length; i++) {
        final dy = _kHeaderHeight + i * _kPinRowHeight + _kPinRowHeight / 2;
        anchors['${block.id}|IN|${inputs[i]}'] = Offset(block.x + ox, block.y + oy + dy);
      }
      for (var i = 0; i < outputs.length; i++) {
        final dy = _kHeaderHeight + i * _kPinRowHeight + _kPinRowHeight / 2;
        anchors['${block.id}|OUT|${outputs[i]}'] =
            Offset(block.x + ox + _kBlockWidth, block.y + oy + dy);
      }
    }

    final stack = Stack(
      // Don't clip to the sized content area: a block dragged above/left of the
      // origin (or beyond the sized extent) must still render, so the canvas
      // feels unlimited in every direction.
      clipBehavior: Clip.none,
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
                wireValues: _wireValues(),
              ),
            ),
          ),
        ),

        // Tap targets over each wire midpoint for selection (simple circular
        // hit areas placed at the wire midpoint).
        ..._buildWireHitTargets(anchors),

        // Online only: the value each wire carries, as compact text above its
        // midpoint (numbers ~2dp, TRUE/FALSE for bool).
        if (_online) ..._buildWireValueLabels(anchors),

        // Online only: every output pin's own monitored value (Q/ET/CV/... on
        // stateful blocks, plus AND/OR/compare/etc.), shown at the pin
        // itself — independent of whether that pin happens to be wired, so
        // an unwired output still reads live. Positioned as an overlay (not
        // inside the fixed-width block card) so it can never overflow the
        // card's layout regardless of value length.
        if (_online) ..._buildPinValueLabels(anchors, blocks),

        // FBD Blocks
        ...blockWidgets,
      ],
    );

    // Size the logical canvas to actually contain this network's blocks (plus
    // breathing room), floored at a comfortable default. Auto-arrange or hand
    // placement can push blocks well past the old fixed 1600×1200 area; sizing
    // to content (with the negative-side offset above) means every block is
    // inside the box and never clipped off-stage or un-draggable.
    final content = SizedBox(
      width: geo.width,
      height: geo.height,
      child: stack,
    );

    // The lane pans/zooms on every platform. On desktop (expanded) individual
    // blocks stay draggable via their own pan handler — dragging a block moves
    // the block, dragging the empty background pans the canvas. An unbounded
    // pan margin lets you scroll to blocks placed anywhere around the diagram,
    // including above/left of the origin.
    return Container(
      color: const Color(0xFF0F172A),
      child: InteractiveViewer(
        constrained: false,
        minScale: 0.4,
        maxScale: 2.5,
        boundaryMargin: const EdgeInsets.all(double.infinity),
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

  /// Compact value readouts positioned just above each wire's midpoint,
  /// mirroring the LD editor's live block-face readouts. Only wires whose
  /// endpoints resolve to anchors in this lane (i.e. not cross-lane) and that
  /// carry a recorded monitor value get a label; a non-IEEE/unset value is
  /// silently skipped (never throws).
  List<Widget> _buildWireValueLabels(Map<String, Offset> anchors) {
    final widgets = <Widget>[];
    final wires = widget.program.fbdWires;
    for (var i = 0; i < wires.length; i++) {
      final w = wires[i];
      final fromBlock = _blockById(w.fromBlockId);
      final fromPin = _resolvedWireFromPin(w, fromBlock);
      final toBlock = _blockById(w.toBlockId);
      final toPin = w.toPin.isNotEmpty
          ? w.toPin
          : (toBlock != null && fbdInputPinsFor(widget.currentProject, toBlock).isNotEmpty
              ? fbdInputPinsFor(widget.currentProject, toBlock).first
              : '');
      final from = anchors['${w.fromBlockId}|OUT|$fromPin'];
      final to = anchors['${w.toBlockId}|IN|$toPin'];
      if (from == null || to == null) continue;

      final value = _pinMonitorValue(w.fromBlockId, fromPin);
      if (value == null) continue;

      final energized = value == true;
      final deEnergized = value == false;
      final color = energized ? _kEnergized : (deEnergized ? _kDeEnergized : Colors.lightBlueAccent);
      final mid = Offset((from.dx + to.dx) / 2, (from.dy + to.dy) / 2);

      widgets.add(Positioned(
        left: mid.dx - 30,
        top: mid.dy - 26,
        width: 60,
        child: IgnorePointer(
          child: Container(
            key: Key('fbdwireval_$i'),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
            decoration: BoxDecoration(
              color: const Color(0xCC0F172A),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: color.withValues(alpha: 0.7)),
            ),
            child: Text(
              _formatMonitorValue(value),
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: color),
            ),
          ),
        ),
      ));
    }
    return widgets;
  }

  /// Compact value readouts anchored right at each block's own output pins
  /// (Q/ET/CV/... on stateful blocks, OUT on gates/compares/math/CONST/...),
  /// independent of whether that pin is wired — an unwired output still reads
  /// live. Positioned relative to the pin anchor (just outside the block's
  /// right edge), never inside the block card, so it can't affect the card's
  /// fixed-width internal layout.
  List<Widget> _buildPinValueLabels(Map<String, Offset> anchors, List<FbdBlock> blocks) {
    final widgets = <Widget>[];
    for (final block in blocks) {
      for (final pin in fbdOutputPinsFor(widget.currentProject, block)) {
        final anchor = anchors['${block.id}|OUT|$pin'];
        if (anchor == null) continue;
        final value = _pinMonitorValue(block.id, pin);
        if (value == null) continue;

        final energized = value == true;
        final deEnergized = value == false;
        final color = energized ? _kEnergized : (deEnergized ? _kDeEnergized : Colors.lightBlueAccent);

        widgets.add(Positioned(
          left: anchor.dx + 4,
          top: anchor.dy - 8,
          width: 46,
          child: IgnorePointer(
            child: Container(
              key: Key('fbdpinval_${block.id}_$pin'),
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xCC0F172A),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: color.withValues(alpha: 0.7)),
              ),
              child: Text(
                _formatMonitorValue(value),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: color),
              ),
            ),
          ),
        ));
      }
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
          // scrollable: true wraps title+content in a SingleChildScrollView so
          // a tall dialog (e.g. an extensible block's extra "Inputs:" row) can
          // never overflow vertically at a short/narrow viewport like 320x568
          // — it scrolls instead.
          scrollable: true,
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
                // Plain GestureDetector + bare Icon (not the 44px-min-width
                // touchable()/IconButton used elsewhere) — at a 320px dialog
                // width the content area is only ~160px, and two 44px touch
                // targets plus the label and counter don't fit on one Row
                // (this used to overflow by 36px). This mirrors the
                // compact edit-affordance pattern already used on the block
                // card header further down in this file.
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Inputs:', style: TextStyle(fontSize: 12, color: Colors.grey)),
                    const SizedBox(width: 8),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setDlgState(() => _changeInputCount(block, -1)),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Icon(Icons.remove_circle_outline, size: 20),
                      ),
                    ),
                    Text('${block.inputCount}', style: const TextStyle(fontWeight: FontWeight.bold)),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setDlgState(() => _changeInputCount(block, 1)),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Icon(Icons.add_circle_outline, size: 20),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('Network:', style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(width: 8),
                  // Expanded + isExpanded:true so the dropdown shrinks to fit
                  // the dialog's content width (as narrow as a 320px phone)
                  // instead of sizing to its own intrinsic width and
                  // overflowing the Row.
                  Expanded(
                    child: DropdownButton<int>(
                      key: const Key('fbd_block_network_dropdown'),
                      value: block.network,
                      isExpanded: true,
                      items: [
                        for (var i = 0; i < widget.program.fbdNetworks.length; i++)
                          DropdownMenuItem(value: i, child: Text('Network ${i + 1}')),
                      ],
                      onChanged: (newNet) {
                        if (newNet == null) return;
                        // Applied immediately (not deferred to Save), mirroring
                        // every other network-membership mutation in this
                        // screen — reuses setBlockNetwork so cross-network
                        // wires get pruned the same way everywhere else.
                        setState(() => setBlockNetwork(widget.program, block.id, newNet));
                        widget.onProgramUpdated();
                        setDlgState(() {});
                      },
                    ),
                  ),
                ],
              ),
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
            key: const Key('fbd_online_toggle'),
            icon: Icon(Icons.sensors, color: _online ? Colors.greenAccent : Colors.grey),
            tooltip: _online ? 'Go Offline (stop live monitor)' : 'Go Online (live monitor)',
            onPressed: () => setState(() => _online = !_online),
          ),
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
                // Custom function blocks: dynamic entries appended AFTER every
                // built-in above, one per project FbDefinition. Zero FBs means
                // zero extra widgets here — byte-identical to pre-FB behavior.
                if (widget.currentProject.fbDefinitions.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Divider(color: Colors.white12, height: 1),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text('FUNCTION BLOCKS', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.grey)),
                  ),
                  for (final fb in widget.currentProject.fbDefinitions)
                    _buildFbPaletteItem(fb, targetNetwork),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFbPaletteItem(FbDefinition fb, int targetNetwork) {
    if (_searchQuery.isNotEmpty && !fb.name.toLowerCase().contains(_searchQuery.toLowerCase())) {
      return const SizedBox.shrink();
    }
    return Card(
      color: const Color(0xFF1E293B),
      margin: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: ListTile(
          dense: true,
          leading: const Icon(Icons.extension, color: Colors.pinkAccent, size: 18),
          title: Text(fb.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
          subtitle: const Text('Custom Function Block', style: TextStyle(fontSize: 10, color: Colors.grey)),
          trailing: IconButton(
            icon: const Icon(Icons.add, color: Colors.tealAccent, size: 18),
            onPressed: () {
              _addFbBlockInstance(fb, network: targetNetwork);
              if (!context.isExpanded && Navigator.of(context).canPop()) {
                Navigator.of(context).pop();
              }
            },
          ),
        ),
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
    final armed = !isInput && _armedBlockId == block.id && _armedPin == pin;
    final key = Key('fbdpin_${block.id}_${isInput ? 'in' : 'out'}_$pin');

    // Live monitored value at this pin. The monitor only records per-block
    // OUTPUT values (mirrors `fbd_exec.dart`'s recording site), so this is
    // null for input pins — their live value is shown on the feeding wire
    // instead (see `_buildWireValueLabels`). Covers Task 6's "stateful block
    // outputs (Q/ET/CV/...) show their monitored values at the pins".
    final monVal = !isInput ? _pinMonitorValue(block.id, pin) : null;
    final energized = monVal == true;
    final deEnergized = monVal == false;

    Color color;
    if (energized) {
      color = _kEnergized;
    } else if (deEnergized) {
      color = _kDeEnergized;
    } else {
      color = _pinColor(pin);
    }

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

    final inputs = fbdInputPinsFor(widget.currentProject, block);
    final outputs = fbdOutputPinsFor(widget.currentProject, block);
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
                if (showInlineEditors) ...[
                  // Always-present edit affordance: on desktop (expanded) the
                  // outer Positioned > GestureDetector's onTap is null (that
                  // slot is claimed by onPanUpdate for block dragging), so
                  // this is the only route into _showConfigureBlockDialog for
                  // every block type — not just TAG_*/CONST, which used to be
                  // the sole types with a pencil affordance further down.
                  // Plain GestureDetector + bare Icon (not IconButton) to keep
                  // the footprint to the icon's own size — the 180px-wide
                  // card header has no room to spare for two IconButtons'
                  // built-in tap-target padding.
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _showConfigureBlockDialog(block),
                    child: const Icon(Icons.edit, size: 14, color: Colors.tealAccent),
                  ),
                  const SizedBox(width: 6),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _deleteBlock(block),
                    child: const Icon(Icons.close, size: 14, color: Colors.redAccent),
                  ),
                ],
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
              // The header's edit pencil (added above, present for every
              // block type) is now the route into the config dialog, so this
              // row just displays the binding — no second pencil needed.
              Text(
                block.tagBinding.isNotEmpty ? block.tagBinding : '(unset)',
                style: const TextStyle(fontSize: 10, color: Colors.grey),
                overflow: TextOverflow.ellipsis,
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
/// target input-pin anchor. The selected wire (if any) is highlighted. While
/// online, [wireValues] (index -> monitored value, from `_wireValues()`)
/// recolors a boolean-carrying wire energized (true, green) or de-energized
/// (false, dim slate) — mirroring the LD editor's power-flow coloring; a
/// numeric/unset value leaves the wire's static color unchanged.
class _WirePainter extends CustomPainter {
  final List<FbdWire> wires;
  final Map<String, Offset> anchors;
  final int? selectedIndex;
  final Map<int, dynamic> wireValues;

  static const Color _kEnergized = Colors.greenAccent;
  static const Color _kDeEnergized = Color(0xFF475569); // slate-600

  _WirePainter({
    required this.wires,
    required this.anchors,
    required this.selectedIndex,
    this.wireValues = const {},
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < wires.length; i++) {
      final w = wires[i];
      final from = anchors['${w.fromBlockId}|OUT|${w.fromPin}'];
      final to = anchors['${w.toBlockId}|IN|${w.toPin}'];
      if (from == null || to == null) continue;

      final selected = selectedIndex == i;
      final value = wireValues[i];
      Color baseColor;
      if (value == true) {
        baseColor = _kEnergized;
      } else if (value == false) {
        baseColor = _kDeEnergized;
      } else {
        baseColor = Colors.tealAccent.withValues(alpha: 0.8);
      }
      final paint = Paint()
        ..color = selected ? Colors.orangeAccent : baseColor
        ..strokeWidth = selected ? 3 : 2
        ..style = PaintingStyle.stroke;

      final path = Path()..moveTo(from.dx, from.dy);
      final dx = (to.dx - from.dx).abs().clamp(24.0, 120.0);
      path.cubicTo(from.dx + dx, from.dy, to.dx - dx, to.dy, to.dx, to.dy);
      canvas.drawPath(path, paint);
    }
  }

  bool _wireValuesEqual(Map<int, dynamic> a, Map<int, dynamic> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) || b[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  bool shouldRepaint(covariant _WirePainter oldDelegate) {
    return oldDelegate.wires != wires ||
        oldDelegate.anchors != anchors ||
        oldDelegate.selectedIndex != selectedIndex ||
        !_wireValuesEqual(oldDelegate.wireValues, wireValues);
  }
}
