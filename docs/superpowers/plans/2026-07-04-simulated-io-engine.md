# Simulated I/O Engine (WS3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an editable "Simulated I/O" system — data-driven rules that drive input tags (pulse/ramp/integrate/delayed-set/set-while-condition) gated by conditions — and migrate the hardcoded per-project input physics into visible default rules.

**Architecture:** A pure `sim_engine.dart` applies a project's `SimRule` list each scan (reading conditions via the WS2 resolver, writing targets via `writePath`, respecting forcing), keeping per-rule timing state in a `SimRuntime`. A new `SimulatedIoScreen` edits the rules; `workspace_shell` runs the engine before its control logic and exposes the screen via a sidebar entry.

**Tech Stack:** Flutter / Dart (web), `flutter test`, `flutter analyze`, Chrome preview.

## Global Constraints

- No third-party or reference-editor branding in any user-facing string, label, comment, or identifier.
- Dark theme preserved. `flutter analyze` must report **zero** issues. Use `withValues(alpha:)` (not `withOpacity`), `initialValue:` (not `value:`) on `DropdownButtonFormField`, braces on all flow-control bodies, prefer `const`, `x.isNotEmpty` not `x.length >= 1`.
- No RenderFlex overflow.
- All shell commands run from `mobile/`.
- Rates are **per-second**; the engine multiplies by `dtMs/1000`. A rule never overwrites a **forced** root tag (root tag `isForced && targetPath == root.name`).

**Sequencing:** Task 1 (model) and Task 2 (engine) are additive/green. Task 3 (screen + nav) is additive/green. Task 4 wires the engine into the scan and migrates the hardcoded input sim. Task 5 validates.

---

### Task 1: SimRule / SimClause model

**Files:**
- Modify: `mobile/lib/models/project_model.dart`

**Interfaces:**
- Produces (used by Tasks 2-4): `class SimClause { String leftPath, comparator, operandKind, operand; }`; `class SimRule { String id, name; bool enabled; String targetPath, behavior; int delayMs, onMs, offMs; double ratePerSec, targetValue, minValue, maxValue; List<SimClause> condition; }`; `PlcProject.simRules` (optional, defaults to `[]`).

- [ ] **Step 1: Add the model classes**

In `mobile/lib/models/project_model.dart`, add these classes (near the other model classes, e.g. after `PlcTask`):

```dart
class SimClause {
  String leftPath;
  String comparator; // '>','<','>=','<=','==','!='
  String operandKind; // 'literal' | 'tag'
  String operand;     // literal text ('true'/'false'/number) or a tag path

  SimClause({
    required this.leftPath,
    this.comparator = '>',
    this.operandKind = 'literal',
    this.operand = '0',
  });

  factory SimClause.fromJson(Map<String, dynamic> j) => SimClause(
        leftPath: j['left'] ?? '',
        comparator: j['cmp'] ?? '>',
        operandKind: j['kind'] ?? 'literal',
        operand: j['operand']?.toString() ?? '0',
      );

  Map<String, dynamic> toJson() => {
        'left': leftPath,
        'cmp': comparator,
        'kind': operandKind,
        'operand': operand,
      };
}

class SimRule {
  String id;
  String name;
  bool enabled;
  String targetPath;
  String behavior; // 'setWhileCondition'|'delayedSet'|'pulse'|'ramp'|'integrate'
  int delayMs;
  int onMs;
  int offMs;
  double ratePerSec;
  double targetValue;
  double minValue;
  double maxValue;
  List<SimClause> condition;

  SimRule({
    required this.id,
    required this.name,
    this.enabled = true,
    required this.targetPath,
    required this.behavior,
    this.delayMs = 1000,
    this.onMs = 500,
    this.offMs = 500,
    this.ratePerSec = 1.0,
    this.targetValue = 0.0,
    this.minValue = 0.0,
    this.maxValue = 100.0,
    List<SimClause>? condition,
  }) : condition = condition ?? [];

  factory SimRule.fromJson(Map<String, dynamic> j) => SimRule(
        id: j['id'] ?? '',
        name: j['name'] ?? '',
        enabled: j['enabled'] ?? true,
        targetPath: j['target'] ?? '',
        behavior: j['behavior'] ?? 'integrate',
        delayMs: j['delay_ms'] ?? 1000,
        onMs: j['on_ms'] ?? 500,
        offMs: j['off_ms'] ?? 500,
        ratePerSec: (j['rate'] as num?)?.toDouble() ?? 1.0,
        targetValue: (j['target_value'] as num?)?.toDouble() ?? 0.0,
        minValue: (j['min'] as num?)?.toDouble() ?? 0.0,
        maxValue: (j['max'] as num?)?.toDouble() ?? 100.0,
        condition: (j['condition'] as List? ?? []).map((c) => SimClause.fromJson(c)).toList(),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'enabled': enabled,
        'target': targetPath,
        'behavior': behavior,
        'delay_ms': delayMs,
        'on_ms': onMs,
        'off_ms': offMs,
        'rate': ratePerSec,
        'target_value': targetValue,
        'min': minValue,
        'max': maxValue,
        'condition': condition.map((c) => c.toJson()).toList(),
      };
}
```

