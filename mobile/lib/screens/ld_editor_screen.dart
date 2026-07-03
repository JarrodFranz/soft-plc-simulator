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
          comment: 'Rung 0: RSLogix Style Timer On Delay (TON) with Parallel Branch',
          inputInstructions: [
            LdInstruction(type: 'XIO', operandTag: 'TONTimer.DN', comment: 'Normally Closed Timer Done Bit'),
            LdInstruction(type: 'TON', operandTag: 'TONTimer', presetMs: 5000, comment: '5 Second TON Timer'),
          ],
          outputInstructions: [
            LdInstruction(type: 'OTE', operandTag: 'MainContactor', comment: 'Main Motor Contactor'),
          ],
          parallelBranches: [
            LdBranch(
              inputInstructions: [
                LdInstruction(type: 'XIC', operandTag: 'TONTimer.DN', comment: 'Examine if Timer Done'),
              ],
              outputInstructions: [
                LdInstruction(type: 'OTE', operandTag: 'Arbor1Oiler', comment: 'Arbor 1 Oiler Solenoid Coil'),
              ],
            ),
          ],
        ),
      ]);
    }

    // Auto register TONTimer tags
    _registerTimerTags('TONTimer', 5000);
  }

  void _registerTimerTags(String timerName, int presetMs) {
    final subTags = [
      {'name': '$timerName.PRE', 'type': 'INT32', 'val': presetMs, 'desc': 'Timer Preset (ms)'},
      {'name': '$timerName.ACC', 'type': 'INT32', 'val': 0, 'desc': 'Timer Accumulator (ms)'},
      {'name': '$timerName.EN', 'type': 'BOOL', 'val': false, 'desc': 'Timer Enable Bit'},
      {'name': '$timerName.TT', 'type': 'BOOL', 'val': false, 'desc': 'Timer Timing Bit'},
      {'name': '$timerName.DN', 'type': 'BOOL', 'val': false, 'desc': 'Timer Done Bit'},
    ];

    for (var st in subTags) {
      if (!widget.currentProject.tags.any((t) => t.name == st['name'])) {
        widget.currentProject.tags.add(PlcTag(
          name: st['name'] as String,
          path: 'Timers/${st['name']}',
          dataType: st['type'] as String,
          value: st['val'],
          ioType: 'Internal',
          description: st['desc'] as String,
        ));
      }
    }
  }

  void _addNewRung([int? insertAt]) {
    setState(() {
      final newRung = LdRung(
        rungIndex: insertAt ?? widget.program.rungs.length,
        comment: 'Rung ${widget.program.rungs.length}: New Rung',
        inputInstructions: [LdInstruction(type: 'XIC', operandTag: 'Start_PB')],
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
        inputInstructions: [LdInstruction(type: 'XIC', operandTag: 'TONTimer.DN')],
        outputInstructions: [LdInstruction(type: 'OTE', operandTag: 'Arbor1Oiler')],
      ));
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

  void _showAddInstructionDialog(LdRung rung, bool isInput, [LdBranch? targetBranch]) {
    String type = isInput ? 'XIC' : 'OTE';
    String tag = widget.currentProject.tags.isNotEmpty ? widget.currentProject.tags.first.name : 'Start_PB';
    final commentCtrl = TextEditingController();
    int presetMs = 5000;

    final inputTypes = [
      {'type': 'XIC', 'label': 'XIC — Examine if Closed (-| |-) [NO Contact]'},
      {'type': 'XIO', 'label': 'XIO — Examine if Open (-|/|-) [NC Contact]'},
      {'type': 'TON', 'label': 'TON — RSLogix Style Timer On Delay Box (EN, DN Out Pins)'},
      {'type': 'TOF', 'label': 'TOF — RSLogix Style Timer Off Delay Box (EN, DN Out Pins)'},
    ];

    final outputTypes = [
      {'type': 'OTE', 'label': 'OTE — Output Coil (-( )-) [Standard]' },
      {'type': 'OTL', 'label': 'OTL — Output Latch (-(L)-) [Set]' },
      {'type': 'OTU', 'label': 'OTU — Output Unlatch (-(U)-) [Reset]' },
    ];

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDlgState) => AlertDialog(
            title: Text(isInput ? 'Add Input Contact / Timer to Rung' : 'Add Output Coil to Rung'),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    value: type,
                    decoration: const InputDecoration(labelText: 'Instruction Type'),
                    items: (isInput ? inputTypes : outputTypes).map((t) => DropdownMenuItem(
                      value: t['type'],
                      child: Text(t['label']!),
                    )).toList(),
                    onChanged: (val) => setDlgState(() => type = val!),
                  ),
                  const SizedBox(height: 12),

                  DropdownButtonFormField<String>(
                    value: widget.currentProject.tags.any((t) => t.name == tag) ? tag : null,
                    decoration: const InputDecoration(labelText: 'Operand Tag / Timer Structure Binding'),
                    items: widget.currentProject.tags.map((t) => DropdownMenuItem(
                      value: t.name,
                      child: Text('${t.name} [${t.dataType}] — ${t.path}'),
                    )).toList(),
                    onChanged: (val) => setDlgState(() => tag = val!),
                  ),
                  const SizedBox(height: 12),

                  if (type == 'TON' || type == 'TOF') ...[
                    TextField(
                      controller: TextEditingController(text: presetMs.toString()),
                      keyboardType: TextInputType.number,
                      onChanged: (v) => presetMs = int.tryParse(v) ?? 5000,
                      decoration: const InputDecoration(labelText: 'Timer Preset Time (PRE) in Milliseconds (ms)'),
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

                  if (type == 'TON' || type == 'TOF') {
                    _registerTimerTags(tag, presetMs);
                  }

                  setState(() {
                    if (targetBranch != null) {
                      if (isInput) {
                        targetBranch.inputInstructions.add(inst);
                      } else {
                        targetBranch.outputInstructions.add(inst);
                      }
                    } else {
                      if (isInput) {
                        rung.inputInstructions.add(inst);
                      } else {
                        rung.outputInstructions.add(inst);
                      }
                    }
                  });
                  widget.onProgramUpdated();
                  Navigator.pop(ctx);
                },
                child: const Text('Add Instruction'),
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
              title: Text('Edit Component: ${inst.type} (${inst.operandTag})'),
              content: SizedBox(
                width: 440,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DropdownButtonFormField<String>(
                      value: selectedType,
                      decoration: const InputDecoration(labelText: 'Instruction Type'),
                      items: const [
                        DropdownMenuItem(value: 'XIC', child: Text('XIC — Examine Closed (-| |-)')),
                        DropdownMenuItem(value: 'XIO', child: Text('XIO — Examine Open (-|/|-)')),
                        DropdownMenuItem(value: 'OTE', child: Text('OTE — Output Coil (-( )-)')),
                        DropdownMenuItem(value: 'OTL', child: Text('OTL — Output Latch (-(L)-)')),
                        DropdownMenuItem(value: 'OTU', child: Text('OTU — Output Unlatch (-(U)-)')),
                        DropdownMenuItem(value: 'TON', child: Text('TON — RSLogix Style Timer On Delay Box')),
                        DropdownMenuItem(value: 'TOF', child: Text('TOF — RSLogix Style Timer Off Delay Box')),
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

                    // Quick Autocomplete Tag Selection Chips
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
                            title: Text(t.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                            subtitle: Text('${t.path} [${t.dataType}]', style: const TextStyle(fontSize: 10, color: Colors.grey)),
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
                        decoration: const InputDecoration(labelText: 'Timer Preset Time (PRE) in ms'),
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

                    if (selectedType == 'TON' || selectedType == 'TOF') {
                      _registerTimerTags(newTag, newPreset);
                    }

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
        title: Text('${widget.program.name} — RSLogix Style Ladder Logic (LD) Editor'),
        backgroundColor: const Color(0xFF1E293B),
        actions: [
          ElevatedButton.icon(
            icon: const Icon(Icons.add, size: 16),
            label: const Text('Add New Rung'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.cyan, foregroundColor: Colors.black),
            onPressed: () => _addNewRung(),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Row(
        children: [
          // CENTER WORKSPACE: Visual Rung Diagram Canvas with RSLogix Timers & Parallel Branches
          Expanded(
            child: Container(
              color: const Color(0xFF0F172A),
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: widget.program.rungs.length,
                itemBuilder: (context, index) {
                  final rung = widget.program.rungs[index];
                  return _buildRungCard(rung, index);
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
                      const Text('TAG & INSTRUCTION AUTOCOMPLETE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.cyanAccent)),
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
                            title: Text(tag.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                            subtitle: Text('${tag.path} [${tag.dataType}]', style: const TextStyle(fontSize: 10, color: Colors.grey)),
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

  Widget _buildRungCard(LdRung rung, int index) {
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

            // Rung Graphical Power Rail Line Canvas
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.cyan.withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Main Rung Line
                  _buildSingleRungLine(rung, rung.inputInstructions, rung.outputInstructions, null),

                  // Parallel Branches (OR Frames)
                  ...rung.parallelBranches.map((branch) {
                    return Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          const SizedBox(width: 22),
                          // Drop line from main branch
                          Container(width: 3, height: 40, color: Colors.greenAccent),
                          Expanded(
                            child: _buildSingleRungLine(rung, branch.inputInstructions, branch.outputInstructions, branch),
                          ),
                          // Rise line back to main rail
                          Container(width: 3, height: 40, color: Colors.blueAccent),
                          const SizedBox(width: 22),
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

  Widget _buildSingleRungLine(LdRung rung, List<LdInstruction> inputs, List<LdInstruction> outputs, LdBranch? branch) {
    return Row(
      children: [
        // Left Power Rail (L1 - 24VDC)
        Column(
          children: [
            Container(width: 6, height: 75, color: Colors.greenAccent),
            const Text('L1', style: TextStyle(fontSize: 8, color: Colors.greenAccent, fontWeight: FontWeight.bold)),
          ],
        ),
        Container(width: 16, height: 3, color: Colors.greenAccent),

        // Input Contacts Flow
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ...inputs.map((inst) => _buildInstructionGraphic(inst, rung, true)),
                IconButton(
                  icon: const Icon(Icons.add_box, color: Colors.cyanAccent, size: 22),
                  tooltip: 'Add Contact / Timer',
                  onPressed: () => _showAddInstructionDialog(rung, true, branch),
                ),
              ],
            ),
          ),
        ),

        // Wire Line across to Output Coils
        Expanded(child: Container(height: 3, color: Colors.greenAccent)),

        // Output Coils Flow
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              ...outputs.map((inst) => _buildInstructionGraphic(inst, rung, false)),
              IconButton(
                icon: const Icon(Icons.add_box, color: Colors.amberAccent, size: 22),
                tooltip: 'Add Output Coil',
                onPressed: () => _showAddInstructionDialog(rung, false, branch),
              ),
            ],
          ),
        ),

        // Right Power Rail (L2 - Neutral / 0V)
        Container(width: 16, height: 3, color: Colors.blueAccent),
        Column(
          children: [
            Container(width: 6, height: 75, color: Colors.blueAccent),
            const Text('L2', style: TextStyle(fontSize: 8, color: Colors.blueAccent, fontWeight: FontWeight.bold)),
          ],
        ),
      ],
    );
  }

  Widget _buildInstructionGraphic(LdInstruction inst, LdRung rung, bool isInput) {
    final bool isTimer = inst.type == 'TON' || inst.type == 'TOF';

    if (isTimer) {
      // Render Exact RSLogix Style TON Timer Box with (EN) and (DN) Output Pins
      return InkWell(
        onTap: () => _showClickToEditTagDialog(inst),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.grey.shade400, width: 1.5),
            boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 4)],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Timer Box Header (RSLogix Grey Header)
              Container(
                width: 170,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                color: const Color(0xFF334155),
                child: Text(
                  inst.type,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.white, fontFamily: 'monospace'),
                ),
              ),

              // Timer Parameters Body with RSLogix (EN) & (DN) Right Output Pins
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Row(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text('Timer', style: TextStyle(fontSize: 11, color: Colors.grey)),
                            const SizedBox(width: 12),
                            Text(inst.operandTag, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.white, fontFamily: 'monospace')),
                          ],
                        ),
                        Row(
                          children: [
                            const Text('Preset', style: TextStyle(fontSize: 11, color: Colors.grey)),
                            const SizedBox(width: 12),
                            Text('${inst.presetMs}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.cyanAccent, fontFamily: 'monospace')),
                          ],
                        ),
                        const Row(
                          children: [
                            Text('Accum', style: TextStyle(fontSize: 11, color: Colors.grey)),
                            SizedBox(width: 12),
                            Text('0', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.cyanAccent, fontFamily: 'monospace')),
                          ],
                        ),
                      ],
                    ),

                    const SizedBox(width: 12),

                    // RSLogix Output Pins extending out right side of Timer Box: -(EN)- and -(DN)-
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(width: 8, height: 2, color: Colors.greenAccent),
                            const Text('-(EN)-', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.greenAccent, fontFamily: 'monospace')),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Container(width: 8, height: 2, color: Colors.grey),
                            const Text('-(DN)-', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.grey, fontFamily: 'monospace')),
                          ],
                        ),
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
        margin: const EdgeInsets.symmetric(horizontal: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color),
        ),
        child: Column(
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
