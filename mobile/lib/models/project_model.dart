import 'dart:convert';

import '../services/tag_historian.dart';
import 'opcua_map.dart';
import 'protocol_settings.dart';
import 'signal_gen.dart';
import 'tag_resolver.dart';

/// HMI component type id for the multi-pen trend chart.
const String kTrendChartDisplay = 'TrendChartDisplay';

/// Hard cap on the number of FBD network headers a program will ever
/// backfill to. Project JSON is untrusted input (loaded from disk/import);
/// a corrupt or hand-edited block with e.g. `"network": 1000000000` must
/// never drive an unbounded `while (result.length < needed)` allocation
/// loop (OOM/hang on load). No legitimate FBD program has anywhere near
/// this many networks, so the cap never affects real data.
const int kMaxFbdNetworks = 4096;

class PlcTag {
  String name;
  String path;
  String dataType; // 'BOOL', 'INT16', 'INT32', 'FLOAT64', 'STRING', 'TIMER'
  int arrayLength;
  dynamic value;
  String quality;
  String access;
  bool retentive;
  String description;
  String engineeringUnits;
  String ioType; // 'SimulatedInput', 'SimulatedOutput', 'Internal'
  bool isForced;
  dynamic forcedValue;
  String folder;
  dynamic defaultValue;

  PlcTag({
    required this.name,
    required this.path,
    required this.dataType,
    this.arrayLength = 0,
    required this.value,
    this.quality = 'Good',
    this.access = 'ReadWrite',
    this.retentive = false,
    this.description = '',
    this.engineeringUnits = '',
    required this.ioType,
    this.isForced = false,
    this.forcedValue,
    this.folder = '',
    this.defaultValue,
  });

  factory PlcTag.fromJson(Map<String, dynamic> json) {
    return PlcTag(
      name: json['name'] ?? '',
      path: json['path'] ?? '',
      dataType: json['data_type'] ?? 'BOOL',
      arrayLength: json['array_length'] ?? 0,
      value: json['initial_value'] ?? json['value'] ?? false,
      quality: json['quality'] ?? 'Good',
      access: json['access'] ?? 'ReadWrite',
      retentive: json['retentive'] ?? false,
      description: json['description'] ?? '',
      engineeringUnits: json['engineering_units'] ?? '',
      ioType: json['io_type'] ?? 'Internal',
      isForced: json['is_forced'] ?? false,
      forcedValue: json['forced_value'],
      folder: json['folder'] ?? '',
      // A key present (even with a null value) means this JSON was already
      // written by the current toJson — trust it as-is so a defaultValue
      // left unset (null) stays null across an encode/decode round-trip.
      // Only truly legacy JSON (no key at all, pre-dating this field) adopts
      // initial_value/value as its default.
      defaultValue: json.containsKey('default_value')
          ? json['default_value']
          : (json['initial_value'] ?? json['value']),
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'path': path,
    'data_type': dataType,
    'array_length': arrayLength,
    'initial_value': value,
    'quality': quality,
    'access': access,
    'retentive': retentive,
    'description': description,
    'engineering_units': engineeringUnits,
    'io_type': ioType,
    'is_forced': isForced,
    'forced_value': forcedValue,
    'default_value': defaultValue,
    'folder': folder,
  };

  /// The declared default when set, else the built-in default for this tag's
  /// type/shape. Callers use this instead of special-casing a null
  /// [defaultValue] (only the project is needed, to resolve a composite's
  /// structural default).
  dynamic effectiveDefault(PlcProject p) =>
      defaultValue ?? defaultValueFor(p, dataType, arrayLength);
}

class StructFieldDef {
  String name;
  String dataType;
  int arrayLength;
  dynamic defaultValue;

  StructFieldDef({
    required this.name,
    required this.dataType,
    this.arrayLength = 0,
    required this.defaultValue,
  });

  factory StructFieldDef.fromJson(Map<String, dynamic> json) {
    return StructFieldDef(
      name: json['name'] ?? '',
      dataType: json['data_type'] ?? 'BOOL',
      arrayLength: json['array_length'] ?? 0,
      defaultValue: json['default_value'],
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'data_type': dataType,
    'array_length': arrayLength,
    'default_value': defaultValue,
  };
}

class PlcStructDef {
  String name;
  List<StructFieldDef> fields;

