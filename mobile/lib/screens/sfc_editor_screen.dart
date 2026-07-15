import 'package:flutter/material.dart';
import '../models/project_model.dart';
import '../models/sfc_edit.dart';
import '../models/sfc_region.dart';
import '../models/sfc_layout2.dart';
import '../ui/responsive.dart';
import '../widgets/tag_autocomplete_field.dart';

/// Padding inside the scroll content, around the laid-out chart, so boxes at
/// x=0 / y=0 are not flush against the canvas edge. Applied to both the
/// positioned boxes and the connector painter.
const double _kCanvasPad = 28.0;

class SfcEditorScreen extends StatefulWidget {
  final PlcProject currentProject;
  final PlcProgram program;
  final VoidCallback onProgramUpdated;

  const SfcEditorScreen({
    super.key,
    required this.currentProject,
    required this.program,
    required this.onProgramUpdated,
  });

  @override
  State<SfcEditorScreen> createState() => _SfcEditorScreenState();
}

class _SfcEditorScreenState extends State<SfcEditorScreen> {
  @override
  void initState() {
    super.initState();
    _ensureDefaultSfc();
  }

  void _ensureDefaultSfc() {
    if (widget.program.sfcSteps.isEmpty) {
      widget.program.sfcSteps.addAll([
        SfcStep(id: 's0', name: 'Step_0_Init', isInitial: true, actionSt: 'Fill_Valve := FALSE; Drain_Valve := FALSE;'),
        SfcStep(id: 's1', name: 'Step_1_Filling', actionSt: 'Fill_Valve := TRUE;'),
        SfcStep(id: 's2', name: 'Step_2_Draining', actionSt: 'Drain_Valve := TRUE;'),
      ]);

      widget.program.sfcTransitions.addAll([
        SfcTransition(id: 't0', fromStepId: 's0', toStepId: 's1', conditionSt: 'Start_PB AND Level_PV < 10.0'),
        SfcTransition(id: 't1', fromStepId: 's1', toStepId: 's2', conditionSt: 'Level_PV >= Level_SP'),
        SfcTransition(id: 't2', fromStepId: 's2', toStepId: 's0', conditionSt: 'Level_PV <= 10.0'),
      ]);
    }
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
          child: _bar(),
        );
      default:
        return const Positioned(left: 0, top: 0, child: SizedBox.shrink());
    }
  }

  Widget _stepBox(SfcStep step) {
    final accent = step.isInitial ? Colors.greenAccent : Colors.purpleAccent;
    return GestureDetector(
      onTap: () => _showStepEditor(step),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: accent, width: 2),
          boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 6)],
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
      child: TagAutocompleteField(
        key: ValueKey('sfccond_${t.id}'),
        options: widget.currentProject.tags.map((tag) => tag.name).toList(),
        initialValue: t.conditionSt,
        onChanged: (val) {
          t.conditionSt = val;
          widget.onProgramUpdated();
        },
      ),
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

  /// A thin double-line bar for a parallel fork / join.
  Widget _bar() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(height: 2, color: Colors.purpleAccent),
        const SizedBox(height: 3),
        Container(height: 2, color: Colors.purpleAccent),
      ],
    );
  }

  /// Tap a step box -> edit its name / N-action, or delete it. (Structural
  /// authoring — adding branches / retargeting — returns in a later task.)
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
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              setState(() => deleteSfcStep(widget.program, step.id));
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

  @override
  bool shouldRepaint(covariant _SfcPainter oldDelegate) => oldDelegate.layout != layout;
}
