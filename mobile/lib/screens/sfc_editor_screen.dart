import 'package:flutter/material.dart';
import '../models/project_model.dart';
import '../models/sfc_edit.dart';
import '../models/sfc_layout.dart';
import '../ui/responsive.dart';

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
    final idx = widget.program.sfcSteps.length;
    final newStep = SfcStep(
      id: 's_$idx',
      name: 'Step_$idx',
      actionSt: '// ST Action for Step_$idx\n',
    );

    setState(() {
      widget.program.sfcSteps.add(newStep);
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

  Widget _buildCenterWorkspace(bool expanded) {
    return Container(
      color: const Color(0xFF0F172A),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final cardWidth = _cardWidth(constraints.maxWidth);
          final rows = layoutSfc(widget.program.sfcSteps, widget.program.sfcTransitions);
          final rowIndexOf = <String, int>{
            for (var i = 0; i < rows.length; i++) rows[i].step.id: i,
          };
          return ListView.builder(
            padding: const EdgeInsets.all(24),
            itemCount: rows.length,
            itemBuilder: (context, index) {
              final row = rows[index];
              return Column(
                children: [
                  _buildSfcStepCard(row.step, cardWidth),
                  for (final o in row.outgoing)
                    _buildOutgoing(
                      o,
                      cardWidth,
                      isLoopBack: o.target != null &&
                          (rowIndexOf[o.target!.id] ?? (1 << 30)) <= index,
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  double _cardWidth(double availableWidth) {
    const margins = 24.0 * 2; // ListView padding, left + right
    final maxW = availableWidth - margins;
    if (maxW <= 0) {
      return 0.0;
    }
    return maxW < 450 ? maxW : 450.0;
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
                // CENTER WORKSPACE: Visual SFC Step Transition Chart
                Expanded(child: _buildCenterWorkspace(true)),

                const VerticalDivider(width: 1, color: Colors.white12),

                // RIGHT DOCK: Action & Condition Tag Autocomplete Palette
                _buildTagPaletteDock(),
              ],
            )
          : _buildCenterWorkspace(false),
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

  Widget _buildSfcStepCard(SfcStep step, double width) {
    return Container(
      width: width,
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: step.isInitial ? Colors.greenAccent : Colors.purpleAccent, width: 2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: (step.isInitial ? Colors.green : Colors.purple).withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    step.isInitial ? 'INITIAL STEP' : 'STEP',
                    style: TextStyle(fontWeight: FontWeight.bold, color: step.isInitial ? Colors.greenAccent : Colors.purpleAccent, fontSize: 10),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(step.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
                IconButton(
                  icon: const Icon(Icons.delete, size: 16, color: Colors.redAccent),
                  tooltip: 'Delete step',
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  onPressed: () {
                    setState(() => deleteSfcStep(widget.program, step.id));
                    widget.onProgramUpdated();
                  },
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline, size: 16, color: Colors.purpleAccent),
                  tooltip: 'Add branch',
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  onPressed: () {
                    setState(() => addSfcBranch(widget.program, step.id));
                    widget.onProgramUpdated();
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text('N (Non-Stored Action Logic):', style: TextStyle(fontSize: 10, color: Colors.grey, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            TextField(
              controller: TextEditingController(text: step.actionSt),
              maxLines: 2,
              onSubmitted: (val) {
                step.actionSt = val;
                widget.onProgramUpdated();
              },
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.cyanAccent),
              decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), hintText: 'Enter ST Action statements...'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSfcTransitionGraphic(SfcTransition transition, double width) {
    return Container(
      width: width,
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: [
          Container(width: 3, height: 16, color: Colors.purpleAccent),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(width: 20, height: 4, color: Colors.amberAccent),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: TextEditingController(text: transition.conditionSt),
                  onSubmitted: (val) {
                    transition.conditionSt = val;
                    widget.onProgramUpdated();
                  },
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.amberAccent, fontWeight: FontWeight.bold),
                  decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), labelText: 'Transition Condition (BOOL ST Expression)'),
                ),
              ),
              const SizedBox(width: 8),
              Container(width: 20, height: 4, color: Colors.amberAccent),
            ],
          ),
          Container(width: 3, height: 16, color: Colors.purpleAccent),
        ],
      ),
    );
  }

  Widget _branchControls(SfcTransition t, double width) {
    final steps = widget.program.sfcSteps;
    return Row(
      children: [
        const Text('→ ', style: TextStyle(color: Colors.amberAccent, fontFamily: 'monospace')),
        Expanded(
          // Keyed by step index (not step id) so this stays a
          // DropdownButton<int>: the shell's SELECT PROJECT selector is a
          // DropdownButton<String>, and the responsive smoke test locates it
          // via find.byType(DropdownButton<String>).first — a String-typed
          // dropdown here (behind the compact Drawer) would shadow it.
          // Sentinel index -1 = "＋ New step…".
          child: DropdownButton<int>(
            isExpanded: true,
            dropdownColor: const Color(0xFF1E293B),
            value: () {
              final i = steps.indexWhere((s) => s.id == t.toStepId);
              return i >= 0 ? i : null;
            }(),
            hint: const Text('(target)', style: TextStyle(color: Colors.grey, fontSize: 12)),
            items: [
              for (var i = 0; i < steps.length; i++)
                DropdownMenuItem(value: i, child: Text(steps[i].name, style: const TextStyle(fontSize: 12))),
              const DropdownMenuItem(value: -1, child: Text('＋ New step…', style: TextStyle(fontSize: 12, color: Colors.cyanAccent))),
            ],
            onChanged: (v) {
              if (v == null) {
                return;
              }
              setState(() {
                if (v == -1) {
                  final s = addSfcStep(widget.program);
                  t.toStepId = s.id;
                } else {
                  t.toStepId = steps[v].id;
                }
              });
              widget.onProgramUpdated();
            },
          ),
        ),
        IconButton(
          icon: const Icon(Icons.arrow_upward, size: 16, color: Colors.cyanAccent),
          tooltip: 'Higher priority',
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          onPressed: () {
            setState(() => reorderSfcBranch(widget.program, t.id, -1));
            widget.onProgramUpdated();
          },
        ),
        IconButton(
          icon: const Icon(Icons.arrow_downward, size: 16, color: Colors.cyanAccent),
          tooltip: 'Lower priority',
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          onPressed: () {
            setState(() => reorderSfcBranch(widget.program, t.id, 1));
            widget.onProgramUpdated();
          },
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
          tooltip: 'Delete branch',
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          onPressed: () {
            setState(() => deleteSfcTransition(widget.program, t.id));
            widget.onProgramUpdated();
          },
        ),
      ],
    );
  }

  Widget _buildOutgoing(SfcOutgoing o, double width, {required bool isLoopBack}) {
    final controls = SizedBox(width: width, child: _branchControls(o.transition, width));
    // The condition editor is the existing transition graphic body.
    final condition = _buildSfcTransitionGraphic(o.transition, width);
    if (o.inline) {
      // vertical connector flows into the next card below
      return Column(children: [controls, condition]);
    }
    // Non-inline: a GOTO reference chip to the target (or "(deleted)").
    final targetName = o.target?.name ?? '(deleted)';
    // Deleted target: link_off. Genuine loop-back (target at/above this row):
    // the loop icon. Forward branch (target below this row): a distinct
    // forward icon so it isn't mistaken for a loop.
    final IconData icon;
    if (o.target == null) {
      icon = Icons.link_off;
    } else if (isLoopBack) {
      icon = Icons.subdirectory_arrow_left;
    } else {
      icon = Icons.arrow_forward;
    }
    return Column(
      children: [
        controls,
        condition,
        Container(
          width: width,
          margin: const EdgeInsets.only(top: 2, bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.amberAccent.withValues(alpha: 0.6)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: Colors.amberAccent),
              const SizedBox(width: 6),
              Text('GOTO $targetName',
                  style: const TextStyle(
                      color: Colors.amberAccent, fontSize: 12, fontFamily: 'monospace')),
            ],
          ),
        ),
      ],
    );
  }
}
