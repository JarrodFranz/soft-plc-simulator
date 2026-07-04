import 'package:flutter/material.dart';
import '../models/project_model.dart';

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
        comment: 'Rung ${widget.program.rungs.length}: Rail-to-Rail Continuous Wire Rung',
        inputInstructions: [],
        outputInstructions: [LdInstruction(type: 'OTE', operandTag: 'Motor_Run')],
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
        inputInstructions: [LdInstruction(type: 'XIC', operandTag: 'Motor_Run')],
        outputInstructions: [],
      ));
    });
    widget.onProgramUpdated();
  }

  void _deleteParallelBranch(LdRung rung, int branchIndex) {
    setState(() {
      rung.parallelBranches.removeAt(branchIndex);
    });
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
    String tag = widget.currentProject.tags.isNotEmpty ? widget.currentProject.tags.first.name : 'Start_PB';
    final commentCtrl = TextEditingController();
    int presetMs = 5000;

    final inputTypes = [
      {'type': 'XIC', 'label': 'XIC — Examine if Closed (-| |-)'},
      {'type': 'XIO', 'label': 'XIO — Examine if Open (-|/|-)'},
      {'type': 'TON', 'label': 'TON — IEC 61131-3 Timer On Delay Block'},
      {'type': 'TOF', 'label': 'TOF — IEC 61131-3 Timer Off Delay Block'},
    ];

    final outputTypes = [
      {'type': 'OTE', 'label': 'OTE — Output Coil (-( )-)' },
      {'type': 'OTL', 'label': 'OTL — Output Latch (-(L)-)' },
      {'type': 'OTU', 'label': 'OTU — Output Unlatch (-(U)-)' },
    ];

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
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
                    decoration: const InputDecoration(labelText: 'Operand Tag / Parameter'),
                    items: widget.currentProject.tags.map((t) => DropdownMenuItem(
                      value: t.name,
                      child: Text('${t.name} [${t.dataType}]', overflow: TextOverflow.ellipsis),
                    )).toList(),
                    onChanged: (val) => setDlgState(() => tag = val!),
                  ),
                  const SizedBox(height: 12),

                  if (type == 'TON' || type == 'TOF') ...[
                    TextField(
                      controller: TextEditingController(text: presetMs.toString()),
                      keyboardType: TextInputType.number,
                      onChanged: (v) => presetMs = int.tryParse(v) ?? 5000,
                      decoration: const InputDecoration(labelText: 'Timer Preset Time (PT) in ms'),
                    ),
                    const SizedBox(height: 12),
                  ],

                  TextField(controller: commentCtrl, decoration: const InputDecoration(labelText: 'Instruction Comment / Annotation')),
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
                child: const Text('Insert Component'),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showClickToEditTagDialog(LdInstruction inst) {
    final tagCtrl = TextEditingController(text: inst.operandTag);
    final commentCtrl = TextEditingController(text: inst.comment);
    final presetCtrl = TextEditingController(text: inst.presetMs.toString());
    String selectedType = inst.type;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDlgState) {
            final filteredAutocompleteTags = widget.currentProject.tags.where((t) {
              return t.name.toLowerCase().contains(tagCtrl.text.toLowerCase());
            }).toList();

            return AlertDialog(
              title: Text('Edit IEC 61131-3 Component: ${inst.type} (${inst.operandTag})'),
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
                        DropdownMenuItem(value: 'TON', child: Text('TON — IEC 61131-3 Timer On Delay Block')),
                        DropdownMenuItem(value: 'TOF', child: Text('TOF — IEC 61131-3 Timer Off Delay Block')),
                      ],
                      onChanged: (val) => setDlgState(() => selectedType = val!),
                    ),
                    const SizedBox(height: 12),

                    TextField(
                      controller: tagCtrl,
                      onChanged: (v) => setDlgState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Tag / Bit Parameter (e.g. TONTimer.DN, TONTimer.ACC)',
                        isDense: true,
                        suffixIcon: Icon(Icons.search, size: 16),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),

                    const Text('AUTOCOMPLETE TAG SUGGESTIONS:', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey)),
                    const SizedBox(height: 4),
                    SizedBox(
                      height: 100,
                      child: ListView.builder(
                        itemCount: filteredAutocompleteTags.length,
                        itemBuilder: (ctx, idx) {
                          final t = filteredAutocompleteTags[idx];
                          return ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.label_important, size: 14, color: t.name.contains('.DN') ? Colors.amberAccent : Colors.cyanAccent),
                            title: Text(t.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12), overflow: TextOverflow.ellipsis),
                            subtitle: Text('${t.path} [${t.dataType}]', style: const TextStyle(fontSize: 10, color: Colors.grey), overflow: TextOverflow.ellipsis),
                            onTap: () {
                              setDlgState(() => tagCtrl.text = t.name);
                            },
                          );
                        },
                      ),
                    ),

                    if (selectedType == 'TON' || selectedType == 'TOF') ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: presetCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Timer Preset Time (PT) in ms'),
                      ),
                    ],

                    const SizedBox(height: 12),
                    TextField(controller: commentCtrl, decoration: const InputDecoration(labelText: 'Comment / Annotation')),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                ElevatedButton(
                  onPressed: () {
                    final newTag = tagCtrl.text.trim();
                    final newPreset = int.tryParse(presetCtrl.text) ?? 5000;

                    setState(() {
                      inst.type = selectedType;
                      inst.operandTag = newTag;
                      inst.comment = commentCtrl.text;
                      inst.presetMs = newPreset;
                    });

                    widget.onProgramUpdated();
                    Navigator.pop(ctx);
                  },
                  child: const Text('Apply Changes'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final filteredTags = widget.currentProject.tags.where((t) {
      return t.name.toLowerCase().contains(_tagSearchQuery.toLowerCase()) ||
          t.path.toLowerCase().contains(_tagSearchQuery.toLowerCase());
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.program.name} — IEC 61131-3 Ladder Diagram (LD) Editor'),
        backgroundColor: const Color(0xFF1E293B),
        actions: [
          ElevatedButton.icon(
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add Blank Rung'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.cyan, foregroundColor: Colors.black),
            onPressed: () => _addNewRung(),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Row(
        children: [
          // CENTER WORKSPACE: LD Grid Matrix Rung Canvas
          Expanded(
            child: Container(
              color: const Color(0xFF0F172A),
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: widget.program.rungs.length,
                itemBuilder: (context, index) {
                  final rung = widget.program.rungs[index];
                  return _buildOpenPlcRungCard(rung, index);
                },
              ),
            ),
          ),

          const VerticalDivider(width: 1, color: Colors.white12),

          // RIGHT DOCK: Tag & Instruction Autocomplete Palette
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
                      const Text('TAG & INSTRUCTION PALETTE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.cyanAccent)),
                      const SizedBox(height: 8),
                      TextField(
                        onChanged: (v) => setState(() => _tagSearchQuery = v),
                        decoration: const InputDecoration(
                          hintText: 'Search tags or timer bits (.DN)...',
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
                      const Text('CLICK TO COPY TAG / AUTOCOMPLETE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.grey)),
                      const SizedBox(height: 6),
                      ...filteredTags.map((tag) => Card(
                        color: const Color(0xFF1E293B),
                        margin: const EdgeInsets.only(bottom: 6),
                        child: Material(
                          color: Colors.transparent,
                          child: ListTile(
                            dense: true,
                            leading: Icon(
                              tag.name.contains('.DN')
                                  ? Icons.timer
                                  : (tag.ioType == 'SimulatedInput' ? Icons.login : (tag.ioType == 'SimulatedOutput' ? Icons.logout : Icons.storage)),
                              size: 16,
                              color: tag.name.contains('.DN')
                                  ? Colors.amberAccent
                                  : (tag.ioType == 'SimulatedInput' ? Colors.greenAccent : Colors.cyanAccent),
                            ),
                            title: Text(tag.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12), overflow: TextOverflow.ellipsis),
                            subtitle: Text('${tag.path} [${tag.dataType}]', style: const TextStyle(fontSize: 10, color: Colors.grey), overflow: TextOverflow.ellipsis),
                          ),
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

  Widget _buildOpenPlcRungCard(LdRung rung, int index) {
    return Card(
      color: const Color(0xFF1E293B),
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: Colors.white12)),
      child: Padding(
        padding: const EdgeInsets.all(14.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Rung Header Bar
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: Colors.cyan.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(4)),
                  child: Text('RUNG $index', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.cyanAccent, fontSize: 11)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: TextEditingController(text: rung.comment),
                    onSubmitted: (val) {
                      setState(() => rung.comment = val);
                      widget.onProgramUpdated();
                    },
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.grey),
                    decoration: const InputDecoration(isDense: true, border: InputBorder.none, hintText: 'Enter Rung Comment...'),
                  ),
                ),

                IconButton(
                  icon: const Icon(Icons.add_road, size: 16, color: Colors.tealAccent),
                  tooltip: 'Add Parallel Branch',
                  onPressed: () => _addParallelBranch(rung),
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_upward, size: 16, color: Colors.grey),
                  tooltip: 'Move Rung Up',
                  onPressed: index > 0 ? () => _moveRung(index, -1) : null,
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_downward, size: 16, color: Colors.grey),
                  tooltip: 'Move Rung Down',
                  onPressed: index < widget.program.rungs.length - 1 ? () => _moveRung(index, 1) : null,
                ),
                IconButton(
                  icon: const Icon(Icons.add, size: 16, color: Colors.greenAccent),
                  tooltip: 'Insert Rung Below',
                  onPressed: () => _addNewRung(index + 1),
                ),
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
                  },
                ),
              ],
            ),

            const SizedBox(height: 12),

            // IEC 61131-3 Grid Matrix Rung Container with Rail-to-Rail Wire Pass
            Container(
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.cyan.withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Main Rung Line
                  _buildOpenPlcGridRungLine(rung, rung.inputInstructions, rung.outputInstructions, null),

                  // Parallel Branches (OR Branch Lines)
                  ...List.generate(rung.parallelBranches.length, (bIdx) {
                    final branch = rung.parallelBranches[bIdx];

                    return Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Row(
                        children: [
                          const SizedBox(width: 14),
                          // Drop line from main branch
                          Container(width: 3, height: 65, color: Colors.greenAccent),
                          Expanded(
                            child: Row(
                              children: [
                                Expanded(child: _buildOpenPlcGridRungLine(rung, branch.inputInstructions, branch.outputInstructions, branch)),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
                                  tooltip: 'Delete Parallel Branch',
                                  onPressed: () => _deleteParallelBranch(rung, bIdx),
                                ),
                              ],
                            ),
                          ),
                          // Rise line back to main rail
                          Container(width: 3, height: 65, color: Colors.blueAccent),
                          const SizedBox(width: 14),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOpenPlcGridRungLine(LdRung rung, List<LdInstruction> inputs, List<LdInstruction> outputs, LdBranch? branch) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Left Power Rail (L1 - 24VDC)
        Column(
          children: [
            Container(width: 6, height: 80, color: Colors.greenAccent),
            const Text('L1', style: TextStyle(fontSize: 8, color: Colors.greenAccent, fontWeight: FontWeight.bold)),
          ],
        ),

        // Wire trace from L1 to first cell
        Container(width: 16, height: 3, color: Colors.greenAccent),

        // Input Contacts & Functions Grid Cells
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                if (inputs.isEmpty)
                  // Blank Wire Line Cell (Clickable to Insert Component)
                  InkWell(
                    onTap: () => _showAddInstructionDialog(rung, true, branch, 0),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.cyan.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.cyanAccent, width: 1.5),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.add, size: 14, color: Colors.cyanAccent),
                          SizedBox(width: 6),
                          Text('Wire — Click to Insert Contact / Timer', style: TextStyle(fontSize: 11, color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  )
                else
                  ...List.generate(inputs.length, (idx) {
                    final inst = inputs[idx];
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildOpenPlcInstructionGraphic(inst, rung),
                        // Wire segment connecting to next cell
                        Container(width: 20, height: 3, color: Colors.greenAccent),
                      ],
                    );
                  }),

                IconButton(
                  icon: const Icon(Icons.add_box, color: Colors.cyanAccent, size: 22),
                  tooltip: 'Insert Contact onto Wire Grid',
                  onPressed: () => _showAddInstructionDialog(rung, true, branch),
                ),
              ],
            ),
          ),
        ),

        // Unbroken Horizontal Main Circuit Wire passing across to Coil
        Expanded(
          child: Container(height: 3, color: Colors.greenAccent),
        ),

        // Output Coils Grid Cells
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              ...outputs.map((inst) => _buildOpenPlcInstructionGraphic(inst, rung)),
            ],
          ),
        ),

        // Wire trace to L2 rail
        Container(width: 16, height: 3, color: Colors.blueAccent),

        // Right Power Rail (L2 - Neutral / 0V)
        Column(
          children: [
            Container(width: 6, height: 80, color: Colors.blueAccent),
            const Text('L2', style: TextStyle(fontSize: 8, color: Colors.blueAccent, fontWeight: FontWeight.bold)),
          ],
        ),
      ],
    );
  }

  Widget _buildOpenPlcInstructionGraphic(LdInstruction inst, LdRung rung) {
    final bool isTimer = inst.type == 'TON' || inst.type == 'TOF';

    if (isTimer) {
      // IEC 61131-3 Standard Timer Block (IN, Q, PT, ET)
      return InkWell(
        onTap: () => _showClickToEditTagDialog(inst),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: 175,
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.grey.shade400, width: 1.5),
            boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 4)],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Timer Block Header
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                color: const Color(0xFF334155),
                child: Text(
                  '${inst.type} (${inst.operandTag})',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.white, fontFamily: 'monospace'),
                  overflow: TextOverflow.ellipsis,
                ),
              ),

              // IEC 61131-3 Block Pins: IN (Input), Q (Done output), PT (Preset), ET (Elapsed)
              Padding(
                padding: const EdgeInsets.all(6.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Left Input Pins
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('IN', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.greenAccent, fontFamily: 'monospace')),
                        Text('PT', style: TextStyle(fontSize: 10, color: Colors.grey, fontFamily: 'monospace')),
                      ],
                    ),

                    // Center Values
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Text('PT: ${inst.presetMs}ms', style: const TextStyle(fontSize: 9, color: Colors.cyanAccent)),
                        const Text('ET: 0ms', style: TextStyle(fontSize: 9, color: Colors.cyanAccent)),
                      ],
                    ),

                    // Right Output Pins (Q, ET)
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('Q', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.greenAccent, fontFamily: 'monospace')),
                        Text('ET', style: TextStyle(fontSize: 10, color: Colors.grey, fontFamily: 'monospace')),
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

    // Render Contact / Coil Component
    String symbol = '-| |-';
    Color color = Colors.greenAccent;

    if (inst.type == 'XIO') symbol = '-|/|-';
    if (inst.type == 'OTE') { symbol = '-( )-'; color = Colors.amberAccent; }
    if (inst.type == 'OTL') { symbol = '-(L)-'; color = Colors.amberAccent; }
    if (inst.type == 'OTU') { symbol = '-(U)-'; color = Colors.amberAccent; }

    return InkWell(
      onTap: () => _showClickToEditTagDialog(inst),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(inst.operandTag, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: color, fontFamily: 'monospace')),
            const SizedBox(height: 4),
            Text(symbol, style: TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold, fontSize: 15, color: color)),
            const SizedBox(height: 2),
            Text(inst.type, style: const TextStyle(fontSize: 9, color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}
