import 'package:flutter/material.dart';
import '../models/project_model.dart';
import '../models/sfc_edit.dart';
import '../models/sfc_exec.dart';
import '../models/sfc_region.dart';
import '../models/sfc_layout2.dart';
import '../ui/responsive.dart';
import '../widgets/live_tick.dart';
import '../widgets/tag_autocomplete_field.dart';

/// Padding inside the scroll content, around the laid-out chart, so boxes at
/// x=0 / y=0 are not flush against the canvas edge. Applied to both the
/// positioned boxes and the connector painter.
const double _kCanvasPad = 28.0;

class SfcEditorScreen extends StatefulWidget {
  final PlcProject currentProject;
  final PlcProgram program;
  final VoidCallback onProgramUpdated;

  /// Live active-step state populated by the scan (Task 2). Read only when the
  /// session-only Go-Online toggle is on; otherwise the editor is fully static.
  final SfcRuntime sfcRuntime;

  /// Whether the scan is actually running (mirrors the LD editor's
  /// `scanRunning`). Drives the LIVE / FROZEN badge; when false the active set
  /// simply stops changing (frozen view).
  final bool scanRunning;

  const SfcEditorScreen({
    super.key,
    required this.currentProject,
    required this.program,
    required this.onProgramUpdated,
    required this.sfcRuntime,
    required this.scanRunning,
  });

  @override
  State<SfcEditorScreen> createState() => _SfcEditorScreenState();
}

class _SfcEditorScreenState extends State<SfcEditorScreen> {
  // Session-only "Go-Online" live-monitor toggle. When true, active step boxes
  // glow energized and show their live STEP_T; default false so the static
  // editor view is unchanged. Never persisted.
  bool _online = false;

  // Fallback repaint pulse used only when no [LiveTickScope] is present in the
  // ancestor tree (e.g. widget tests that pump the editor standalone). In the
  // app the shell provides the real scan-driven tick.
  final LiveTick _fallbackTick = LiveTick();

  // Energized accent for the live "online" view (mirrors the LD monitor).
  static const Color _kEnergized = Colors.greenAccent;

  @override
  void dispose() {
    _fallbackTick.dispose();
    super.dispose();
  }

  /// Whether [step] is in the live active set (only meaningful while online).
  bool _isActive(SfcStep step) =>
      _online &&
      (widget.sfcRuntime.active[widget.program.name]?.contains(step.id) ?? false);

  /// Compact STEP_T label for an active step (ms below a second, else seconds).
  String _stepTLabel(SfcStep step) {
    final ms = widget.sfcRuntime.stepElapsedMs['${widget.program.name}|${step.id}'] ?? 0;
    final formatted = ms < 1000 ? '${ms}ms' : '${(ms / 1000).toStringAsFixed(1)}s';
    return 'STEP_T $formatted';
  }

  void _addNewStep() {
    setState(() {
      addSfcStep(widget.program);
    });
    widget.onProgramUpdated();
  }

  void _openTagPaletteSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.75,
          child: _buildTagPaletteDock(),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 2D pan/zoom canvas (SFC-v2): region parser -> 2D layout -> positioned boxes
  // + a connector painter. Mirrors the FBD/LD editors' InteractiveViewer +
  // Stack(CustomPaint + Positioned...) pattern.
  // ---------------------------------------------------------------------------

  Widget _buildCanvas() {
    // Offline: a plain static canvas, no per-tick repaint.
    if (!_online) {
      return _buildCanvasContent();
    }
    // Online: repaint the canvas on each LiveTick pulse so active-step glow and
    // STEP_T track the scan. Falls back to a local (never-pulsed) tick when no
    // LiveTickScope is present, so the highlight still renders one-shot.
    final tick =
        context.getInheritedWidgetOfExactType<LiveTickScope>()?.notifier ?? _fallbackTick;
    return ListenableBuilder(
      listenable: tick,
      builder: (context, _) => _buildCanvasContent(),
    );
  }

  Widget _buildCanvasContent() {
    final region = parseSfc(widget.program.sfcSteps, widget.program.sfcTransitions);
    final layout = layoutSfcRegion(region);

    final stack = Stack(
      children: [
        Positioned.fill(
          child: CustomPaint(painter: _SfcPainter(layout)),
        ),
        for (final b in layout.boxes) _positionedBox(b),
      ],
    );

    return Container(
      color: const Color(0xFF0F172A),
      child: InteractiveViewer(
        constrained: false,
        minScale: 0.4,
        maxScale: 2.5,
        boundaryMargin: const EdgeInsets.all(200),
        child: SizedBox(
          width: layout.width + _kCanvasPad * 2,
          height: layout.height + _kCanvasPad * 2,
          child: stack,
        ),
      ),
    );
  }