- [ ] **Step 2: Add `simRules` to `PlcProject`**

In `class PlcProject`: add the field `List<SimRule> simRules;`. Make it **optional** in the constructor so existing call sites don't break — add a named param `List<SimRule>? simRules,` and initialize with `: simRules = simRules ?? []` (combine with any existing initializer list; if there is none, add `)  : simRules = simRules ?? [];`). In `fromJson`, add `simRules: (proj['sim_rules'] as List? ?? []).map((r) => SimRule.fromJson(r)).toList(),`. In `toJson`, add `'sim_rules': simRules.map((r) => r.toJson()).toList(),`.

- [ ] **Step 3: Analyze**

Run: `flutter analyze` → **No issues found!** (additive; existing `PlcProject(...)` call sites still compile because `simRules` is optional.)

- [ ] **Step 4: Commit**

```bash
git add mobile/lib/models/project_model.dart
git commit -m "feat(sim): add SimRule/SimClause model + PlcProject.simRules"
```

---

### Task 2: Pure simulation engine + tests

**Files:**
- Create: `mobile/lib/models/sim_engine.dart`
- Test: `mobile/test/sim_engine_test.dart`

**Interfaces:**
- Consumes: `PlcProject`, `PlcTag`, `SimRule`, `SimClause` from `project_model.dart`; `readPath`/`writePath` from `tag_resolver.dart`.
- Produces (used by Task 4): `class RuleRuntime`; `class SimRuntime`; `bool evalCondition(PlcProject p, List<SimClause> clauses)`; `void applySimRules(PlcProject p, List<SimRule> rules, int dtMs, SimRuntime rt)`.

- [ ] **Step 1: Write the failing tests**