  PlcStructDef({
    required this.name,
    required this.fields,
  });

  factory PlcStructDef.fromJson(Map<String, dynamic> json) {
    return PlcStructDef(
      name: json['name'] ?? '',
      fields: (json['fields'] as List? ?? [])
          .map((f) => StructFieldDef.fromJson(f))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'fields': fields.map((f) => f.toJson()).toList(),
  };
}

// -------------------------------------------------------------
// LADDER LOGIC (LD) — node-and-wire graph model
// -------------------------------------------------------------
enum LdKind { leftRail, rightRail, contact, coil, block, link }

class LdNode {
  String id;
  LdKind kind;
  String variable;   // bound tag (contact/coil); '' for rails/blocks
  String modifier;   // 'normal'|'negated'|'rising'|'falling'|'set'|'reset'
  String blockType;  // 'TON'|'TOF'|'CTU'|... when kind == LdKind.block
  int presetMs;      // block preset time (TON/TOF)
  String comment;
  int col;           // grid column (series index) — assigned by layout
  int row;           // grid lane (0 = main line)
  String operandA;   // first data operand (e.g. compare/move block LHS)
  String operandB;   // second data operand (e.g. compare/move block RHS)

  LdNode({
    required this.id,
    required this.kind,
    this.variable = '',
    this.modifier = 'normal',
    this.blockType = '',
    this.presetMs = 5000,
    this.comment = '',
    this.col = 0,
    this.row = 0,
    this.operandA = '',
    this.operandB = '',
  });

  factory LdNode.fromJson(Map<String, dynamic> json) {
    return LdNode(
      id: json['id'] ?? '',
      kind: LdKind.values.firstWhere(
        (e) => e.name == json['kind'],
        orElse: () => LdKind.contact,
      ),
      variable: json['variable'] ?? '',
      modifier: json['modifier'] ?? 'normal',
      blockType: json['block_type'] ?? '',
      presetMs: json['preset_ms'] ?? 5000,
      comment: json['comment'] ?? '',
      col: json['col'] ?? 0,
      row: json['row'] ?? 0,
      operandA: json['operand_a'] ?? '',
      operandB: json['operand_b'] ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'id': id, 'kind': kind.name, 'variable': variable, 'modifier': modifier,
      'block_type': blockType, 'preset_ms': presetMs, 'comment': comment, 'col': col, 'row': row,
    };
    if (operandA.isNotEmpty) m['operand_a'] = operandA;
    if (operandB.isNotEmpty) m['operand_b'] = operandB;
    return m;
  }
}

class LdWire {
  String fromId;
  String fromPort;
  String toId;
  String toPort;

  LdWire({
    required this.fromId,
    this.fromPort = 'out',
    required this.toId,
    this.toPort = 'in',
  });

  factory LdWire.fromJson(Map<String, dynamic> json) {
    return LdWire(
      fromId: json['from_id'] ?? '',
      fromPort: json['from_port'] ?? 'out',
      toId: json['to_id'] ?? '',
      toPort: json['to_port'] ?? 'in',
    );
  }

  Map<String, dynamic> toJson() => {
    'from_id': fromId,
    'from_port': fromPort,
    'to_id': toId,
    'to_port': toPort,
  };
}

class LdRung {
  int rungIndex;
  String comment;
  List<LdNode> nodes;
  List<LdWire> wires;

  LdRung({
    required this.rungIndex,
    this.comment = '',
    required this.nodes,
    required this.wires,
  });

  factory LdRung.fromJson(Map<String, dynamic> json) {
    return LdRung(
      rungIndex: json['rung_index'] ?? 0,
      comment: json['comment'] ?? '',
      nodes: (json['nodes'] as List? ?? []).map((n) => LdNode.fromJson(n)).toList(),
      wires: (json['wires'] as List? ?? []).map((w) => LdWire.fromJson(w)).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'rung_index': rungIndex,
    'comment': comment,
    'nodes': nodes.map((n) => n.toJson()).toList(),
    'wires': wires.map((w) => w.toJson()).toList(),
  };
}

// -------------------------------------------------------------
// FUNCTION BLOCK DIAGRAM (FBD) MODELS
// -------------------------------------------------------------
class FbdBlock {
  String id;
  String type; // e.g. 'AND','OR','NOT','ADD','SUB','MUL','DIV', comparators, 'LIMIT','SEL','TON','TOF','PID','CTU','CTD','CTUD','R_TRIG','F_TRIG','TP','CONST','TAG_INPUT','TAG_OUTPUT'
  String title;
  String tagBinding;
  double x;
  double y;
  int inputCount; // extensible AND/OR/ADD/MUL input count (default 2); ignored otherwise
  int network; // index into the owning PlcProgram.fbdNetworks list (default 0)

