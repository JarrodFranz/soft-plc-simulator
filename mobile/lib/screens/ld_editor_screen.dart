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
          comment: 'Motor Seal-in Latch Rung',
          inputInstructions: [
            LdInstruction(type: 'XIC', operandTag: 'Start_PB', comment: 'Start Pushbutton (NO)'),
            LdInstruction(type: 'XIO', operandTag: 'Stop_PB', comment: 'Stop Pushbutton (NC)'),
            LdInstruction(type: 'XIC', operandTag: 'EStop_OK', comment: 'Emergency Stop Healthy'),
          ],
          outputInstructions: [
            LdInstruction(type: 'OTL', operandTag: 'Motor_Latch', comment: 'Latch Motor Internal Tag'),
          ],
        ),
        LdRung(
          rungIndex: 1,
          comment: 'Motor Contactor Output Rung',
          inputInstructions: [
            LdInstruction(type: 'XIC', operandTag: 'Motor_Latch', comment: 'Motor Internal Latch'),
            LdInstruction(type: 'XIC', operandTag: 'Overload_OK', comment: 'Thermal Overload Healthy'),
          ],
          outputInstructions: [
            LdInstruction(type: 'OTE', operandTag: 'Motor_Run', comment: 'Output Contactor Solenoid'),
          ],
        ),
      ]);
    }
  }

  void _showAddInstructionDialog(LdRung rung, bool isInput) {
    String type = isInput ? 'XIC' : 'OTE';
    String tag = widget.currentProject.tags.isNotEmpty ? widget.currentProject.tags.first.name : 'Start_PB';
    final commentCtrl = TextEditingController();

    final inputTypes = [
      {'type': 'XIC', 'label': 'XIC — Examine if Closed (-| |-) [NO Contact]'},
      {'type': 'XIO', 'label': 'XIO — Examine if Open (-|/|-) [NC Contact]'},
      {'type': 'TON', 'label': 'TON — Timer On Delay Block'},
      {'type': 'EQU', 'label': 'EQU — Compare Equal (A == B)'},
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
            title: Text(isInput ? 'Add Input Contact / Instruction to Rung' : 'Add Output Coil / Instruction to Rung'),
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

                  // Tag Autocomplete Dropdown
                  DropdownButtonFormField<String>(
                    value: tag,
                    decoration: const InputDecoration(labelText: 'Operand Tag Binding'),
                    items: widget.currentProject.tags.map((t) => DropdownMenuItem(
                      value: t.name,
                      child: Text('${t.name} [${t.dataType}] — ${t.path}'),
                    )).toList(),
                    onChanged: (val) => setDlgState(() => tag = val!),
                  ),
                  const SizedBox(height: 12),

                  TextField(controller: commentCtrl, decoration: const InputDecoration(labelText: 'Instruction Comment / Annotation')),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () {
                  final inst = LdInstruction(type: type, operandTag: tag, comment: commentCtrl.text);
                  setState(() {
                    if (isInput) {
                      rung.inputInstructions.add(inst);
                    } else {
                      rung.outputInstructions.add(inst);
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

  void _addNewRung() {
    setState(() {
      widget.program.rungs.add(LdRung(
        rungIndex: widget.program.rungs.length,
        comment: 'Rung ${widget.program.rungs.length}',
        inputInstructions: [LdInstruction(type: 'XIC', operandTag: 'Start_PB')],
        outputInstructions: [LdInstruction(type: 'OTE', operandTag: 'Motor_Run')],
      ));
    });
    widget.onProgramUpdated();
  }

  @override
  Widget build(BuildContext context) {
    final filteredTags = widget.currentProject.tags.where((t) {
      return t.name.toLowerCase().contains(_tagSearchQuery.toLowerCase()) ||
          t.path.toLowerCase().contains(_tagSearchQuery.toLowerCase());
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.program.name} — Ladder Logic (LD) Editor'),
        backgroundColor: const Color(0xFF1E293B),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_circle, color: Colors.greenAccent),
            tooltip: 'Add Rung to Ladder Diagram',
            onPressed: _addNewRung,
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Row(
        children: [
          // CENTER WORKSPACE: Visual Rung Diagram Canvas
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
                      const Text('TAG & INSTRUCTION AUTOCOMPLETE', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: Colors.cyanAccent)),
                      const SizedBox(height: 8),
                      TextField(
                        onChanged: (v) => setState(() => _tagSearchQuery = v),
                        decoration: const InputDecoration(
                          hintText: 'Search tags or instructions...',
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
                      const Text('AVAILABLE TAGS', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 10, color: Colors.grey)),
                      const SizedBox(height: 6),
                      ...filteredTags.map((tag) => Card(
                        color: const Color(0xFF1E293B),
                        margin: const EdgeInsets.only(bottom: 6),
                        child: Material(
                          color: Colors.transparent,
                          child: ListTile(
                            dense: true,
                            leading: Icon(
                              tag.ioType == 'SimulatedInput' ? Icons.login : (tag.ioType == 'SimulatedOutput' ? Icons.logout : Icons.storage),
                              size: 16,
                              color: tag.ioType == 'SimulatedInput' ? Colors.greenAccent : Colors.amberAccent,
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
            // Rung Header
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: Colors.cyan.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(4)),
                  child: Text('RUNG ${rung.rungIndex + 1}', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.cyanAccent, fontSize: 11)),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(rung.comment, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.grey))),
                IconButton(
                  icon: const Icon(Icons.delete, size: 16, color: Colors.redAccent),
                  onPressed: () {
                    setState(() {
                      widget.program.rungs.removeAt(index);
                    });
                    widget.onProgramUpdated();
                  },
                ),
              ],
            ),

            const SizedBox(height: 12),

            // Rung Graphical Power Rail Line
            Container(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.cyan.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  // Left Power Rail (L1)
                  Container(width: 6, height: 60, color: Colors.greenAccent),
                  Container(width: 16, height: 3, color: Colors.greenAccent),

                  // Input Contacts Flow
                  Expanded(
                    child: Row(
                      children: [
                        ...rung.inputInstructions.map((inst) => _buildInstructionGraphic(inst, rung, true)),
                        IconButton(
                          icon: const Icon(Icons.add_box, color: Colors.cyanAccent, size: 20),
                          tooltip: 'Add Contact',
                          onPressed: () => _showAddInstructionDialog(rung, true),
                        ),
                      ],
                    ),
                  ),

                  // Wire Line across to Coil
                  Expanded(child: Container(height: 3, color: Colors.greenAccent)),

                  // Output Coils Flow
                  Row(
                    children: [
                      ...rung.outputInstructions.map((inst) => _buildInstructionGraphic(inst, rung, false)),
                      IconButton(
                        icon: const Icon(Icons.add_box, color: Colors.amberAccent, size: 20),
                        tooltip: 'Add Coil',
                        onPressed: () => _showAddInstructionDialog(rung, false),
                      ),
                    ],
                  ),

                  // Right Power Rail (L2 / Neutral)
                  Container(width: 16, height: 3, color: Colors.blueAccent),
                  Container(width: 6, height: 60, color: Colors.blueAccent),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInstructionGraphic(LdInstruction inst, LdRung rung, bool isInput) {
    String symbol = '-| |-';
    Color color = Colors.greenAccent;

    if (inst.type == 'XIO') symbol = '-|/|-';
    if (inst.type == 'OTE') { symbol = '-( )-'; color = Colors.amberAccent; }
    if (inst.type == 'OTL') { symbol = '-(L)-'; color = Colors.amberAccent; }
    if (inst.type == 'OTU') { symbol = '-(U)-'; color = Colors.amberAccent; }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color),
      ),
      child: Column(
        children: [
          Text(inst.operandTag, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: color)),
          const SizedBox(height: 4),
          Text(symbol, style: TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold, fontSize: 14, color: color)),
          const SizedBox(height: 2),
          Text(inst.type, style: const TextStyle(fontSize: 9, color: Colors.grey)),
        ],
      ),
    );
  }
}
