import '../models/project_model.dart';
import 'import_ir.dart';

/// Result of translating one SFC `SfcBody`. `translated == false` tells the
/// mapper to keep today's whole-POU stub; `stubReason` is the `sfcStubReasons`
/// key. SFC is whole-POU faithful-or-stub for structure + conditions; an
/// unrepresentable step action degrades to a no-op + warning (chart still
/// translates). Pure, deterministic, never-throws.
class SfcTranslation {
  final List<SfcStep> steps;
  final List<SfcTransition> transitions;
  final bool translated;
  final String? stubReason;
  final List<ImportWarning> warnings;
  SfcTranslation({required this.steps, required this.transitions,
      required this.translated, required this.stubReason, required this.warnings});
}

/// Internal whole-POU bail-out. Always caught inside [translateSfcBody].
class _SfcStub implements Exception {
  final String reason;
  final String detail;
  _SfcStub(this.reason, this.detail);
}

SfcTranslation translateSfcBody(SfcBody body, {required String pouName}) {
  final warnings = <ImportWarning>[];
  try {
    final built = _build(body, pouName, warnings);
    return SfcTranslation(steps: built.$1, transitions: built.$2,
        translated: true, stubReason: null, warnings: warnings);
  } on _SfcStub catch (e) {
    warnings.add(ImportWarning(severity: WarningSeverity.warning,
        message: 'SFC POU "$pouName": not translated (${e.detail}).'));
    return SfcTranslation(steps: const [], transitions: const [],
        translated: false, stubReason: e.reason, warnings: warnings);
  }
}

(List<SfcStep>, List<SfcTransition>) _build(
    SfcBody body, String pouName, List<ImportWarning> warnings) {
  final stepNodes = [for (final n in body.nodes) if (n.kind == SfcNodeKind.step) n];
  if (stepNodes.isEmpty) throw _SfcStub('no-initial', 'chart has no steps');

  final byId = {for (final n in body.nodes) n.localId: n};

  // A direct step->step edge means a transition is missing from the source
  // — a structural error, not something we can represent faithfully as a
  // partial chart. Whole-POU stub rather than silently drop the path.
  //
  // Import builders (l5x_parser's SFC poison node) depend on this scan
  // preceding every warning emission below — see
  // docs/superpowers/specs/2026-08-07-l5x-sfc-import-design.md §4.
  for (final e in body.edges) {
    if (byId[e.fromLocalId]?.kind == SfcNodeKind.step &&
        byId[e.toLocalId]?.kind == SfcNodeKind.step) {
      throw _SfcStub('complex-topology', 'step directly wired to step (missing transition)');
    }
  }

  final succ = <int, List<int>>{for (final n in body.nodes) n.localId: []};
  final pred = <int, List<int>>{for (final n in body.nodes) n.localId: []};
  for (final e in body.edges) {
    succ[e.fromLocalId]?.add(e.toLocalId);
    pred[e.toLocalId]?.add(e.fromLocalId);
  }

  String stepId(int localId) => '${pouName}_s$localId';
  SfcNode? stepByName(String name) {
    for (final n in stepNodes) {
      if (n.name == name) return n;
    }
    return null;
  }

  // Actions grouped by step. An action whose stepLocalId does not resolve to
  // a real step (dangling reference, typo'd id, or association with a
  // transition/connector) is unassociatable: it degrades to no-op, but must
  // still surface a warning rather than silently vanish.
  final stepLocalIds = {for (final s in stepNodes) s.localId};
  final actionsByStep = <int, List<SfcActionAssoc>>{};
  for (final a in body.actions) {
    if (!stepLocalIds.contains(a.stepLocalId)) {
      warnings.add(ImportWarning(severity: WarningSeverity.info,
          message: 'SFC POU "$pouName": action associated with unknown step '
              '(id ${a.stepLocalId}) — skipped.'));
      continue;
    }
    (actionsByStep[a.stepLocalId] ??= []).add(a);
  }

  // Steps.
  final steps = <SfcStep>[];
  var anyInitial = false;
  for (final s in stepNodes) {
    if (s.initial) anyInitial = true;
    steps.add(SfcStep(
      id: stepId(s.localId),
      name: s.name.isEmpty ? 's${s.localId}' : s.name,
      isInitial: s.initial,
      actionSt: _actionSt(actionsByStep[s.localId] ?? const [], body,
          s.name.isEmpty ? 's${s.localId}' : s.name, warnings),
    ));
  }
  if (!anyInitial) {
    warnings.add(ImportWarning(severity: WarningSeverity.info,
        message: 'SFC POU "$pouName": no initial step marked — first step used.'));
    steps.first.isInitial = true;
  }

  // Upstream/downstream step resolution across transparent connectors.
  // step, selDiv (→ its single step source), selConv (→ its single step
  // target), jump (→ named step), simConv (→ its branch-tail steps, upstream),
  // simDiv (→ its branch-head steps, downstream).
  List<int> upstreamSteps(int transId) {
    final out = <int>[];
    for (final p in pred[transId] ?? const []) {
      final node = byId[p];
      if (node == null) throw _SfcStub('complex-topology', 'dangling edge');
      switch (node.kind) {
        case SfcNodeKind.step:
          out.add(p);
          break;
        case SfcNodeKind.selDiv:
          for (final pp in pred[p] ?? const []) {
            if (byId[pp]?.kind != SfcNodeKind.step) {
              throw _SfcStub('complex-topology', 'selDiv upstream not a step');
            }
            out.add(pp);
          }
          break;
        case SfcNodeKind.simConv:
          for (final pp in pred[p] ?? const []) {
            if (byId[pp]?.kind != SfcNodeKind.step) {
              throw _SfcStub('complex-topology', 'simConv upstream not a step');
            }
            out.add(pp);
          }
          break;
        default:
          throw _SfcStub('complex-topology', 'unsupported transition source');
      }
    }
    return out;
  }

  List<int> downstreamSteps(int transId) {
    final out = <int>[];
    for (final s in succ[transId] ?? const []) {
      final node = byId[s];
      if (node == null) throw _SfcStub('complex-topology', 'dangling edge');
      switch (node.kind) {
        case SfcNodeKind.step:
          out.add(s);
          break;
        case SfcNodeKind.selConv:
          for (final ss in succ[s] ?? const []) {
            if (byId[ss]?.kind != SfcNodeKind.step) {
              throw _SfcStub('complex-topology', 'selConv downstream not a step');
            }
            out.add(ss);
          }
          break;
        case SfcNodeKind.jump:
          final target = stepByName(node.name);
          if (target == null) {
            throw _SfcStub('complex-topology', 'jump to unknown step "${node.name}"');
          }
          out.add(target.localId);
          break;
        case SfcNodeKind.simDiv:
          for (final ss in succ[s] ?? const []) {
            if (byId[ss]?.kind != SfcNodeKind.step) {
              throw _SfcStub('complex-topology', 'simDiv downstream not a step');
            }
            out.add(ss);
          }
          break;
        default:
          throw _SfcStub('complex-topology', 'unsupported transition target');
      }
    }
    return out;
  }

  // Transitions.
  final transitions = <SfcTransition>[];
  for (final t in body.nodes) {
    if (t.kind != SfcNodeKind.transition) continue;
    final cond = _conditionSt(t.condition, body);
    final src = upstreamSteps(t.localId);
    final tgt = downstreamSteps(t.localId);
    if (src.length == 1 && tgt.length == 1) {
      transitions.add(SfcTransition(
        id: '${pouName}_t${t.localId}',
        fromStepId: stepId(src.first),
        toStepId: stepId(tgt.first),
        conditionSt: cond,
        kind: 'single',
      ));
    } else if (src.length == 1 && tgt.length > 1) {
      transitions.add(SfcTransition(
        id: '${pouName}_t${t.localId}',
        fromStepId: stepId(src.first),
        toStepId: '',
        conditionSt: cond,
        kind: 'parallelFork',
        toStepIds: [for (final s in tgt) stepId(s)],
      ));
    } else if (src.length > 1 && tgt.length == 1) {
      transitions.add(SfcTransition(
        id: '${pouName}_t${t.localId}',
        fromStepId: '',
        toStepId: stepId(tgt.first),
        conditionSt: cond,
        kind: 'parallelJoin',
        fromStepIds: [for (final s in src) stepId(s)],
      ));
    } else {
      throw _SfcStub('complex-topology', 'unsupported transition fan-in/out');
    }
  }

  return (steps, transitions);
}