  FbdBlock({
    required this.id,
    required this.type,
    required this.title,
    this.tagBinding = '',
    this.x = 100,
    this.y = 100,
    this.inputCount = 2,
    this.network = 0,
  });

  factory FbdBlock.fromJson(Map<String, dynamic> json) {
    return FbdBlock(
      id: json['id'] ?? '',
      type: json['type'] ?? '',
      title: json['title'] ?? '',
      tagBinding: json['tag_binding'] ?? '',
      x: (json['x'] as num?)?.toDouble() ?? 100,
      y: (json['y'] as num?)?.toDouble() ?? 100,
      inputCount: json['input_count'] ?? 2,
      network: json['network'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'title': title,
    'tag_binding': tagBinding,
    'x': x,
    'y': y,
    'input_count': inputCount,
    'network': network,
  };
}

class FbdWire {
  String fromBlockId;
  String fromPin;
  String toBlockId;
  String toPin;

  FbdWire({
    required this.fromBlockId,
    this.fromPin = '',
    required this.toBlockId,
    this.toPin = '',
  });

  /// Legacy JSON (no `from_pin`/`to_pin`) is read with empty pin fields; a
  /// wire with an empty `fromPin`/`toPin` is resolved by callers (see
  /// `fbd_exec.dart`) as the source's first output pin / target's first
  /// input pin, per the block-type pin registry (`fbd_pins.dart`). This
  /// model file intentionally has no dependency on that registry.
  factory FbdWire.fromJson(Map<String, dynamic> json) {
    return FbdWire(
      fromBlockId: json['from_block_id'] ?? '',
      fromPin: json['from_pin'] ?? '',
      toBlockId: json['to_block_id'] ?? '',
      toPin: json['to_pin'] ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'from_block_id': fromBlockId,
    'from_pin': fromPin,
    'to_block_id': toBlockId,
    'to_pin': toPin,
  };
}

/// Header/metadata for one FBD network (a horizontal rung-like grouping of
/// blocks). `FbdBlock.network` indexes into the owning `PlcProgram.fbdNetworks`.
class FbdNetwork {
  String comment;
  FbdNetwork({this.comment = ''});
  factory FbdNetwork.fromJson(Map<String, dynamic> json) =>
      FbdNetwork(comment: json['comment'] ?? '');
  Map<String, dynamic> toJson() => {'comment': comment};
}

// -------------------------------------------------------------
// SEQUENTIAL FUNCTION CHART (SFC) MODELS
// -------------------------------------------------------------
class SfcStep {
  String id;
  String name;
  bool isInitial;
  String actionSt;

  SfcStep({
    required this.id,
    required this.name,
    this.isInitial = false,
    this.actionSt = '',
  });

  factory SfcStep.fromJson(Map<String, dynamic> json) {
    return SfcStep(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      isInitial: json['is_initial'] ?? false,
      actionSt: json['action_st'] ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'is_initial': isInitial,
    'action_st': actionSt,
  };
}

class SfcTransition {
  String id;
  String fromStepId;
  String toStepId;
  String conditionSt;
  String kind;
  List<String> toStepIds;
  List<String> fromStepIds;

  SfcTransition({
    required this.id,
    required this.fromStepId,
    required this.toStepId,
    required this.conditionSt,
    this.kind = 'single',
    List<String>? toStepIds,
    List<String>? fromStepIds,
  })  : toStepIds = toStepIds ?? [],
        fromStepIds = fromStepIds ?? [];

  factory SfcTransition.fromJson(Map<String, dynamic> json) {
    return SfcTransition(
      id: json['id'] ?? '',
      fromStepId: json['from_step_id'] ?? '',
      toStepId: json['to_step_id'] ?? '',
      conditionSt: json['condition_st'] ?? '',
      kind: json['kind'] ?? 'single',
      toStepIds: (json['to_step_ids'] as List? ?? []).map((e) => e.toString()).toList(),
      fromStepIds: (json['from_step_ids'] as List? ?? []).map((e) => e.toString()).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'from_step_id': fromStepId,
    'to_step_id': toStepId,
    'condition_st': conditionSt,
    'kind': kind,
    'to_step_ids': toStepIds,
    'from_step_ids': fromStepIds,
  };
}

class PlcProgram {
  String name;
  String language; // 'StructuredText', 'LadderLogic', 'FunctionBlockDiagram', 'SequentialFunctionChart'
  String description;
  String stSource;
  List<LdRung> rungs;
  List<FbdBlock> fbdBlocks;
  List<FbdWire> fbdWires;
  List<FbdNetwork> fbdNetworks;
  List<SfcStep> sfcSteps;
  List<SfcTransition> sfcTransitions;
  bool enabled;

  PlcProgram({
    required this.name,
    required this.language,
    this.description = '',
    this.stSource = '',
    List<LdRung>? rungs,
    List<FbdBlock>? fbdBlocks,
    List<FbdWire>? fbdWires,
    List<FbdNetwork>? fbdNetworks,
    List<SfcStep>? sfcSteps,
    List<SfcTransition>? sfcTransitions,
    this.enabled = true,
  })  : rungs = rungs ?? [],
        fbdBlocks = fbdBlocks ?? [],
        fbdWires = fbdWires ?? [],
        fbdNetworks =
            _normalizeFbdNetworks(language, fbdBlocks ?? [], fbdNetworks ?? []),
        sfcSteps = sfcSteps ?? [],
        sfcTransitions = sfcTransitions ?? [];

  /// Normalizes `fbdNetworks` so every block's `network` index has a
  /// corresponding header, and an FBD program with blocks always has at
  /// least one network (legacy migration). Applied in the constructor
  /// itself (not just `fromJson`) so directly-constructed FBD programs
  /// (e.g. the built-in default projects) stay consistent with what
  /// loading the same data through `fromJson` would produce.
  static List<FbdNetwork> _normalizeFbdNetworks(
      String language, List<FbdBlock> blocks, List<FbdNetwork> networks) {
    final result = List<FbdNetwork>.from(networks);
    final maxNet = blocks.fold<int>(-1, (m, b) => b.network > m ? b.network : m);
    // Capped at kMaxFbdNetworks: `blocks` comes from untrusted project JSON,
    // so maxNet (and therefore `needed`) can be attacker/corruption-controlled
    // (e.g. a block with `"network": 1000000000`). Without the cap the `while`
    // loop below would attempt ~1e9 allocations (OOM/hang on load).
    final needed = (language == 'FunctionBlockDiagram' && blocks.isNotEmpty)
        ? (maxNet + 1).clamp(1, kMaxFbdNetworks)
        : (maxNet + 1).clamp(0, kMaxFbdNetworks);
    while (result.length < needed) {
      result.add(FbdNetwork());
    }
    // The cap above means a corrupt block's `network` index can still exceed
    // the header list we just built (e.g. maxNet = 1e9, result.length capped
    // at kMaxFbdNetworks). Clamp any such block down into range so the
    // invariant "every block.network < fbdNetworks.length" always holds after
    // normalization, even for corrupt input. Legitimate in-range indices
    // (including trailing empty networks with no blocks) are left untouched.
    if (result.isNotEmpty) {
      final maxIndex = result.length - 1;
      for (final b in blocks) {
        if (b.network < 0 || b.network > maxIndex) {
          b.network = maxIndex;
        }
      }
    }
    return result;
  }

  factory PlcProgram.fromJson(Map<String, dynamic> json) {
    return PlcProgram(
      name: json['name'] ?? '',
      language: json['language'] ?? 'StructuredText',
      description: json['description'] ?? '',
      stSource: json['st_source'] ?? '',
      rungs: (json['rungs'] as List? ?? []).map((r) => LdRung.fromJson(r)).toList(),
      fbdBlocks: (json['fbd_blocks'] as List? ?? []).map((b) => FbdBlock.fromJson(b)).toList(),
      fbdWires: (json['fbd_wires'] as List? ?? []).map((w) => FbdWire.fromJson(w)).toList(),
      fbdNetworks:
          (json['fbd_networks'] as List? ?? []).map((n) => FbdNetwork.fromJson(n)).toList(),
      sfcSteps: (json['sfc_steps'] as List? ?? []).map((s) => SfcStep.fromJson(s)).toList(),
      sfcTransitions: (json['sfc_transitions'] as List? ?? [])
          .map((t) => SfcTransition.fromJson(t))
          .toList(),
      enabled: json['enabled'] ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'language': language,
    'description': description,
    'st_source': stSource,
    'rungs': rungs.map((r) => r.toJson()).toList(),
    'fbd_blocks': fbdBlocks.map((b) => b.toJson()).toList(),
    'fbd_wires': fbdWires.map((w) => w.toJson()).toList(),
    'fbd_networks': fbdNetworks.map((n) => n.toJson()).toList(),
    'sfc_steps': sfcSteps.map((s) => s.toJson()).toList(),
    'sfc_transitions': sfcTransitions.map((t) => t.toJson()).toList(),
    'enabled': enabled,
  };
}

class PlcTask {
  String name;
  String type; // 'Startup', 'Continuous', 'Periodic', 'Event'
  int periodMs;
  List<String> programNames;
  bool enabled;
  String triggerTag; // Event task: BOOL trigger tag path; '' = none
  int watchdogMs;    // per-task watchdog limit in ms; 0 = disabled

  PlcTask({
    required this.name,
    required this.type,
    this.periodMs = 100,
    required this.programNames,
    this.enabled = true,
    this.triggerTag = '',
    this.watchdogMs = 0,
  });

  factory PlcTask.fromJson(Map<String, dynamic> json) {
    return PlcTask(
      name: json['name'] ?? '',
      type: json['type'] ?? 'Continuous',
      periodMs: json['period_ms'] ?? 100,
      programNames: List<String>.from(json['programs'] ?? []),
      enabled: json['enabled'] ?? true,
      triggerTag: json['trigger_tag'] ?? '',
      watchdogMs: json['watchdog_ms'] ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'type': type,
    'period_ms': periodMs,
    'programs': programNames,
    'enabled': enabled,
    'trigger_tag': triggerTag,
    'watchdog_ms': watchdogMs,
  };
}

/// True if [name] collides with an existing task in [tasks], compared
/// case-insensitively after trimming whitespace. [excluding] lets an edit keep
/// its own name (pass the task being renamed). Task names must be unique
/// because the scheduler keys its per-task runtime state (periodic
/// accumulators, event-edge memory) by name — duplicates would share one entry
/// and mis-schedule.
bool isTaskNameTaken(List<PlcTask> tasks, String name, {PlcTask? excluding}) {
  final norm = name.trim().toLowerCase();
  for (final t in tasks) {
    if (identical(t, excluding)) {
      continue;
    }
    if (t.name.trim().toLowerCase() == norm) {
      return true;
    }
  }
  return false;
}

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
  // Analog-scaled rate (integrate/ramp): effective rate = ratePerSec * (source/refValue).
  // First-order lag (firstOrderLag): dual role — sourcePath is the TARGET source
  // (readPath), not a gain source, when behavior == 'firstOrderLag'.
  String sourcePath;
  double refValue;
  double tauSec;
  String valveCurve;
  String noiseDistribution;
  double driftAmplitude;
  double driftPeriodSec;

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
    this.sourcePath = '',
    this.refValue = 100.0,
    this.tauSec = 5.0,
    this.valveCurve = 'linear',
    this.noiseDistribution = 'uniform',
    this.driftAmplitude = 0.0,
    this.driftPeriodSec = 60.0,
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
        sourcePath: j['source'] ?? '',
        refValue: (j['ref_value'] as num?)?.toDouble() ?? 100.0,
        tauSec: (j['tau_sec'] as num?)?.toDouble() ?? 5.0,
        valveCurve: j['valve_curve'] ?? 'linear',
        noiseDistribution: j['noise_dist'] ?? 'uniform',
        driftAmplitude: (j['drift_amp'] as num?)?.toDouble() ?? 0.0,
        driftPeriodSec: (j['drift_period_sec'] as num?)?.toDouble() ?? 60.0,
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
        'source': sourcePath,
        'ref_value': refValue,
        'tau_sec': tauSec,
        'valve_curve': valveCurve,
        'noise_dist': noiseDistribution,
        'drift_amp': driftAmplitude,
        'drift_period_sec': driftPeriodSec,
      };
}

/// A historized pen: which tag to record, its color, sample cadence, and
/// retention. Persisted on the project; the captured samples are NOT persisted
/// (they live only in the in-memory TagHistorian).
class TrendPen implements TrendPenLike {
  @override
  String tagPath;
  String color;
  @override
  int sampleIntervalMs;
  @override
  String retentionMode; // 'points' | 'time'
  @override
  int maxPoints;
  @override
  int windowMs;

  TrendPen({
    required this.tagPath,
    this.color = 'cyan',
    this.sampleIntervalMs = 250,
    this.retentionMode = 'time',
    this.maxPoints = 1200,
    this.windowMs = 300000,
  });

  factory TrendPen.fromJson(Map<String, dynamic> json) => TrendPen(
        tagPath: json['tag_path'] ?? '',
        color: json['color'] ?? 'cyan',
        sampleIntervalMs: json['sample_interval_ms'] ?? 250,
        retentionMode: json['retention_mode'] ?? 'time',
        maxPoints: json['max_points'] ?? 1200,
        windowMs: json['window_ms'] ?? 300000,
      );

  Map<String, dynamic> toJson() => {
        'tag_path': tagPath,
        'color': color,
        'sample_interval_ms': sampleIntervalMs,
        'retention_mode': retentionMode,
        'max_points': maxPoints,
        'window_ms': windowMs,
      };
}

/// An HMI trend component's reference to a project pen, with an optional
/// per-component color override.
class TrendPenRef {
  String penTagPath;
  String? colorOverride;

  TrendPenRef({required this.penTagPath, this.colorOverride});

  factory TrendPenRef.fromJson(Map<String, dynamic> json) => TrendPenRef(
        penTagPath: json['pen_tag_path'] ?? '',
        colorOverride: json['color_override'],
      );

  Map<String, dynamic> toJson() => {
        'pen_tag_path': penTagPath,
        if (colorOverride != null) 'color_override': colorOverride,
      };
}

class HmiComponent {
  String id;
  String title;
  String type;
  String tagBinding;
  int gridSpanWidth;
  String accentColor;
  List<TrendPenRef> trendPens;
  int? windowMs;

  HmiComponent({
    required this.id,
    required this.title,
    required this.type,
    required this.tagBinding,
    this.gridSpanWidth = 1,
    this.accentColor = 'cyan',
    List<TrendPenRef>? trendPens,
    this.windowMs,
  }) : trendPens = trendPens ?? [];

  factory HmiComponent.fromJson(Map<String, dynamic> json) {
    return HmiComponent(
      id: json['id'] ?? 'comp_01',
      title: json['title'] ?? 'Component',
      type: json['type'] ?? 'PushbuttonSwitch',
      tagBinding: json['tag_binding'] ?? '',
      gridSpanWidth: json['grid_span_width'] ?? 1,
      accentColor: json['accent_color'] ?? 'cyan',
      trendPens: (json['trend_pens'] as List? ?? [])
          .map((e) => TrendPenRef.fromJson(e as Map<String, dynamic>))
          .toList(),
      windowMs: json['window_ms'],
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'type': type,
    'tag_binding': tagBinding,
    'grid_span_width': gridSpanWidth,
    'accent_color': accentColor,
    'trend_pens': trendPens.map((e) => e.toJson()).toList(),
    if (windowMs != null) 'window_ms': windowMs,
  };
}

class HmiScreenDef {
  String id;
  String title;
  String layoutType;
  List<HmiComponent> components;

  HmiScreenDef({
    required this.id,
    required this.title,
    this.layoutType = 'GridDashboard',
    required this.components,
  });

  factory HmiScreenDef.fromJson(Map<String, dynamic> json) {
    return HmiScreenDef(
      id: json['id'] ?? 'hmi_01',
      title: json['title'] ?? 'HMI Dashboard',
      layoutType: json['layout_type'] ?? 'GridDashboard',
      components: (json['components'] as List? ?? []).map((c) => HmiComponent.fromJson(c)).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'layout_type': layoutType,
    'components': components.map((c) => c.toJson()).toList(),
  };
}

class PlcProject {
  String id;
  String name;
  String version;
  String description;
  String controllerName;
  int scanPeriodMs;
  List<PlcTag> tags;
  List<PlcStructDef> structDefs;
  List<PlcProgram> programs;
  List<PlcTask> tasks;
  List<HmiScreenDef> hmis;
  List<SimRule> simRules;
  List<SignalGen> signalGens;
  List<TrendPen> trends;
  ProtocolSettings? protocols;

  PlcProject({
    required this.id,
    required this.name,
    this.version = '1.0.0',
    this.description = '',
    required this.controllerName,
    this.scanPeriodMs = 100,
    required this.tags,
    required this.structDefs,
    required this.programs,
    required this.tasks,
    required this.hmis,
    List<SimRule>? simRules,
    List<SignalGen>? signalGens,
    List<TrendPen>? trends,
    this.protocols,
  }) : simRules = simRules ?? [],
       signalGens = signalGens ?? [],
       trends = trends ?? [];

  factory PlcProject.fromJson(Map<String, dynamic> json) {
    final proj = json['project'] ?? json;
    final ctrl = proj['controller'] ?? {};
    return PlcProject(
      id: proj['id'] ?? proj['name']?.replaceAll(' ', '_')?.toLowerCase() ?? 'proj_01',
      name: proj['name'] ?? 'Untitled Project',
      version: proj['version'] ?? '1.0.0',
      description: proj['description'] ?? '',
      controllerName: ctrl['name'] ?? 'PLC_01',
      scanPeriodMs: ctrl['scan_period_ms'] ?? 100,
      tags: (proj['tags'] as List? ?? []).map((t) => PlcTag.fromJson(t)).toList(),
      structDefs: (proj['struct_defs'] as List? ?? []).map((s) => PlcStructDef.fromJson(s)).toList(),
      programs: (proj['programs'] as List? ?? []).map((p) => PlcProgram.fromJson(p)).toList(),
      tasks: (proj['tasks'] as List? ?? []).map((tk) => PlcTask.fromJson(tk)).toList(),
      hmis: (proj['hmis'] as List? ?? []).map((h) => HmiScreenDef.fromJson(h)).toList(),
      simRules: (proj['sim_rules'] as List? ?? []).map((r) => SimRule.fromJson(r)).toList(),
      signalGens: (proj['signal_gens'] as List? ?? []).map((g) => SignalGen.fromJson(g)).toList(),
      trends: (proj['trends'] as List? ?? [])
          .map((e) => TrendPen.fromJson(e as Map<String, dynamic>))
          .toList(),
      protocols: proj['protocols'] != null
          ? ProtocolSettings.fromJson(proj['protocols'] as Map<String, dynamic>)
          : (proj['opcua_map'] != null
              ? ProtocolSettings(
                  gatewayUrl: kDefaultGatewayUrl,
                  opcua: OpcUaProtocolConfig(
                    enabled: true,
                    namespaceUri:
                        OpcuaMap.fromJson({'opcua_map': proj['opcua_map']}).namespaceUri,
                    map: OpcuaMap.fromJson({'opcua_map': proj['opcua_map']}),
                  ),
                )
              : null),
    );
  }

  Map<String, dynamic> toJson() => {
    'schema': 1,
    'project': {
      'id': id,
      'name': name,
      'version': version,
      'description': description,
      'controller': {
        'name': controllerName,
        'scan_period_ms': scanPeriodMs,
      },
      'tags': tags.map((t) => t.toJson()).toList(),
      'struct_defs': structDefs.map((s) => s.toJson()).toList(),
      'programs': programs.map((p) => p.toJson()).toList(),
      'tasks': tasks.map((tk) => tk.toJson()).toList(),
      'hmis': hmis.map((h) => h.toJson()).toList(),
      'sim_rules': simRules.map((r) => r.toJson()).toList(),
      'signal_gens': signalGens.map((g) => g.toJson()).toList(),
      'trends': trends.map((e) => e.toJson()).toList(),
      if (protocols != null) 'protocols': protocols!.toJson(),
    }
  };

  String toFormattedJson() {
    return const JsonEncoder.withIndent('  ').convert(toJson());
  }
}