  Widget _positionedBox(SfcBox b) {
    switch (b.kind) {
      case 'step':
        // Fixed height: the step box content (badge + name + action preview)
        // fills the laid-out box exactly.
        return Positioned(
          left: b.x + _kCanvasPad,
          top: b.y + _kCanvasPad,
          width: b.w,
          height: b.h,
          child: _stepBox(b.step!),
        );
      case 'trans':
        // Height-intrinsic so the inline condition field never overflows a
        // fixed box on a narrow screen; width is pinned to the laid-out block.
        return Positioned(
          left: b.x + _kCanvasPad,
          top: b.y + _kCanvasPad,
          width: b.w,
          child: _transBlock(b.transition!),
        );
      case 'goto':
        return Positioned(
          left: b.x + _kCanvasPad,
          top: b.y + _kCanvasPad,
          width: b.w,
          child: _gotoChip(b.transition!),
        );
      case 'forkBar':
      case 'joinBar':
        return Positioned(
          left: b.x + _kCanvasPad,
          top: b.y + _kCanvasPad,
          width: b.w,
          height: b.h,
          child: _bar(b.kind),
        );
      default:
        return const Positioned(left: 0, top: 0, child: SizedBox.shrink());
    }
  }

  Widget _stepBox(SfcStep step) {
    final active = _isActive(step);
    final dim = _online && !active;
    final accent = active ? _kEnergized : (step.isInitial ? Colors.greenAccent : Colors.purpleAccent);
    return GestureDetector(
      onTap: () => _showStepEditor(step),
      child: Opacity(
        opacity: dim ? 0.45 : 1.0,
        child: Container(
          decoration: BoxDecoration(
            color: active ? const Color(0xFF14361F) : const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: accent, width: active ? 3 : 2),
            boxShadow: active
                ? [BoxShadow(color: _kEnergized.withValues(alpha: 0.6), blurRadius: 16, spreadRadius: 1)]
                : const [BoxShadow(color: Colors.black45, blurRadius: 6)],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: (step.isInitial ? Colors.green : Colors.purple).withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      step.isInitial ? 'INIT' : 'STEP',
                      style: TextStyle(fontWeight: FontWeight.bold, color: accent, fontSize: 8),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      step.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
                    ),
                  ),
                  const Icon(Icons.edit, size: 11, color: Colors.white38),
                ],
              ),
              if (active) ...[
                const SizedBox(height: 2),
                Row(
                  children: [
                    const Icon(Icons.timer, size: 9, color: _kEnergized),
                    const SizedBox(width: 3),
                    Flexible(
                      child: Text(
                        _stepTLabel(step),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 8,
                          fontWeight: FontWeight.bold,
                          color: _kEnergized,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 3),
              Expanded(
                child: Text(
                  step.actionSt.isEmpty ? '(no action)' : step.actionSt,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9,
                    color: step.actionSt.isEmpty ? Colors.white38 : Colors.cyanAccent,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// A transition rendered as a BORDERED BLOCK holding the editable condition
  /// (with tag autocomplete). Editing writes straight through to the model, so
  /// an in-flight edit survives a sibling rebuild.
  Widget _transBlock(SfcTransition t) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.amberAccent.withValues(alpha: 0.7), width: 1.5),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: TagAutocompleteField(
              key: ValueKey('sfccond_${t.id}'),
              options: widget.currentProject.tags.map((tag) => tag.name).toList(),
              initialValue: t.conditionSt,
              onChanged: (val) {
                t.conditionSt = val;
                widget.onProgramUpdated();
              },
            ),
          ),
          InkWell(
            key: ValueKey('sfctransmenu_${t.id}'),
            onTap: () => _showTransitionMenu(t),
            child: const Padding(
              padding: EdgeInsets.only(left: 2),
              child: Icon(Icons.more_vert, size: 16, color: Colors.amberAccent),
            ),
          ),
        ],
      ),
    );
  }