Create `mobile/test/sim_engine_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:soft_plc_mobile/models/project_model.dart';
import 'package:soft_plc_mobile/models/sim_engine.dart';

PlcTag _tag(String n, String type, dynamic v, {bool forced = false, dynamic fv}) =>
    PlcTag(name: n, path: n, dataType: type, value: v, ioType: 'Internal', isForced: forced, forcedValue: fv);

PlcProject _proj(List<PlcTag> tags, List<SimRule> rules) => PlcProject(
      id: 'p', name: 'p', controllerName: 'c',
      tags: tags, structDefs: [], programs: [], tasks: [], hmis: [], simRules: rules,
    );

SimClause _cl(String left, String cmp, String operand, {String kind = 'literal'}) =>
    SimClause(leftPath: left, comparator: cmp, operandKind: kind, operand: operand);

void main() {
  test('evalCondition: empty means always true', () {
    final p = _proj([], []);
    expect(evalCondition(p, []), isTrue);
  });

  test('evalCondition: numeric comparator + AND', () {
    final p = _proj([_tag('L', 'FLOAT64', 60.0), _tag('B', 'BOOL', true)], []);
    expect(evalCondition(p, [_cl('L', '>', '50')]), isTrue);
    expect(evalCondition(p, [_cl('L', '>', '70')]), isFalse);
    expect(evalCondition(p, [_cl('L', '>', '50'), _cl('B', '==', 'true')]), isTrue);
    expect(evalCondition(p, [_cl('L', '>', '50'), _cl('B', '==', 'false')]), isFalse);
  });

  test('evalCondition: tag operand', () {
    final p = _proj([_tag('A', 'FLOAT64', 10.0), _tag('B', 'FLOAT64', 5.0)], []);
    expect(evalCondition(p, [_cl('A', '>', 'B', kind: 'tag')]), isTrue);
    expect(evalCondition(p, [_cl('B', '>', 'A', kind: 'tag')]), isFalse);
  });

  test('setWhileCondition drives a bool from its condition', () {
    final rule = SimRule(id: 'r', name: 'sw', targetPath: 'Sw', behavior: 'setWhileCondition',
        condition: [_cl('L', '>', '50')]);
    final p = _proj([_tag('Sw', 'BOOL', false), _tag('L', 'FLOAT64', 60.0)], [rule]);
    final rt = SimRuntime();
    applySimRules(p, p.simRules, 100, rt);
    expect(p.tags.firstWhere((t) => t.name == 'Sw').value, isTrue);
    (p.tags.firstWhere((t) => t.name == 'L')).value = 40.0;
    applySimRules(p, p.simRules, 100, rt);
    expect(p.tags.firstWhere((t) => t.name == 'Sw').value, isFalse);
  });

  test('integrate accumulates rate*dt and clamps', () {
    final rule = SimRule(id: 'r', name: 'fill', targetPath: 'Lvl', behavior: 'integrate',
        ratePerSec: 10.0, minValue: 0, maxValue: 100, condition: []);
    final p = _proj([_tag('Lvl', 'FLOAT64', 0.0)], [rule]);
    final rt = SimRuntime();
    applySimRules(p, p.simRules, 1000, rt); // +10
    expect(p.tags.first.value, closeTo(10.0, 0.001));
    for (int i = 0; i < 20; i++) {
      applySimRules(p, p.simRules, 1000, rt);
    }
    expect(p.tags.first.value, equals(100.0)); // clamped
  });

  test('ramp moves toward target and stops there', () {
    final rule = SimRule(id: 'r', name: 'ramp', targetPath: 'PV', behavior: 'ramp',
        ratePerSec: 5.0, targetValue: 20.0, minValue: 0, maxValue: 100, condition: []);
    final p = _proj([_tag('PV', 'FLOAT64', 0.0)], [rule]);
    final rt = SimRuntime();
    applySimRules(p, p.simRules, 1000, rt); // +5 -> 5
    expect(p.tags.first.value, closeTo(5.0, 0.001));
    for (int i = 0; i < 10; i++) {
      applySimRules(p, p.simRules, 1000, rt);
    }
    expect(p.tags.first.value, equals(20.0)); // reaches target, no overshoot
  });

  test('pulse toggles on/off by timing while condition holds', () {
    final rule = SimRule(id: 'r', name: 'pulse', targetPath: 'Eye', behavior: 'pulse',
        onMs: 200, offMs: 300, condition: [_cl('Run', '==', 'true')]);
    final p = _proj([_tag('Eye', 'BOOL', false), _tag('Run', 'BOOL', true)], [rule]);
    final rt = SimRuntime();
    applySimRules(p, p.simRules, 100, rt); // 100ms into on-phase
    expect(p.tags.firstWhere((t) => t.name == 'Eye').value, isTrue);
    applySimRules(p, p.simRules, 100, rt); // 200ms -> flip to off
    applySimRules(p, p.simRules, 100, rt); // into off-phase
    expect(p.tags.firstWhere((t) => t.name == 'Eye').value, isFalse);
    // condition false -> forced off
    (p.tags.firstWhere((t) => t.name == 'Run')).value = false;
    applySimRules(p, p.simRules, 100, rt);
    expect(p.tags.firstWhere((t) => t.name == 'Eye').value, isFalse);
  });

  test('delayedSet fires after delayMs and resets when condition drops', () {
    final rule = SimRule(id: 'r', name: 'del', targetPath: 'Trip', behavior: 'delayedSet',
        delayMs: 300, condition: [_cl('Run', '==', 'true')]);
    final p = _proj([_tag('Trip', 'BOOL', false), _tag('Run', 'BOOL', true)], [rule]);
    final rt = SimRuntime();
    applySimRules(p, p.simRules, 200, rt); // 200 < 300
    expect(p.tags.firstWhere((t) => t.name == 'Trip').value, isFalse);
    applySimRules(p, p.simRules, 200, rt); // 400 >= 300
    expect(p.tags.firstWhere((t) => t.name == 'Trip').value, isTrue);
    (p.tags.firstWhere((t) => t.name == 'Run')).value = false;
    applySimRules(p, p.simRules, 100, rt);
    expect(p.tags.firstWhere((t) => t.name == 'Trip').value, isFalse);
  });

  test('a forced target is not overwritten', () {
    final rule = SimRule(id: 'r', name: 'i', targetPath: 'Lvl', behavior: 'integrate',
        ratePerSec: 10.0, condition: []);
    final p = _proj([_tag('Lvl', 'FLOAT64', 0.0, forced: true, fv: 42.0)], [rule]);
    final rt = SimRuntime();
    applySimRules(p, p.simRules, 1000, rt);
    expect(p.tags.first.value, equals(0.0)); // untouched (forced)
  });

  test('disabled rule does nothing', () {
    final rule = SimRule(id: 'r', name: 'i', targetPath: 'Lvl', behavior: 'integrate',
        ratePerSec: 10.0, enabled: false, condition: []);
    final p = _proj([_tag('Lvl', 'FLOAT64', 0.0)], [rule]);
    applySimRules(p, p.simRules, 1000, SimRuntime());
    expect(p.tags.first.value, equals(0.0));
  });
}
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `flutter test test/sim_engine_test.dart`
Expected: FAIL — `sim_engine.dart` does not exist.

- [ ] **Step 3: Implement `sim_engine.dart`**

Create `mobile/lib/models/sim_engine.dart`:

```dart
import 'project_model.dart';
import 'tag_resolver.dart';

