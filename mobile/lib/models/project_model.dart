import 'dart:convert';

class PlcTag {
  String name;
  String path;
  String dataType; // 'BOOL', 'INT16', 'INT32', 'FLOAT64', 'STRING', 'TIMER'
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
      value: json['initial_value'] ?? json['value'] ?? false,
      quality: json['quality'] ?? 'Good',
      access: json['access'] ?? 'ReadWrite',
      retentive: json['retentive'] ?? false,
      description: json['description'] ?? '',
      engineeringUnits: json['engineering_units'] ?? '',
      ioType: json['io_type'] ?? 'Internal',
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'path': path,
    'data_type': dataType,
    'initial_value': value,
    'access': access,
    'retentive': retentive,
    'description': description,
    'engineering_units': engineeringUnits,
    'io_type': ioType,
  };
}

class StructFieldDef {
  String name;
  String dataType;
  dynamic defaultValue;

  StructFieldDef({
    required this.name,
    required this.dataType,
    required this.defaultValue,
  });
}

class PlcStructDef {
  String name;
  List<StructFieldDef> fields;

  PlcStructDef({
    required this.name,
    required this.fields,
  });
}

class PlcDataBlock {
  String name;
  String structTypeName;
  Map<String, dynamic> fieldValues;

  PlcDataBlock({
    required this.name,
    required this.structTypeName,
    required this.fieldValues,
  });
}

// -------------------------------------------------------------
// LADDER LOGIC (LD) MODELS WITH PARALLEL BRANCHES
// -------------------------------------------------------------
class LdInstruction {
  String type; // 'XIC', 'XIO', 'OTE', 'OTL', 'OTU', 'TON', 'TOF', 'EQU', 'GRT', 'LES'
  String operandTag;
  String comment;
  int presetMs; // For TON/TOF timers

  LdInstruction({
    required this.type,
    required this.operandTag,
    this.comment = '',
    this.presetMs = 5000,
  });
}

class LdBranch {
  List<LdInstruction> inputInstructions;
  List<LdInstruction> outputInstructions;

  LdBranch({
    required this.inputInstructions,
    required this.outputInstructions,
  });
}

class LdRung {
  int rungIndex;
  String comment;
  List<LdInstruction> inputInstructions;
  List<LdInstruction> outputInstructions;
  List<LdBranch> parallelBranches; // Parallel OR Rung Branches

  LdRung({
    required this.rungIndex,
    this.comment = '',
    required this.inputInstructions,
    required this.outputInstructions,
    List<LdBranch>? parallelBranches,
  }) : parallelBranches = parallelBranches ?? [];
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
}

class FbdWire {
  String fromBlockId;
  String toBlockId;

  FbdWire({
    required this.fromBlockId,
    required this.toBlockId,
  });
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
      enabled: json['enabled'] ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'language': language,
    'description': description,
    'st_source': stSource,
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
  List<PlcDataBlock> dataBlocks;
  List<PlcProgram> programs;
  List<PlcTask> tasks;
  List<HmiScreenDef> hmis;

  PlcProject({
    required this.id,
    required this.name,
    this.version = '1.0.0',
    this.description = '',
    required this.controllerName,
    this.scanPeriodMs = 100,
    required this.tags,
    required this.structDefs,
    required this.dataBlocks,
    required this.programs,
    required this.tasks,
    required this.hmis,
  });

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
      structDefs: [],
      dataBlocks: [],
      programs: (proj['programs'] as List? ?? []).map((p) => PlcProgram.fromJson(p)).toList(),
      tasks: (proj['tasks'] as List? ?? []).map((tk) => PlcTask.fromJson(tk)).toList(),
      hmis: (proj['hmis'] as List? ?? []).map((h) => HmiScreenDef.fromJson(h)).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
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
      'programs': programs.map((p) => p.toJson()).toList(),
      'tasks': tasks.map((tk) => tk.toJson()).toList(),
      'hmis': hmis.map((h) => h.toJson()).toList(),
    }
  };

  String toFormattedJson() {
    return const JsonEncoder.withIndent('  ').convert(toJson());
  }
}
