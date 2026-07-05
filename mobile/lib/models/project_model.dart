import 'dart:convert';

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
  };
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
enum LdKind { leftRail, rightRail, contact, coil, block }

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
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'variable': variable,
    'modifier': modifier,
    'block_type': blockType,
    'preset_ms': presetMs,
    'comment': comment,
    'col': col,
    'row': row,
  };
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
  String type; // 'AND', 'OR', 'NOT', 'ADD', 'SUB', 'TON', 'LIMIT', 'TAG_INPUT', 'TAG_OUTPUT'
  String title;
  String tagBinding;
  double x;
  double y;

  FbdBlock({
    required this.id,
    required this.type,
    required this.title,
    this.tagBinding = '',
    this.x = 100,
    this.y = 100,
  });

  factory FbdBlock.fromJson(Map<String, dynamic> json) {
    return FbdBlock(
      id: json['id'] ?? '',
      type: json['type'] ?? '',
      title: json['title'] ?? '',
      tagBinding: json['tag_binding'] ?? '',
      x: (json['x'] as num?)?.toDouble() ?? 100,
      y: (json['y'] as num?)?.toDouble() ?? 100,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'title': title,
    'tag_binding': tagBinding,
    'x': x,
    'y': y,
  };
}

class FbdWire {
  String fromBlockId;
  String toBlockId;

  FbdWire({
    required this.fromBlockId,
    required this.toBlockId,
  });

  factory FbdWire.fromJson(Map<String, dynamic> json) {
    return FbdWire(
      fromBlockId: json['from_block_id'] ?? '',
      toBlockId: json['to_block_id'] ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'from_block_id': fromBlockId,
    'to_block_id': toBlockId,
  };
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

  SfcTransition({
    required this.id,
    required this.fromStepId,
    required this.toStepId,
    required this.conditionSt,
  });

  factory SfcTransition.fromJson(Map<String, dynamic> json) {
    return SfcTransition(
      id: json['id'] ?? '',
      fromStepId: json['from_step_id'] ?? '',
      toStepId: json['to_step_id'] ?? '',
      conditionSt: json['condition_st'] ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'from_step_id': fromStepId,
    'to_step_id': toStepId,
    'condition_st': conditionSt,
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
    List<SfcStep>? sfcSteps,
    List<SfcTransition>? sfcTransitions,
    this.enabled = true,
  })  : rungs = rungs ?? [],
        fbdBlocks = fbdBlocks ?? [],
        fbdWires = fbdWires ?? [],
        sfcSteps = sfcSteps ?? [],
        sfcTransitions = sfcTransitions ?? [];

  factory PlcProgram.fromJson(Map<String, dynamic> json) {
    return PlcProgram(
      name: json['name'] ?? '',
      language: json['language'] ?? 'StructuredText',
      description: json['description'] ?? '',
      stSource: json['st_source'] ?? '',
      rungs: (json['rungs'] as List? ?? []).map((r) => LdRung.fromJson(r)).toList(),
      fbdBlocks: (json['fbd_blocks'] as List? ?? []).map((b) => FbdBlock.fromJson(b)).toList(),
      fbdWires: (json['fbd_wires'] as List? ?? []).map((w) => FbdWire.fromJson(w)).toList(),
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

  PlcTask({
    required this.name,
    required this.type,
    this.periodMs = 100,
    required this.programNames,
    this.enabled = true,
  });

  factory PlcTask.fromJson(Map<String, dynamic> json) {
    return PlcTask(
      name: json['name'] ?? '',
      type: json['type'] ?? 'Continuous',
      periodMs: json['period_ms'] ?? 100,
      programNames: List<String>.from(json['programs'] ?? []),
      enabled: json['enabled'] ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'type': type,
    'period_ms': periodMs,
    'programs': programNames,
  };
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

class HmiComponent {
  String id;
  String title;
  String type;
  String tagBinding;
  int gridSpanWidth;
  String accentColor;

  HmiComponent({
    required this.id,
    required this.title,
    required this.type,
    required this.tagBinding,
    this.gridSpanWidth = 1,
    this.accentColor = 'cyan',
  });

  factory HmiComponent.fromJson(Map<String, dynamic> json) {
    return HmiComponent(
      id: json['id'] ?? 'comp_01',
      title: json['title'] ?? 'Component',
      type: json['type'] ?? 'PushbuttonSwitch',
      tagBinding: json['tag_binding'] ?? '',
      gridSpanWidth: json['grid_span_width'] ?? 1,
      accentColor: json['accent_color'] ?? 'cyan',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'type': type,
    'tag_binding': tagBinding,
    'grid_span_width': gridSpanWidth,
    'accent_color': accentColor,
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
  }) : simRules = simRules ?? [];

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
    }
  };

  String toFormattedJson() {
    return const JsonEncoder.withIndent('  ').convert(toJson());
  }
}