/// Per-rule timing state carried across scans.
class RuleRuntime {
  int phaseMs = 0;      // pulse: elapsed within current on/off phase
  bool pulseOn = true;  // pulse: current phase is the on-phase
  int heldMs = 0;       // delayedSet: how long the condition has held
}

class SimRuntime {
  final Map<String, RuleRuntime> byRuleId = {};
  RuleRuntime _for(String id) => byRuleId.putIfAbsent(id, () => RuleRuntime());
}

double _asDouble(dynamic v) => v is num ? v.toDouble() : (v == true ? 1.0 : 0.0);

bool _compare(dynamic left, String cmp, dynamic right) {
  // Bool equality
  if (left is bool || right is bool) {
    final l = left == true;
    final r = right == true;
    if (cmp == '==') {
      return l == r;
    }
    if (cmp == '!=') {
      return l != r;
    }
    return false;
  }
  final l = _asDouble(left);
  final r = _asDouble(right);
  switch (cmp) {
    case '>':
      return l > r;
    case '<':
      return l < r;
    case '>=':
      return l >= r;
    case '<=':
      return l <= r;
    case '==':
      return l == r;
    case '!=':
      return l != r;
    default:
      return false;
  }
}

dynamic _operandValue(PlcProject p, SimClause c) {
  if (c.operandKind == 'tag') {
    return readPath(p, c.operand);
  }
  final t = c.operand.trim().toLowerCase();
  if (t == 'true') {
    return true;
  }
  if (t == 'false') {
    return false;
  }
  return double.tryParse(c.operand.trim()) ?? 0.0;
}

/// AND of all clauses; empty list is always true.
bool evalCondition(PlcProject p, List<SimClause> clauses) {
  for (final c in clauses) {
    final left = readPath(p, c.leftPath);
    if (!_compare(left, c.comparator, _operandValue(p, c))) {
      return false;
    }
  }
  return true;
}

PlcTag? _rootTagOf(PlcProject p, String path) {
  final rootName = path.split('.').first.split('[').first;
  for (final t in p.tags) {
    if (t.name == rootName) {
      return t;
    }
  }
  return null;
}

void _write(PlcProject p, String path, dynamic value) {
  final root = _rootTagOf(p, path);
  if (root != null && root.isForced && root.name == path) {
    return; // forcing wins
  }
  writePath(p, path, value);
}

double _clamp(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);