/// Resolves a transition's condition to ST, or bails the whole POU.
String _conditionSt(SfcCond? cond, SfcBody body) {
  switch (cond) {
    case SfcCondInline c:
      return c.text;
    case SfcCondRef c:
      final b = body.refBodies[c.name];
      if (b == null || body.graphicalRefs.contains(c.name)) {
        throw _SfcStub('unresolved-condition', 'transition references "${c.name}"');
      }
      return b;
    case SfcCondWired _:
      throw _SfcStub('wired-condition', 'graphical transition condition');
    case SfcCondNone _:
    case null:
      throw _SfcStub('unresolved-condition', 'transition has no condition');
  }
}

/// Resolves a step's N-qualified actions to concatenated ST; non-N and
/// unresolved actions degrade to no-op + warning.
String _actionSt(List<SfcActionAssoc> actions, SfcBody body, String stepName,
    List<ImportWarning> warnings) {
  final parts = <String>[];
  for (final a in actions) {
    if (a.qualifier.toUpperCase() != 'N') {
      warnings.add(ImportWarning(severity: WarningSeverity.info,
          message: 'SFC step "$stepName": action qualifier "${a.qualifier}" '
              'unsupported — action skipped (N only).'));
      continue;
    }
    switch (a.source) {
      case SfcActInline s:
        if (s.text.isNotEmpty) parts.add(s.text);
        break;
      case SfcActRef s:
        final b = body.refBodies[s.name];
        if (b == null || body.graphicalRefs.contains(s.name)) {
          warnings.add(ImportWarning(severity: WarningSeverity.info,
              message: 'SFC step "$stepName": action "${s.name}" not resolvable '
                  'to ST — skipped.'));
        } else if (b.isNotEmpty) {
          parts.add(b);
        }
        break;
    }
  }
  return parts.join('\n');
}
