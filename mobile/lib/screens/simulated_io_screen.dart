import 'package:flutter/material.dart';
import '../models/project_model.dart';
import '../models/tag_resolver.dart';
import '../ui/responsive.dart';
import '../widgets/tag_autocomplete_field.dart';

class SimulatedIoScreen extends StatefulWidget {
  final PlcProject currentProject;
  final VoidCallback onProjectUpdated;

  const SimulatedIoScreen({
    super.key,
    required this.currentProject,
    required this.onProjectUpdated,
  });

  @override
  State<SimulatedIoScreen> createState() => _SimulatedIoScreenState();
}

const List<String> _behaviors = [
  'setWhileCondition',
  'delayedSet',
  'pulse',
  'ramp',
  'integrate',
  'firstOrderLag',
  'deadTime',
];

const Map<String, String> _behaviorLabels = {
  'setWhileCondition': 'Set While Condition',
  'delayedSet': 'Delayed Set',
  'pulse': 'Pulse',
  'ramp': 'Ramp',
  'integrate': 'Integrate',
  'firstOrderLag': 'First-Order Lag (process response)',
  'deadTime': 'Transport Dead-Time',
};
const List<String> _comparators = ['>', '<', '>=', '<=', '==', '!='];

class _SimulatedIoScreenState extends State<SimulatedIoScreen> {
  int _nextId() {
    int i = 0;
    final used = widget.currentProject.simRules.map((r) => r.id).toSet();
    while (used.contains('sim$i')) {
      i++;
    }
    return i;
  }

  String _conditionSummary(SimRule r) {
    if (r.condition.isEmpty) {
      return 'Always';
    }
    return r.condition.map((c) => '${c.leftPath} ${c.comparator} ${c.operand}').join(' AND ');
  }

  String _behaviorSummary(SimRule r) {
    switch (r.behavior) {
      case 'setWhileCondition':
        return 'set TRUE while condition';
      case 'delayedSet':
        return 'TRUE after ${r.delayMs}ms';
      case 'pulse':
        return 'pulse ${r.onMs}/${r.offMs}ms';
      case 'ramp':
        return 'ramp to ${r.targetValue} @ ${r.ratePerSec}/s';
      case 'integrate':
        return 'integrate ${r.ratePerSec >= 0 ? '+' : ''}${r.ratePerSec}/s';
      case 'firstOrderLag':
        return 'lag τ=${r.tauSec}s → ${r.sourcePath.isNotEmpty ? r.sourcePath : r.targetValue}';
      case 'deadTime':
        return 'dead time τ=${r.tauSec}s of ${r.sourcePath.isNotEmpty ? r.sourcePath : '(no source)'}';
      default:
        return r.behavior;
    }
  }