void applySimRules(PlcProject p, List<SimRule> rules, int dtMs, SimRuntime rt) {
  final dt = dtMs / 1000.0;
  for (final rule in rules) {
    if (!rule.enabled) {
      continue;
    }
    final cond = evalCondition(p, rule.condition);
    final st = rt._for(rule.id);
    switch (rule.behavior) {
      case 'setWhileCondition':
        _write(p, rule.targetPath, cond);
        break;
      case 'delayedSet':
        if (cond) {
          st.heldMs += dtMs;
          _write(p, rule.targetPath, st.heldMs >= rule.delayMs);
        } else {
          st.heldMs = 0;
          _write(p, rule.targetPath, false);
        }
        break;
      case 'pulse':
        if (!cond) {
          st.phaseMs = 0;
          st.pulseOn = true;
          _write(p, rule.targetPath, false);
          break;
        }
        st.phaseMs += dtMs;
        final limit = st.pulseOn ? rule.onMs : rule.offMs;
        if (st.phaseMs >= limit && limit > 0) {
          st.pulseOn = !st.pulseOn;
          st.phaseMs = 0;
        }
        _write(p, rule.targetPath, st.pulseOn);
        break;
      case 'ramp':
        if (cond) {
          final cur = _asDouble(readPath(p, rule.targetPath));
          final step = rule.ratePerSec * dt;
          double next;
          if (cur < rule.targetValue) {
            next = (cur + step).clamp(cur, rule.targetValue).toDouble();
          } else {
            next = (cur - step).clamp(rule.targetValue, cur).toDouble();
          }
          _write(p, rule.targetPath, _clamp(next, rule.minValue, rule.maxValue));
        }
        break;
      case 'integrate':
        if (cond) {
          final cur = _asDouble(readPath(p, rule.targetPath));
          _write(p, rule.targetPath, _clamp(cur + rule.ratePerSec * dt, rule.minValue, rule.maxValue));
        }
        break;
      default:
        break;
    }
  }
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `flutter test test/sim_engine_test.dart`
Expected: PASS (10 tests).

- [ ] **Step 5: Analyze and commit**

Run: `flutter analyze` → **No issues found!**

```bash
git add mobile/lib/models/sim_engine.dart mobile/test/sim_engine_test.dart
git commit -m "feat(sim): pure simulation engine (pulse/ramp/integrate/delayedSet/setWhileCondition)"
```

---

### Task 3: Simulated I/O editor screen + sidebar entry

**Files:**
- Create: `mobile/lib/screens/simulated_io_screen.dart`
- Modify: `mobile/lib/screens/workspace_shell.dart` (sidebar entry + center-pane dispatch)

**Interfaces:**
- Consumes: `SimRule`, `SimClause`, `PlcProject` from `project_model.dart`; `leafAndNodePaths` from `tag_resolver.dart`.
- Produces: `SimulatedIoScreen({required PlcProject currentProject, required VoidCallback onProjectUpdated})`; nav id `'SIMIO:rules'`.

- [ ] **Step 1: Create the screen**

Create `mobile/lib/screens/simulated_io_screen.dart`:

```dart
import 'package:flutter/material.dart';
import '../models/project_model.dart';
import '../models/tag_resolver.dart';

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
];
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

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDlg) {
          final numeric = working.behavior == 'ramp' || working.behavior == 'integrate';
          return AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            title: Text(isNew ? 'Add Simulated Input' : 'Edit Simulated Input'),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
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
                    DropdownButtonFormField<String>(
                      initialValue: paths.contains(working.targetPath) ? working.targetPath : (paths.isNotEmpty ? paths.first : null),
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Target tag'),
                      items: paths.map((p) => DropdownMenuItem(value: p, child: Text(p, overflow: TextOverflow.ellipsis))).toList(),
                      onChanged: (v) => setDlg(() => working.targetPath = v ?? working.targetPath),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: working.behavior,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Behaviour'),
                      items: _behaviors.map((b) => DropdownMenuItem(value: b, child: Text(b))).toList(),
                      onChanged: (v) => setDlg(() => working.behavior = v ?? working.behavior),
                    ),
                    const SizedBox(height: 8),
                    ..._behaviorParams(working, numeric, setDlg),
                    const Divider(color: Colors.white24),
                    const Text('Condition (AND — empty = Always)', style: TextStyle(fontSize: 11, color: Colors.amberAccent)),
                    ..._conditionRows(working, paths, setDlg),
                    TextButton.icon(
                      icon: const Icon(Icons.add, size: 14),
                      label: const Text('Add condition clause'),
                      onPressed: () => setDlg(() => working.condition.add(SimClause(leftPath: paths.isNotEmpty ? paths.first : ''))),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
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
                  Navigator.pop(ctx);
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _behaviorParams(SimRule r, bool numeric, StateSetter setDlg) {
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

  List<Widget> _conditionRows(SimRule r, List<String> paths, StateSetter setDlg) {
    return r.condition.asMap().entries.map((e) {
      final c = e.value;
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(children: [
          Expanded(
            flex: 3,
            child: DropdownButtonFormField<String>(
              initialValue: paths.contains(c.leftPath) ? c.leftPath : (paths.isNotEmpty ? paths.first : null),
              isExpanded: true,
              decoration: const InputDecoration(isDense: true),
              items: paths.map((p) => DropdownMenuItem(value: p, child: Text(p, overflow: TextOverflow.ellipsis))).toList(),
              onChanged: (v) => setDlg(() => c.leftPath = v ?? c.leftPath),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            flex: 2,
            child: DropdownButtonFormField<String>(
              initialValue: c.comparator,
              isExpanded: true,
              decoration: const InputDecoration(isDense: true),
              items: _comparators.map((o) => DropdownMenuItem(value: o, child: Text(o))).toList(),
              onChanged: (v) => setDlg(() => c.comparator = v ?? c.comparator),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            flex: 2,
            child: TextFormField(
              initialValue: c.operand,
              decoration: const InputDecoration(isDense: true, hintText: 'value'),
              onChanged: (v) => c.operand = v,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16, color: Colors.redAccent),
            onPressed: () => setDlg(() => r.condition.removeAt(e.key)),
          ),
        ]),
      );
    }).toList();
  }
}
```

Note: `Switch(activeThumbColor:)` is the current Flutter API; if the installed Flutter flags it, use `activeColor:` — pick whichever keeps `flutter analyze` clean.

- [ ] **Step 2: Add the sidebar entry + center-pane dispatch in `workspace_shell.dart`**

Add the import: `import 'simulated_io_screen.dart';`.

In the left dock, near the `MEMORY` entry, add a tappable "Simulated I/O" tile that sets `_activeViewId = 'SIMIO:rules'` (mirror the existing MEMORY tile's widget/onTap/selected-highlight structure; label it `SIMULATED I/O`, use `Icons.sensors` or similar, show a count `(${_activeProject.simRules.length})`).

In `_buildCenterWorkspace`, add before the final fallback:

```dart
    } else if (_activeViewId == 'SIMIO:rules') {
      return SimulatedIoScreen(
        currentProject: _activeProject,
        onProjectUpdated: () => setState(() {}),
      );
```

- [ ] **Step 3: Analyze, build**

Run: `flutter analyze` → **No issues found!**
Run: `flutter build web --release` → succeeds.

(Controller does Chrome validation; do not attempt preview here.)

- [ ] **Step 4: Commit**

```bash
git add mobile/lib/screens/simulated_io_screen.dart mobile/lib/screens/workspace_shell.dart
git commit -m "feat(sim): Simulated I/O editor screen + sidebar entry"
```

---

### Task 4: Wire the engine into the scan + migrate hardcoded input sim

**Files:**
- Modify: `mobile/lib/screens/workspace_shell.dart` (run engine; remove migrated input-sim lines)
- Modify: `mobile/lib/data/default_projects.dart` (default `SimRule`s per project)

**Interfaces:**
- Consumes: `applySimRules`, `SimRuntime` from `sim_engine.dart`; `SimRule`, `SimClause` from `project_model.dart`.

- [ ] **Step 1: Run the engine each scan**

In `workspace_shell.dart`: add `import '../models/sim_engine.dart';`. Add a field `final SimRuntime _simRuntime = SimRuntime();`. In `_executeScan()`, immediately before the `_evaluateActiveLogic();` call, add:

```dart
      applySimRules(_activeProject, _activeProject.simRules, scanSpeedMs, _simRuntime);
```

Where the active project is switched (the method that sets `_activeProject` to a new project), clear runtime state: `_simRuntime.byRuleId.clear();`.

- [ ] **Step 2: Remove the migrated input-simulation writes from `_evaluateActiveLogic`**

Delete ONLY the input-simulation writes (leave every control-logic write intact):
- `proj_tank`: the `Level_PV` ramp lines (the `pv += ...`/`pv -= ...` and the `_setTagDouble('Level_PV', ...)` that follows the ramp — NOT the alarms/valves).
- `proj_st_reactor`: the `Temp_PV` accumulation lines + its `_setTagDouble('Temp_PV', ...)`.
- `proj_ld_conveyor`: the `Photo_Eye` and `Part_Present` `_setTagBool` lines driven by `scanCount`.
- `proj_fbd_hvac`: the `Room_Temp` accumulation + `_setTagDouble('Room_Temp', ...)`.
- `proj_sfc_filling`: the `Fill_Level` accumulation line.
- `proj_all_water`: the `Turbidity_PV`, `Level_PV`, `Flow_PV` process-value writes (leave pump/backwash/dosing/alarm control writes).

Read each block carefully; a write is *input simulation* only if it drives a `SimulatedInput`/process-value tag from time or from an output (not if it computes an output/coil/alarm from inputs).

- [ ] **Step 3: Add default `SimRule`s reproducing those behaviors**

In `default_projects.dart`, give each affected project a `simRules: [...]` list. Convert per-scan deltas to per-second rates using the 500 ms default (`ratePerSec = deltaPerScan * 2`). Concrete values:

- `_tankProject` → `simRules`:
```dart
      simRules: [
        SimRule(id: 'sim0', name: 'Tank fills while filling', targetPath: 'Level_PV',
            behavior: 'integrate', ratePerSec: 1.0, minValue: 0, maxValue: 100,
            condition: [SimClause(leftPath: 'Fill_Valve', comparator: '==', operand: 'true')]),
        SimRule(id: 'sim1', name: 'Tank drains while draining', targetPath: 'Level_PV',
            behavior: 'integrate', ratePerSec: -1.0, minValue: 0, maxValue: 100,
            condition: [SimClause(leftPath: 'Drain_Valve', comparator: '==', operand: 'true')]),
      ],
```
- `_stReactorProject` → `simRules`:
```dart
      simRules: [
        SimRule(id: 'sim0', name: 'Heating raises temp', targetPath: 'Temp_PV',
            behavior: 'integrate', ratePerSec: 0.6, minValue: 0, maxValue: 105,
            condition: [SimClause(leftPath: 'Heat_Cmd', comparator: '==', operand: 'true')]),
        SimRule(id: 'sim1', name: 'Cooling lowers temp', targetPath: 'Temp_PV',
            behavior: 'integrate', ratePerSec: -0.4, minValue: 0, maxValue: 105,
            condition: [SimClause(leftPath: 'Cool_Cmd', comparator: '==', operand: 'true')]),
        SimRule(id: 'sim2', name: 'Ambient heat loss', targetPath: 'Temp_PV',
            behavior: 'integrate', ratePerSec: -0.04, minValue: 0, maxValue: 105, condition: []),
      ],
```
- `_ldConveyorProject` → `simRules`:
```dart
      simRules: [
        SimRule(id: 'sim0', name: 'Photo eye blips while belt runs', targetPath: 'Photo_Eye',
            behavior: 'pulse', onMs: 2000, offMs: 9000,
            condition: [SimClause(leftPath: 'Belt_Motor', comparator: '==', operand: 'true')]),
        SimRule(id: 'sim1', name: 'Part present follows photo eye', targetPath: 'Part_Present',
            behavior: 'setWhileCondition',
            condition: [SimClause(leftPath: 'Photo_Eye', comparator: '==', operand: 'true')]),
      ],
```
- `_fbdHvacProject` → `simRules`:
```dart
      simRules: [
        SimRule(id: 'sim0', name: 'Heating warms room', targetPath: 'Room_Temp',
            behavior: 'integrate', ratePerSec: 0.16, minValue: 0, maxValue: 40,
            condition: [SimClause(leftPath: 'Heat_Cmd', comparator: '==', operand: 'true')]),
        SimRule(id: 'sim1', name: 'Cooling cools room', targetPath: 'Room_Temp',
            behavior: 'integrate', ratePerSec: -0.16, minValue: 0, maxValue: 40,
            condition: [SimClause(leftPath: 'Cool_Cmd', comparator: '==', operand: 'true')]),
        SimRule(id: 'sim2', name: 'Ambient drift', targetPath: 'Room_Temp',
            behavior: 'integrate', ratePerSec: -0.02, minValue: 0, maxValue: 40, condition: []),
      ],
```
- `_sfcFillingProject` → `simRules`:
```dart
      simRules: [
        SimRule(id: 'sim0', name: 'Bottle fills while valve open', targetPath: 'Fill_Level',
            behavior: 'integrate', ratePerSec: 8.0, minValue: 0, maxValue: 100,
            condition: [SimClause(leftPath: 'Fill_Valve', comparator: '==', operand: 'true')]),
      ],
```
- `_allWaterProject` → `simRules` (match the removed process-value physics; use the same gating tags the removed code used — e.g. turbidity falls while `Treat_Dosing`, level rises while `Pump_Motor`, flow follows `Pump_Motor`):
```dart
      simRules: [
        SimRule(id: 'sim0', name: 'Dosing clears turbidity', targetPath: 'Turbidity_PV',
            behavior: 'integrate', ratePerSec: -0.24, minValue: 0, maxValue: 20,
            condition: [SimClause(leftPath: 'Treat_Dosing', comparator: '==', operand: 'true')]),
        SimRule(id: 'sim1', name: 'Turbidity creeps up', targetPath: 'Turbidity_PV',
            behavior: 'integrate', ratePerSec: 0.06, minValue: 0, maxValue: 20, condition: []),
        SimRule(id: 'sim2', name: 'Level rises while pumping', targetPath: 'Level_PV',
            behavior: 'integrate', ratePerSec: 1.0, minValue: 0, maxValue: 100,
            condition: [SimClause(leftPath: 'Pump_Motor', comparator: '==', operand: 'true')]),
        SimRule(id: 'sim3', name: 'Flow while pumping', targetPath: 'Flow_PV',
            behavior: 'ramp', ratePerSec: 40.0, targetValue: 120.0, minValue: 0, maxValue: 150,
            condition: [SimClause(leftPath: 'Pump_Motor', comparator: '==', operand: 'true')]),
      ],
```

If the removed `proj_all_water` physics used different gating tags or ranges than assumed here, mirror the ORIGINAL behavior (adjust the rule's condition/rate/clamp accordingly) — the goal is behavior parity at the 500 ms default scan.

- [ ] **Step 4: Analyze, test, build**

Run: `flutter analyze` → **No issues found!**
Run: `flutter test` → all pass.
Run: `flutter build web --release` → succeeds.

- [ ] **Step 5: Commit**

```bash
git add mobile/lib/screens/workspace_shell.dart mobile/lib/data/default_projects.dart
git commit -m "feat(sim): run engine each scan; migrate hardcoded input physics to default rules"
```

---

### Task 5: Final validation

**Files:** none (verification; small fixes only if a regression surfaces).

- [ ] **Step 1: Full suite + analyze + build**

Run: `flutter test` → all pass (sim_engine, tag_resolver, ld_graph, ld_layout, widget tests).
Run: `flutter analyze` → **No issues found!**
Run: `flutter build web --release` → succeeds.

- [ ] **Step 2: Chrome walkthrough (controller)**

- Open the "LD — Conveyor Belt Control" project, start the scan, and confirm `Photo_Eye` still pulses (now via the migrated rule) only while the belt runs.
- Open the ST reactor and confirm `Temp_PV` still ramps toward setpoint under heat/cool.
- Open the **Simulated I/O** screen: the migrated rules are listed; add a new rule (target + behavior + condition), save, and watch it drive the tag; toggle a rule off and confirm it stops; **force** the target tag in the inspector and confirm the rule yields.

- [ ] **Step 3: Branding sweep**

Run: `grep -ri "openplc" mobile/lib mobile/test` → no matches.

- [ ] **Step 4: Commit (only if fixes were made)**

```bash
git add -A
git commit -m "test(sim): validate simulated I/O across projects"
```

---

## Self-review notes

- **Spec coverage:** model (Task 1) ✓; engine with 5 behaviors + condition eval + forcing (Task 2) ✓; editor screen with target picker/behavior params/condition builder + sidebar entry (Task 3) ✓; scan integration + migrate hardcoded input sim to default rules (Task 4) ✓; validation incl. force-yields and per-project parity (Task 5) ✓.
- **Type consistency:** `SimRule`/`SimClause` fields, `evalCondition`/`applySimRules`/`SimRuntime`/`RuleRuntime`, behavior strings (`setWhileCondition`/`delayedSet`/`pulse`/`ramp`/`integrate`), and comparator strings are identical across tasks.
- **Green-after-every-task:** Tasks 1-3 additive; Task 4 swaps the input-sim source (engine replaces the deleted lines in the same commit) so behavior is preserved; Task 5 verifies.
- **Deferred (per spec):** OR conditions; LD/FBD/SFC execution; disk persistence.