  /// Transition block menu: set target (existing step / new step / GOTO) or
  /// delete the transition. Only offered for ordinary `single` edges — fork /
  /// join links are managed structurally through the step menu.
  void _showTransitionMenu(SfcTransition t) {
    showAdaptiveWidthDialog(
      context,
      desiredWidth: 420,
      child: AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('Transition'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'TARGET STEP:',
              style: TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            if (t.kind == 'single')
              _targetDropdown(t)
            else
              const Text(
                'Fork / join links are edited via the step menu.',
                style: TextStyle(fontSize: 11, color: Colors.white54),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              _applyStructure(() => deleteSfcTransition(widget.program, t.id));
              Navigator.pop(context);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
          if (t.kind == 'single')
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _applyStructure(() {
                  final s = addSfcStep(widget.program);
                  t.toStepId = s.id;
                });
              },
              child: const Text('New step', style: TextStyle(color: Colors.purpleAccent)),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// A dropdown of every step id — picking one retargets the `single` edge to an
  /// existing step (a forward edge, or a GOTO/back-edge when it points upstream).
  Widget _targetDropdown(SfcTransition t) {
    final steps = widget.program.sfcSteps;
    final valid = steps.any((s) => s.id == t.toStepId) ? t.toStepId : null;
    return DropdownButton<String>(
      key: ValueKey('sfctarget_${t.id}'),
      isExpanded: true,
      dropdownColor: const Color(0xFF1E293B),
      value: valid,
      hint: const Text('(select target)', style: TextStyle(fontSize: 12, color: Colors.white54)),
      items: [
        for (final s in steps)
          DropdownMenuItem(
            value: s.id,
            child: Text(
              s.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
      ],
      onChanged: (v) {
        if (v == null) {
          return;
        }
        _applyStructure(() => t.toStepId = v);
        Navigator.pop(context);
      },
    );
  }

  Widget _gotoChip(SfcTransition t) {
    final target = widget.program.sfcSteps.where((s) => s.id == t.toStepId);
    final targetName = target.isEmpty ? '(deleted)' : target.first.name;
    return Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.amberAccent.withValues(alpha: 0.6)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.replay, size: 14, color: Colors.amberAccent),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              'GOTO $targetName',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.amberAccent, fontSize: 11, fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }

  /// A thin double-line bar for a parallel fork / join. [kind] is `'forkBar'`
  /// or `'joinBar'` — used as a stable key so tests / hit-tests can find it.
  Widget _bar(String kind) {
    return Column(
      key: ValueKey('sfc_$kind'),
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(height: 2, color: Colors.purpleAccent),
        const SizedBox(height: 3),
        Container(height: 2, color: Colors.purpleAccent),
      ],
    );
  }

  /// Applies a pure structure mutation and refreshes the canvas.
  void _applyStructure(void Function() mutate) {
    setState(mutate);
    widget.onProgramUpdated();
  }

  /// A compact dark-theme action chip used in the step editor's STRUCTURE row.
  Widget _structureButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 14, color: Colors.purpleAccent),
      label: Text(label, style: const TextStyle(fontSize: 11, color: Colors.purpleAccent)),
      style: OutlinedButton.styleFrom(
        side: BorderSide(color: Colors.purpleAccent.withValues(alpha: 0.5)),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  /// Tap a step box -> edit its name / N-action, add structure (step after /
  /// alternative / parallel branch), or delete it (collapse-aware).
  void _showStepEditor(SfcStep step) {
    String pendingName = step.name;
    String pendingAction = step.actionSt;

    showAdaptiveWidthDialog(
      context,
      desiredWidth: 420,
      child: AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: Text(step.isInitial ? 'Initial Step' : 'Step'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextFormField(
              initialValue: step.name,
              decoration: const InputDecoration(labelText: 'Step name'),
              onChanged: (v) => pendingName = v,
            ),
            const SizedBox(height: 12),
            const Text(
              'N (Non-Stored Action Logic):',
              style: TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            TextFormField(
              initialValue: step.actionSt,
              maxLines: 4,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.cyanAccent),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Enter ST Action statements...',
              ),
              onChanged: (v) => pendingAction = v,
            ),
            const SizedBox(height: 14),
            const Text(
              'STRUCTURE:',
              style: TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                _structureButton(
                  icon: Icons.south,
                  label: '＋Add step after',
                  onTap: () {
                    Navigator.pop(context);
                    _applyStructure(() => addSfcStepAfter(widget.program, step.id));
                  },
                ),
                _structureButton(
                  icon: Icons.call_split,
                  label: '＋Add alternative branch',
                  onTap: () {
                    Navigator.pop(context);
                    _applyStructure(() => addAlternativeBranch(widget.program, step.id));
                  },
                ),
                _structureButton(
                  icon: Icons.account_tree,
                  label: '＋Add parallel branch',
                  onTap: () {
                    Navigator.pop(context);
                    _applyStructure(() => addParallelBranch(widget.program, step.id));
                  },
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              setState(() => deleteSfcStepStructured(widget.program, step.id));
              widget.onProgramUpdated();
              Navigator.pop(context);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() {
                step.name = pendingName.trim().isEmpty ? step.name : pendingName.trim();
                step.actionSt = pendingAction;
              });
              widget.onProgramUpdated();
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final expanded = context.isExpanded;
    final short = context.isShort;

    return Scaffold(
      appBar: AppBar(
        title: Text(short
            ? '${widget.program.name} (SFC)'
            : '${widget.program.name} — Sequential Function Chart (SFC) Editor'),
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
            tooltip: _online ? 'Go Offline (stop live monitor)' : 'Go Online (live monitor)',
            onPressed: () => setState(() => _online = !_online),
          ),
          if (!expanded)
            IconButton(
              icon: const Icon(Icons.label_important, color: Colors.purpleAccent),
              tooltip: 'Tag & Condition Autocomplete',
              onPressed: _openTagPaletteSheet,
            ),
          IconButton(
            icon: const Icon(Icons.add_circle, color: Colors.purpleAccent),
            tooltip: 'Add SFC Step',
            onPressed: _addNewStep,
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: expanded
          ? Row(
              children: [
                // CENTER WORKSPACE: 2D SFC pan/zoom canvas.
                Expanded(child: _buildCanvas()),

                const VerticalDivider(width: 1, color: Colors.white12),

                // RIGHT DOCK: Action & Condition Tag Autocomplete Palette
                _buildTagPaletteDock(),
              ],
            )
          : _buildCanvas(),
    );
  }

  Widget _buildTagPaletteDock() {
    return Container(
      width: 260,
      color: const Color(0xFF0F172A),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            color: const Color(0xFF1E293B),
            child: const Text('SFC TAG & CONDITION AUTOCOMPLETE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.purpleAccent)),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(8),
              children: widget.currentProject.tags.map((tag) => Card(
                color: const Color(0xFF1E293B),
                margin: const EdgeInsets.only(bottom: 6),
                child: Material(
                  color: Colors.transparent,
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.label_important, color: Colors.purpleAccent, size: 16),
                    title: Text(tag.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                    subtitle: Text('${tag.path} [${tag.dataType}]', style: const TextStyle(fontSize: 10, color: Colors.grey)),
                  ),
                ),
              )).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

/// Paints the SFC connector segments. A normal edge is a single line; a
/// [SfcConn.doubleBar] edge (parallel fork / join link) is drawn as two
/// parallel strokes.
class _SfcPainter extends CustomPainter {
  final SfcLayout layout;

  _SfcPainter(this.layout);

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = Colors.purpleAccent.withValues(alpha: 0.7)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    for (final c in layout.conns) {
      final x1 = c.x1 + _kCanvasPad;
      final y1 = c.y1 + _kCanvasPad;
      final x2 = c.x2 + _kCanvasPad;
      final y2 = c.y2 + _kCanvasPad;
      if (c.doubleBar) {
        // Fork/join links are vertical; offset the twin strokes in x.
        const off = 3.0;
        canvas.drawLine(Offset(x1 - off, y1), Offset(x2 - off, y2), line);
        canvas.drawLine(Offset(x1 + off, y1), Offset(x2 + off, y2), line);
      } else {
        canvas.drawLine(Offset(x1, y1), Offset(x2, y2), line);
      }
    }
  }

  // The painter draws only the connector segments, so it need only repaint when
  // the connector geometry actually changes (a structural edit). A fresh
  // `SfcLayout` is built every `build()` — comparing by reference (the previous
  // `oldDelegate.layout != layout`) reported "changed" every time, forcing a
  // wasteful repaint on every rebuild (including per-tick online rebuilds where
  // the connectors are identical). Compare the painted fields instead.
  @override
  bool shouldRepaint(covariant _SfcPainter oldDelegate) {
    final a = oldDelegate.layout;
    final b = layout;
    if (a.width != b.width || a.height != b.height || a.conns.length != b.conns.length) {
      return true;
    }
    for (var i = 0; i < a.conns.length; i++) {
      final c1 = a.conns[i];
      final c2 = b.conns[i];
      if (c1.x1 != c2.x1 ||
          c1.y1 != c2.y1 ||
          c1.x2 != c2.x2 ||
          c1.y2 != c2.y2 ||
          c1.doubleBar != c2.doubleBar) {
        return true;
      }
    }
    return false;
  }
}