  @override
  Widget build(BuildContext context) {
    final rules = widget.currentProject.simRules;
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        title: const Text('Simulated I/O — Input Behaviour Rules'),
        backgroundColor: const Color(0xFF1E293B),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.add, size: 16, color: Colors.cyanAccent),
            label: const Text('Add Rule', style: TextStyle(color: Colors.cyanAccent)),
            onPressed: _addRule,
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: rules.isEmpty
          ? const Center(
              child: Text('No simulated inputs yet. Add a rule to drive an input tag over time.',
                  style: TextStyle(color: Colors.grey)))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: rules.length,
              itemBuilder: (context, i) => _ruleCard(rules[i], i),
            ),
    );
  }

  Widget _ruleCard(SimRule r, int index) {
    return Card(
      color: const Color(0xFF1E293B),
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: Switch(
          value: r.enabled,
          activeThumbColor: Colors.greenAccent,
          onChanged: (v) {
            setState(() => r.enabled = v);
            widget.onProjectUpdated();
          },
        ),
        title: Text('${r.name}  →  ${r.targetPath}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_behaviorSummary(r), style: const TextStyle(fontSize: 11, color: Colors.cyanAccent)),
            Text('when: ${_conditionSummary(r)}', style: const TextStyle(fontSize: 11, color: Colors.amberAccent)),
          ],
        ),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            icon: const Icon(Icons.edit, size: 18, color: Colors.grey),
            onPressed: () => _editRule(r),
          ),
          IconButton(
            icon: const Icon(Icons.delete, size: 18, color: Colors.redAccent),
            onPressed: () {
              setState(() => widget.currentProject.simRules.removeAt(index));
              widget.onProjectUpdated();
            },
          ),
        ]),
      ),
    );
  }

  void _addRule() {
    final paths = leafAndNodePaths(widget.currentProject);
    final rule = SimRule(
      id: 'sim${_nextId()}',
      name: 'New Rule',
      targetPath: paths.isNotEmpty ? paths.first : '',
      behavior: 'integrate',
    );
    _editRule(rule, isNew: true);
  }

  void _editRule(SimRule rule, {bool isNew = false}) {
    final working = SimRule.fromJson(rule.toJson()); // edit a copy
    final nameCtrl = TextEditingController(text: working.name);
    final paths = leafAndNodePaths(widget.currentProject);

    showAdaptiveWidthDialog(
      context,
      desiredWidth: 460,
      child: StatefulBuilder(
        builder: (context, setDlg) {
          final numeric = working.behavior == 'ramp' || working.behavior == 'integrate';
          return AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            title: Text(isNew ? 'Add Simulated Input' : 'Edit Simulated Input'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: 'Name'),
                    onChanged: (v) => working.name = v,
                  ),
                  const SizedBox(height: 8),
                  TagAutocompleteField(
                    options: paths,
                    initialValue: working.targetPath,
                    label: 'Target tag',
                    allowFreeText: false,
                    onChanged: (v) => setDlg(() => working.targetPath = v),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: working.behavior,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Behaviour'),
                    items: _behaviors
                        .map((b) => DropdownMenuItem(
                              value: b,
                              child: Text(_behaviorLabels[b] ?? b, style: const TextStyle(fontSize: 12)),
                            ))
                        .toList(),
                    onChanged: (v) => setDlg(() => working.behavior = v ?? working.behavior),
                  ),
                  const SizedBox(height: 8),
                  ..._behaviorParams(working, numeric, paths, setDlg),
                  const Divider(color: Colors.white24),
                  const Text('Condition (AND — empty = Always)', style: TextStyle(fontSize: 11, color: Colors.amberAccent)),
                  ..._conditionRows(context, working, paths, setDlg),
                  TextButton.icon(
                    icon: const Icon(Icons.add, size: 14),
                    label: const Text('Add condition clause'),
                    onPressed: () => setDlg(() => working.condition.add(SimClause(leftPath: paths.isNotEmpty ? paths.first : ''))),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () {
                  working.name = nameCtrl.text;
                  setState(() {
                    if (isNew) {
                      widget.currentProject.simRules.add(working);
                    } else {
                      final idx = widget.currentProject.simRules.indexWhere((r) => r.id == rule.id);
                      if (idx != -1) {
                        widget.currentProject.simRules[idx] = working;
                      }
                    }
                  });
                  widget.onProjectUpdated();
                  Navigator.pop(context);
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _behaviorParams(SimRule r, bool numeric, List<String> paths, StateSetter setDlg) {
    final w = <Widget>[];
    if (r.behavior == 'delayedSet') {
      w.add(_numField('Delay (ms)', r.delayMs.toDouble(), (v) => r.delayMs = v.toInt()));
    }
    if (r.behavior == 'pulse') {
      w.add(_numField('On (ms)', r.onMs.toDouble(), (v) => r.onMs = v.toInt()));
      w.add(_numField('Off (ms)', r.offMs.toDouble(), (v) => r.offMs = v.toInt()));
    }
    if (numeric) {
      w.add(_numField('Rate / second', r.ratePerSec, (v) => r.ratePerSec = v));
      if (r.behavior == 'ramp') {
        w.add(_numField('Target value', r.targetValue, (v) => r.targetValue = v));
      }
      w.add(_numField('Min', r.minValue, (v) => r.minValue = v));
      w.add(_numField('Max', r.maxValue, (v) => r.maxValue = v));
      w.add(const Padding(
        padding: EdgeInsets.only(top: 10, bottom: 2),
        child: Text('Rate driven by tag (optional)', style: TextStyle(fontSize: 11, color: Colors.amberAccent)),
      ));
      w.add(Padding(
        padding: const EdgeInsets.only(top: 4),
        child: TagAutocompleteField(
          options: paths,
          initialValue: r.sourcePath,
          label: 'Rate source tag (blank = fixed rate)',
          allowFreeText: true,
          onChanged: (v) => setDlg(() => r.sourcePath = v),
        ),
      ));
      w.add(_numField('= 100% rate at', r.refValue, (v) => r.refValue = v));
    }
    if (r.behavior == 'firstOrderLag') {
      w.add(_numField('Time constant τ (seconds)', r.tauSec, (v) => r.tauSec = v));
      w.add(_numField('Target value', r.targetValue, (v) => r.targetValue = v));
      w.add(const Padding(
        padding: EdgeInsets.only(top: 10, bottom: 2),
        child: Text('Target from tag (optional)', style: TextStyle(fontSize: 11, color: Colors.amberAccent)),
      ));
      w.add(Padding(
        padding: const EdgeInsets.only(top: 4),
        child: TagAutocompleteField(
          options: paths,
          initialValue: r.sourcePath,
          label: 'Target source tag (blank = use Target value)',
          allowFreeText: true,
          onChanged: (v) => setDlg(() => r.sourcePath = v),
        ),
      ));
      w.add(_numField('Min', r.minValue, (v) => r.minValue = v));
      w.add(_numField('Max', r.maxValue, (v) => r.maxValue = v));
    }
    if (r.behavior == 'deadTime') {
      w.add(Padding(
        padding: const EdgeInsets.only(top: 4),
        child: TagAutocompleteField(
          options: paths,
          initialValue: r.sourcePath,
          label: 'Delayed source tag',
          allowFreeText: true,
          onChanged: (v) => setDlg(() => r.sourcePath = v),
        ),
      ));
      w.add(_numField('Dead time τ (seconds)', r.tauSec, (v) => r.tauSec = v));
      w.add(_numField('Min', r.minValue, (v) => r.minValue = v));
      w.add(_numField('Max', r.maxValue, (v) => r.maxValue = v));
    }
    return w;
  }

  Widget _numField(String label, double value, void Function(double) onChanged) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: TextFormField(
        initialValue: value.toString(),
        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
        decoration: InputDecoration(labelText: label, isDense: true),
        onChanged: (v) => onChanged(double.tryParse(v) ?? value),
      ),
    );
  }

  List<Widget> _conditionRows(BuildContext context, SimRule r, List<String> paths, StateSetter setDlg) {
    final compact = context.isCompact;
    return r.condition.asMap().entries.map((e) {
      final c = e.value;
      final isTagOperand = c.operandKind == 'tag';

      final leftField = TagAutocompleteField(
        options: paths,
        initialValue: c.leftPath,
        allowFreeText: false,
        onChanged: (v) => setDlg(() => c.leftPath = v),
      );
      final comparatorField = DropdownButtonFormField<String>(
        initialValue: c.comparator,
        isExpanded: true,
        decoration: const InputDecoration(isDense: true),
        items: _comparators.map((o) => DropdownMenuItem(value: o, child: Text(o))).toList(),
        onChanged: (v) => setDlg(() => c.comparator = v ?? c.comparator),
      );
      final operandKindField = DropdownButtonFormField<String>(
        initialValue: c.operandKind,
        isExpanded: true,
        decoration: const InputDecoration(isDense: true),
        items: const [
          DropdownMenuItem(value: 'literal', child: Text('val', style: TextStyle(fontSize: 11))),
          DropdownMenuItem(value: 'tag', child: Text('tag', style: TextStyle(fontSize: 11))),
        ],
        onChanged: (v) => setDlg(() {
          c.operandKind = v ?? c.operandKind;
          if (c.operandKind == 'tag' && !paths.contains(c.operand)) {
            c.operand = paths.isNotEmpty ? paths.first : '';
          }
        }),
      );
      final operandField = isTagOperand
          ? TagAutocompleteField(
              options: paths,
              initialValue: c.operand,
              onChanged: (v) => setDlg(() => c.operand = v),
            )
          : TextFormField(
              initialValue: c.operand,
              decoration: const InputDecoration(isDense: true, hintText: 'value'),
              onChanged: (v) => c.operand = v,
            );
      final removeButton = IconButton(
        icon: const Icon(Icons.close, size: 16, color: Colors.redAccent),
        onPressed: () => setDlg(() => r.condition.removeAt(e.key)),
      );

      if (compact) {
        // Stack the operand controls vertically so none get squeezed below a
        // usable width on a narrow screen.
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              leftField,
              const SizedBox(height: 6),
              Row(children: [
                Expanded(child: comparatorField),
                const SizedBox(width: 6),
                SizedBox(width: 72, child: operandKindField),
              ]),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(child: operandField),
                removeButton,
              ]),
            ],
          ),
        );
      }

      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(children: [
          Expanded(flex: 3, child: leftField),
          const SizedBox(width: 4),
          Expanded(flex: 2, child: comparatorField),
          const SizedBox(width: 4),
          SizedBox(width: 56, child: operandKindField),
          const SizedBox(width: 4),
          Expanded(flex: 3, child: operandField),
          removeButton,
        ]),
      );
    }).toList();
  }
}
