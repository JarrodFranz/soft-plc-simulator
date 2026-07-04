import 'package:flutter/material.dart';
import '../models/project_model.dart';

const double _kRowH = 90.0;
const double _kRailW = 6.0;
const double _kWireH = 3.0;
const double _kJunctionW = 24.0;

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
  String _tagSearchQuery = '';

  @override
  void initState() {
    super.initState();
    _ensureDefaultRungs();
  }

  void _ensureDefaultRungs() {
    if (widget.program.rungs.isEmpty) {
      widget.program.rungs.addAll([
        LdRung(
          rungIndex: 0,
          comment: 'Rung 0: Motor Start/Stop Seal-In Circuit',
          inputInstructions: [
            LdInstruction(type: 'XIC', operandTag: 'Start_PB', comment: 'Start Pushbutton'),
            LdInstruction(type: 'XIO', operandTag: 'Stop_PB', comment: 'Stop Pushbutton'),
            LdInstruction(type: 'XIO', operandTag: 'Overload_OK', comment: 'Overload Thermal Relay'),
          ],
          outputInstructions: [
            LdInstruction(type: 'OTE', operandTag: 'Motor_Run', comment: 'Motor Starter Solenoid Coil'),
          ],
          parallelBranches: [
            LdBranch(
              inputInstructions: [
                LdInstruction(type: 'XIC', operandTag: 'Motor_Run', comment: 'Motor Seal-In Auxiliary Contact'),
              ],
              outputInstructions: [],
            ),
          ],
        ),
        LdRung(
          rungIndex: 1,
          comment: 'Rung 1: IEC 61131-3 Standard TON Timer Block (IN, Q, PT, ET)',
          inputInstructions: [
            LdInstruction(type: 'XIO', operandTag: 'TONTimer.DN', comment: 'Timer Done NC Contact'),
            LdInstruction(type: 'TON', operandTag: 'TONTimer', presetMs: 5000, comment: '5 Second TON Timer'),
          ],
          outputInstructions: [
            LdInstruction(type: 'OTE', operandTag: 'MixerMotor', comment: 'Mixer Motor Coil'),
          ],
          parallelBranches: [
            LdBranch(
              inputInstructions: [
                LdInstruction(type: 'XIC', operandTag: 'TONTimer.DN', comment: 'Timer Done NO Contact'),
              ],
              outputInstructions: [
                LdInstruction(type: 'OTE', operandTag: 'Arbor1Oiler', comment: 'Arbor Oiler Coil'),
              ],
            ),
          ],
        ),
      ]);
    }
  }

  void _addNewRung([int? insertAt]) {
    setState(() {
      final newRung = LdRung(
        rungIndex: insertAt ?? widget.program.rungs.length,
        comment: 'Rung ${widget.program.rungs.length}: New Rung',
        inputInstructions: [],
        outputInstructions: [LdInstruction(type: 'OTE', operandTag: 'Output_Coil')],
      );
      if (insertAt != null && insertAt >= 0 && insertAt <= widget.program.rungs.length) {
        widget.program.rungs.insert(insertAt, newRung);
        for (int i = 0; i < widget.program.rungs.length; i++) {
          widget.program.rungs[i].rungIndex = i;
        }
      } else {
        widget.program.rungs.add(newRung);
      }
    });
    widget.onProgramUpdated();
  }

  void _addParallelBranch(LdRung rung) {
    setState(() {
      rung.parallelBranches.add(LdBranch(
        inputInstructions: [LdInstruction(type: 'XIC', operandTag: 'New_Contact')],
        outputInstructions: [],
      ));
    });
    widget.onProgramUpdated();
  }

  void _deleteParallelBranch(LdRung rung, int branchIndex) {
    setState(() => rung.parallelBranches.removeAt(branchIndex));
    widget.onProgramUpdated();
  }

  void _moveRung(int index, int delta) {
    final newIdx = index + delta;
    if (newIdx < 0 || newIdx >= widget.program.rungs.length) return;
    setState(() {
      final rung = widget.program.rungs.removeAt(index);
      widget.program.rungs.insert(newIdx, rung);
      for (int i = 0; i < widget.program.rungs.length; i++) {
        widget.program.rungs[i].rungIndex = i;
      }
    });
    widget.onProgramUpdated();
  }

  void _showAddInstructionDialog(LdRung rung, bool isInput, [LdBranch? targetBranch, int? insertIndex]) {
    String type = isInput ? 'XIC' : 'OTE';
    String tag = widget.currentProject.tags.isNotEmpty ? widget.currentProject.tags.first.name : 'Tag_01';
    final commentCtrl = TextEditingController();
    int presetMs = 5000;

    final inputTypes = [
      {'type': 'XIC', 'label': 'XIC — Examine if Closed (-| |-)'},
      {'type': 'XIO', 'label': 'XIO — Examine if Open (-|/|-)'},
      {'type': 'TON', 'label': 'TON — Timer On Delay Block'},
      {'type': 'TOF', 'label': 'TOF — Timer Off Delay Block'},
    ];
    final outputTypes = [
      {'type': 'OTE', 'label': 'OTE — Output Coil (-( )-)'},
      {'type': 'OTL', 'label': 'OTL — Output Latch (-(L)-)'},
      {'type': 'OTU', 'label': 'OTU — Output Unlatch (-(U)-)'},
    ];

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) => AlertDialog(
          title: Text(isInput ? 'Insert Contact / Block' : 'Add Output Coil'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: type,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Instruction Type'),
                  items: (isInput ? inputTypes : outputTypes).map((t) => DropdownMenuItem(
                    value: t['type'],
                    child: Text(t['label']!, overflow: TextOverflow.ellipsis),
                  )).toList(),
                  onChanged: (val) => setDlgState(() => type = val!),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: widget.currentProject.tags.any((t) => t.name == tag) ? tag : null,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Operand Tag'),
                  items: widget.currentProject.tags.map((t) => DropdownMenuItem(
                    value: t.name,
                    child: Text('${t.name} [${t.dataType}]', overflow: TextOverflow.ellipsis),
                  )).toList(),
                  onChanged: (val) => setDlgState(() => tag = val!),
                ),
                if (type == 'TON' || type == 'TOF') ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: TextEditingController(text: presetMs.toString()),
                    keyboardType: TextInputType.number,
                    onChanged: (v) => presetMs = int.tryParse(v) ?? 5000,
                    decoration: const InputDecoration(labelText: 'Preset Time (PT) in ms'),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(controller: commentCtrl, decoration: const InputDecoration(labelText: 'Comment')),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                final inst = LdInstruction(type: type, operandTag: tag, presetMs: presetMs, comment: commentCtrl.text);
                setState(() {
                  final targetList = targetBranch != null
                      ? (isInput ? targetBranch.inputInstructions : targetBranch.outputInstructions)
                      : (isInput ? rung.inputInstructions : rung.outputInstructions);
                  if (insertIndex != null && insertIndex >= 0 && insertIndex <= targetList.length) {
                    targetList.insert(insertIndex, inst);
                  } else {
                    targetList.add(inst);
                  }
                });
                widget.onProgramUpdated();
                Navigator.pop(ctx);
              },
              child: const Text('Insert'),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditInstructionDialog(LdInstruction inst) {
    final tagCtrl = TextEditingController(text: inst.operandTag);
    final commentCtrl = TextEditingController(text: inst.comment);
    final presetCtrl = TextEditingController(text: inst.presetMs.toString());
    String selectedType = inst.type;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlgState) {
          final filtered = widget.currentProject.tags.where((t) =>
              t.name.toLowerCase().contains(tagCtrl.text.toLowerCase())).toList();
          return AlertDialog(
            title: Text('Edit: ${inst.type} (${inst.operandTag})'),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: selectedType,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Instruction Type'),
                    items: const [
                      DropdownMenuItem(value: 'XIC', child: Text('XIC — Examine Closed (-| |-)')),
                      DropdownMenuItem(value: 'XIO', child: Text('XIO — Examine Open (-|/|-)')),
                      DropdownMenuItem(value: 'OTE', child: Text('OTE — Output Coil (-( )-)')),
                      DropdownMenuItem(value: 'OTL', child: Text('OTL — Output Latch (-(L)-)')),
                      DropdownMenuItem(value: 'OTU', child: Text('OTU — Output Unlatch (-(U)-)')),
                      DropdownMenuItem(value: 'TON', child: Text('TON — Timer On Delay Block')),
                      DropdownMenuItem(value: 'TOF', child: Text('TOF — Timer Off Delay Block')),
                    ],
                    onChanged: (val) => setDlgState(() => selectedType = val!),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: tagCtrl,
                    onChanged: (_) => setDlgState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Tag / Parameter',
                      isDense: true,
                      suffixIcon: Icon(Icons.search, size: 16),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text('TAG SUGGESTIONS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey)),
                  const SizedBox(height: 4),
                  SizedBox(
                    height: 90,
                    child: ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (ctx, idx) {
                        final t = filtered[idx];
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.label_important, size: 14,
                              color: t.name.contains('.DN') ? Colors.amberAccent : Colors.cyanAccent),
                          title: Text(t.name,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                              overflow: TextOverflow.ellipsis),
                          subtitle: Text('${t.path} [${t.dataType}]',
                              style: const TextStyle(fontSize: 10, color: Colors.grey),
                              overflow: TextOverflow.ellipsis),
                          onTap: () => setDlgState(() => tagCtrl.text = t.name),
                        );
                      },
                    ),
                  ),
                  if (selectedType == 'TON' || selectedType == 'TOF') ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: presetCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Preset Time (PT) in ms'),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(controller: commentCtrl, decoration: const InputDecoration(labelText: 'Comment')),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    inst.type = selectedType;
                    inst.operandTag = tagCtrl.text.trim();
                    inst.comment = commentCtrl.text;
                    inst.presetMs = int.tryParse(presetCtrl.text) ?? 5000;
                  });
                  widget.onProgramUpdated();
                  Navigator.pop(ctx);
                },
                child: const Text('Apply'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filteredTags = widget.currentProject.tags.where((t) =>
        t.name.toLowerCase().contains(_tagSearchQuery.toLowerCase()) ||
        t.path.toLowerCase().contains(_tagSearchQuery.toLowerCase())).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.program.name} — IEC 61131-3 Ladder Diagram (LD) Editor'),
        backgroundColor: const Color(0xFF1E293B),
        actions: [
          ElevatedButton.icon(
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add Rung'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.cyan, foregroundColor: Colors.black),
            onPressed: () => _addNewRung(),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Row(
        children: [
          // ── RUNG CANVAS ──────────────────────────────────────────────
          Expanded(
            child: Container(
              color: const Color(0xFF0F172A),
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: widget.program.rungs.length,
                itemBuilder: (context, index) =>
                    _buildRungCard(widget.program.rungs[index], index),
              ),
            ),
          ),

          const VerticalDivider(width: 1, color: Colors.white12),

          // ── TAG PALETTE ───────────────────────────────────────────────
          Container(
            width: 270,
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
                      const Text('TAG & INSTRUCTION PALETTE',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.cyanAccent)),
                      const SizedBox(height: 8),
                      TextField(
                        onChanged: (v) => setState(() => _tagSearchQuery = v),
                        decoration: const InputDecoration(
                          hintText: 'Search tags...',
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
                      const Text('CLICK TO COPY TAG',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.grey)),
                      const SizedBox(height: 6),
                      ...filteredTags.map((tag) => Card(
                        color: const Color(0xFF1E293B),
                        margin: const EdgeInsets.only(bottom: 6),
                        child: ListTile(
                          dense: true,
                          leading: Icon(
                            tag.name.contains('.DN') ? Icons.timer
                                : (tag.ioType == 'SimulatedInput' ? Icons.login
                                : (tag.ioType == 'SimulatedOutput' ? Icons.logout : Icons.storage)),
                            size: 16,
                            color: tag.name.contains('.DN') ? Colors.amberAccent
                                : (tag.ioType == 'SimulatedInput' ? Colors.greenAccent : Colors.cyanAccent),
                          ),
                          title: Text(tag.name,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                              overflow: TextOverflow.ellipsis),
                          subtitle: Text('${tag.path} [${tag.dataType}]',
                              style: const TextStyle(fontSize: 10, color: Colors.grey),
                              overflow: TextOverflow.ellipsis),
                        ),
                      )),
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

  // ── RUNG CARD ───────────────────────────────────────────────────────────

  Widget _buildRungCard(LdRung rung, int index) {
    return Card(
      color: const Color(0xFF1E293B),
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8), side: const BorderSide(color: Colors.white12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildRungHeader(rung, index),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.cyan.withValues(alpha: 0.3)),
              ),
              child: _buildRungCanvas(rung),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRungHeader(LdRung rung, int index) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
              color: Colors.cyan.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(4)),
          child: Text('RUNG $index',
              style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.cyanAccent, fontSize: 11)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: TextEditingController(text: rung.comment),
            onSubmitted: (val) {
              setState(() => rung.comment = val);
              widget.onProgramUpdated();
            },
            style: const TextStyle(fontSize: 12, color: Colors.grey),
            decoration: const InputDecoration(
                isDense: true, border: InputBorder.none, hintText: 'Rung comment...'),
          ),
        ),
        IconButton(
            icon: const Icon(Icons.account_tree, size: 16, color: Colors.tealAccent),
            tooltip: 'Add Parallel Branch',
            onPressed: () => _addParallelBranch(rung)),
        IconButton(
            icon: const Icon(Icons.arrow_upward, size: 16, color: Colors.grey),
            tooltip: 'Move Up',
            onPressed: index > 0 ? () => _moveRung(index, -1) : null),
        IconButton(
            icon: const Icon(Icons.arrow_downward, size: 16, color: Colors.grey),
            tooltip: 'Move Down',
            onPressed: index < widget.program.rungs.length - 1 ? () => _moveRung(index, 1) : null),
        IconButton(
            icon: const Icon(Icons.add, size: 16, color: Colors.greenAccent),
            tooltip: 'Insert Rung Below',
            onPressed: () => _addNewRung(index + 1)),
        IconButton(
            icon: const Icon(Icons.delete, size: 16, color: Colors.redAccent),
            tooltip: 'Delete Rung',
            onPressed: () {
              setState(() {
                widget.program.rungs.removeAt(index);
                for (int i = 0; i < widget.program.rungs.length; i++) {
                  widget.program.rungs[i].rungIndex = i;
                }
              });
              widget.onProgramUpdated();
            }),
      ],
    );
  }

  // ── RUNG CANVAS: single L1/L2 rail spanning all branch rows ─────────────

  Widget _buildRungCanvas(LdRung rung) {
    final branches = rung.parallelBranches;
    final totalRows = 1 + branches.length;
    final canvasH = _kRowH * totalRows;
    final hasParallel = branches.isNotEmpty;

    return SizedBox(
      height: canvasH + 14, // +14 for L1/L2 labels
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── L1 POWER RAIL ──
          Column(children: [
            Container(width: _kRailW, height: canvasH, color: Colors.greenAccent),
            const Text('L1', style: TextStyle(fontSize: 8, color: Colors.greenAccent, fontWeight: FontWeight.bold)),
          ]),

          // ── LEFT JUNCTION ──
          _buildLeftJunction(totalRows, canvasH, hasParallel),

          // ── BRANCH ROWS ──
          Expanded(
            child: SizedBox(
              height: canvasH,
              child: Column(
                children: [
                  SizedBox(
                    height: _kRowH,
                    child: _buildBranchRow(
                      inputs: rung.inputInstructions,
                      outputs: rung.outputInstructions,
                      rung: rung,
                      branch: null,
                    ),
                  ),
                  ...branches.asMap().entries.map((e) => SizedBox(
                    height: _kRowH,
                    child: _buildBranchRow(
                      inputs: e.value.inputInstructions,
                      outputs: e.value.outputInstructions,
                      rung: rung,
                      branch: e.value,
                    ),
                  )),
                ],
              ),
            ),
          ),

          // ── RIGHT JUNCTION ──
          _buildRightJunction(totalRows, canvasH, hasParallel),

          // ── L2 POWER RAIL ──
          Column(children: [
            Container(width: _kRailW, height: canvasH, color: Colors.blueAccent),
            const Text('L2', style: TextStyle(fontSize: 8, color: Colors.blueAccent, fontWeight: FontWeight.bold)),
          ]),

          // ── DELETE BRANCH BUTTONS (outside L2) ──
          if (hasParallel)
            SizedBox(
              height: canvasH,
              child: Column(children: [
                const SizedBox(height: _kRowH), // spacer for main rung row
                ...branches.asMap().entries.map((e) => SizedBox(
                  height: _kRowH,
                  child: Center(
                    child: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
                      tooltip: 'Delete Branch',
                      onPressed: () => _deleteParallelBranch(rung, e.key),
                    ),
                  ),
                )),
              ]),
            ),
        ],
      ),
    );
  }

  // Left junction: vertical line on the left + horizontal stubs right to each row
  Widget _buildLeftJunction(int totalRows, double canvasH, bool hasParallel) {
    if (!hasParallel) {
      return Container(
          width: _kJunctionW,
          alignment: Alignment.center,
          child: Container(width: _kJunctionW, height: _kWireH, color: Colors.greenAccent));
    }
    return SizedBox(
      width: _kJunctionW,
      height: canvasH,
      child: Stack(children: [
        // Vertical spine connecting row 0 center to last row center
        Positioned(
          left: 0,
          width: _kWireH,
          top: _kRowH / 2,
          height: canvasH - _kRowH,
          child: Container(color: Colors.greenAccent),
        ),
        // Horizontal stubs for every row
        ...List.generate(totalRows, (i) => Positioned(
          left: 0,
          right: 0,
          top: i * _kRowH + _kRowH / 2 - _kWireH / 2,
          height: _kWireH,
          child: Container(color: Colors.greenAccent),
        )),
      ]),
    );
  }

  // Right junction: vertical line on the right + horizontal stubs left from each row
  Widget _buildRightJunction(int totalRows, double canvasH, bool hasParallel) {
    if (!hasParallel) {
      return Container(
          width: _kJunctionW,
          alignment: Alignment.center,
          child: Container(width: _kJunctionW, height: _kWireH, color: Colors.greenAccent));
    }
    return SizedBox(
      width: _kJunctionW,
      height: canvasH,
      child: Stack(children: [
        // Vertical spine on the right edge
        Positioned(
          right: 0,
          width: _kWireH,
          top: _kRowH / 2,
          height: canvasH - _kRowH,
          child: Container(color: Colors.greenAccent),
        ),
        // Horizontal stubs for every row
        ...List.generate(totalRows, (i) => Positioned(
          left: 0,
          right: 0,
          top: i * _kRowH + _kRowH / 2 - _kWireH / 2,
          height: _kWireH,
          child: Container(color: Colors.greenAccent),
        )),
      ]),
    );
  }

  // ── BRANCH ROW: contacts → expanding wire → coils ───────────────────────

  Widget _buildBranchRow({
    required List<LdInstruction> inputs,
    required List<LdInstruction> outputs,
    required LdRung rung,
    required LdBranch? branch,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // INPUT CONTACTS (horizontally scrollable if many)
        Flexible(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (inputs.isEmpty)
                  _emptyWirePlaceholder(rung, branch)
                else
                  ...inputs.map((inst) => Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _buildInstructionCell(inst),
                      Container(width: 16, height: _kWireH, color: Colors.greenAccent),
                    ],
                  )),
                // Add-contact button
                IconButton(
                  icon: const Icon(Icons.add_box_outlined, color: Colors.cyanAccent, size: 20),
                  tooltip: 'Add Contact / Block',
                  onPressed: () => _showAddInstructionDialog(rung, true, branch),
                ),
              ],
            ),
          ),
        ),

        // EXPANDING WIRE (fills remaining horizontal space)
        Expanded(child: Container(height: _kWireH, color: Colors.greenAccent)),

        // OUTPUT COILS
        ...outputs.map((inst) => Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _buildInstructionCell(inst),
            Container(width: 10, height: _kWireH, color: Colors.greenAccent),
          ],
        )),

        // Add-output button
        IconButton(
          icon: const Icon(Icons.add_circle_outline, color: Colors.amberAccent, size: 18),
          tooltip: 'Add Output Coil',
          onPressed: () => _showAddInstructionDialog(rung, false, branch),
        ),
      ],
    );
  }

  Widget _emptyWirePlaceholder(LdRung rung, LdBranch? branch) {
    return InkWell(
      onTap: () => _showAddInstructionDialog(rung, true, branch, 0),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 24),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.cyan.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.4)),
        ),
        child: const Row(children: [
          Icon(Icons.add, size: 12, color: Colors.cyanAccent),
          SizedBox(width: 6),
          Text('Insert Contact', style: TextStyle(fontSize: 10, color: Colors.cyanAccent)),
        ]),
      ),
    );
  }

  // ── INSTRUCTION GRAPHICS ────────────────────────────────────────────────

  Widget _buildInstructionCell(LdInstruction inst) {
    if (inst.type == 'TON' || inst.type == 'TOF') {
      return _buildTimerBlock(inst);
    }
    return _buildContactCoil(inst);
  }

  Widget _buildTimerBlock(LdInstruction inst) {
    return InkWell(
      onTap: () => _showEditInstructionDialog(inst),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        width: 172,
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.grey.shade500, width: 1.5),
          boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 4)],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Block header
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: const BoxDecoration(
                color: Color(0xFF334155),
                borderRadius: BorderRadius.only(topLeft: Radius.circular(4), topRight: Radius.circular(4)),
              ),
              child: Text(
                '${inst.type}  ${inst.operandTag}',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 11, color: Colors.white, fontFamily: 'monospace'),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // Pin layout
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Left pins (inputs)
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('IN ──', style: TextStyle(fontSize: 10, color: Colors.greenAccent, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
                      SizedBox(height: 4),
                      Text('PT ──', style: TextStyle(fontSize: 10, color: Colors.grey, fontFamily: 'monospace')),
                    ],
                  ),
                  // Center values
                  Column(
                    children: [
                      Text('PT: ${inst.presetMs}ms', style: const TextStyle(fontSize: 9, color: Colors.cyanAccent)),
                      const SizedBox(height: 2),
                      const Text('ET:  0ms', style: TextStyle(fontSize: 9, color: Colors.grey)),
                    ],
                  ),
                  // Right pins (outputs)
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('── Q', style: TextStyle(fontSize: 10, color: Colors.greenAccent, fontFamily: 'monospace', fontWeight: FontWeight.bold)),
                      SizedBox(height: 4),
                      Text('── ET', style: TextStyle(fontSize: 10, color: Colors.grey, fontFamily: 'monospace')),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContactCoil(LdInstruction inst) {
    String symbol;
    Color color;
    switch (inst.type) {
      case 'XIO':  symbol = '-|/|-'; color = Colors.greenAccent; break;
      case 'OTE':  symbol = '-( )-'; color = Colors.amberAccent; break;
      case 'OTL':  symbol = '-(L)-'; color = Colors.amberAccent; break;
      case 'OTU':  symbol = '-(U)-'; color = Colors.amberAccent; break;
      default:     symbol = '-| |-'; color = Colors.greenAccent;  // XIC
    }

    return InkWell(
      onTap: () => _showEditInstructionDialog(inst),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 12),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color, width: 1.5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(inst.operandTag,
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: color, fontFamily: 'monospace'),
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 3),
            Text(symbol,
                style: TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold, fontSize: 15, color: color)),
            const SizedBox(height: 1),
            Text(inst.type, style: const TextStyle(fontSize: 8, color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}
