import '../models/project_model.dart';
import '../models/system_tags.dart';
import '../models/tag_resolver.dart';
import 'import_ir.dart';
import 'type_normalize.dart';

class ImportReport {
  final int tagCount;
  final int structCount;
  final int stProgramCount;
  final int graphicalStubCount;
  final List<ImportWarning> warnings;
  ImportReport({required this.tagCount, required this.structCount,
      required this.stProgramCount, required this.graphicalStubCount,
      required this.warnings});
}

class ImportResult {
  final PlcProject project;
  final ImportReport report;
  ImportResult({required this.project, required this.report});
}

/// Sanitizes an imported identifier to the app's rules: keep [A-Za-z0-9_],
/// replace every other char with '_', prefix '_' if it starts with a digit,
/// fall back to 'Tag' if empty. Uniqueness/reserved-name handling (including
/// avoiding [kSystemTagName]) is applied by the caller.
String _sanitizeIdentifier(String raw) {
  var s = raw.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
  if (s.isEmpty) {
    s = 'Tag';
  }
  if (RegExp(r'^[0-9]').hasMatch(s)) {
    s = '_$s';
  }
  return s;
}

/// Maps the vendor-neutral IR into a new [PlcProject]. Pure and never-throws.
/// [projectId]/[projectName] are supplied by the caller (keeps this
/// deterministic). Graphical POUs become language-tagged stubs (empty body +
/// a note) with a warning; the raw graph lives only in [ir] — a future
/// per-language translator re-imports to produce a real body.
ImportResult mapImportedProject(ImportedProject ir,
    {required String projectName, required String projectId}) {
  final warnings = <ImportWarning>[...ir.warnings];
  final dutNames = ir.types.map((t) => t.name).toSet();

  // Structs (dependency order: a struct referencing another comes after it).
  // A throwaway project only used to resolve type defaults during mapping.
  final scratch = PlcProject(id: 'scratch', name: 'scratch', controllerName: 'PLC',
      programs: [], tasks: [], hmis: [], structDefs: [], tags: []);
  final structs = _orderTypes(ir.types).map((t) => PlcStructDef(
        name: t.name,
        fields: t.fields.map((f) {
          final appType = normalizeType(f.baseType, knownDutNames: dutNames);
          return StructFieldDef(
            name: f.name,
            dataType: appType,
            arrayLength: f.arrayLength,
            defaultValue: coerceInitialValue(scratch, appType, f.arrayLength,
                f.initialValue == null ? null : '${f.initialValue}', warnings),
          );
        }).toList(),
      )).toList();

  // Now scratch2 knows the structs, so composite-typed vars resolve.
  final scratch2 = PlcProject(id: 'scratch', name: 'scratch', controllerName: 'PLC',
      programs: [], tasks: [], hmis: [], structDefs: structs, tags: []);

  // Vars -> tags (with name sanitization + within-import dedup).
  final used = <String>{};
  final tags = <PlcTag>[];
  for (final v in ir.globalVars) {
    final appType = normalizeType(v.baseType, knownDutNames: dutNames);
    var name = _sanitizeIdentifier(v.name);
    if (name != v.name) {
      warnings.add(ImportWarning(severity: WarningSeverity.info,
          message: 'Variable "${v.name}" renamed to "$name" (identifier rules).'));
    }
    if (name == kSystemTagName || used.contains(name)) {
      var n = 1;
      while (used.contains('${name}_$n') || '${name}_$n' == kSystemTagName) {
        n++;
      }
      final renamed = '${name}_$n';
      warnings.add(ImportWarning(severity: WarningSeverity.info,
          message: 'Variable "$name" renamed to "$renamed" (name collision'
              '${name == kSystemTagName ? '/reserved' : ''}).'));
      name = renamed;
    }
    used.add(name);
    final isComposite = defaultValueFor(scratch2, appType, 0) is Map;
    final def = coerceInitialValue(scratch2, appType, v.arrayLength,
        v.initialValue == null ? null : '${v.initialValue}', warnings);
    tags.add(PlcTag(
      name: name,
      path: name,
      dataType: appType,
      arrayLength: v.arrayLength,
      value: def,
      defaultValue: (v.arrayLength == 0 && !isComposite) ? def : null,
      ioType: switch (v.scope) {
        VarScope.input => 'SimulatedInput',
        VarScope.output => 'SimulatedOutput',
        _ => 'Internal',
      },
      retentive: v.retain,
    ));
  }

  // POUs -> programs.
  var stCount = 0;
  var stubCount = 0;
  final programs = <PlcProgram>[];
  for (final pou in ir.pous) {
    final body = pou.body;
    if (body is TextBody) {
      if (pou.lang == PouLanguage.il) {
        warnings.add(ImportWarning(severity: WarningSeverity.info,
            message: 'POU "${pou.name}" imported from IL as Structured Text — '
                "verify against the app's ST subset."));
      }
      programs.add(PlcProgram(name: pou.name, language: 'StructuredText', stSource: body.source));
      stCount++;
    } else if (body is GraphBody) {
      final lang = switch (pou.lang) {
        PouLanguage.ld => 'LadderLogic',
        PouLanguage.fbd => 'FunctionBlockDiagram',
        PouLanguage.sfc => 'SequentialFunctionChart',
        _ => 'StructuredText',
      };
      warnings.add(ImportWarning(severity: WarningSeverity.warning,
          message: 'POU "${pou.name}" ($lang): graphical body not yet translated '
              '(${body.nodes.length} elements captured) — re-import once graphical '
              'translation ships.'));
      programs.add(PlcProgram(name: pou.name, language: lang,
          description: 'Graphical body not yet translated (${body.nodes.length} elements captured).'));
      stubCount++;
    }
  }

  final project = PlcProject(
    id: projectId, name: projectName, controllerName: projectName,
    tags: tags, structDefs: structs, programs: programs, tasks: [], hmis: [],
  );
  return ImportResult(
    project: project,
    report: ImportReport(tagCount: tags.length, structCount: structs.length,
        stProgramCount: stCount, graphicalStubCount: stubCount, warnings: warnings),
  );
}

/// Topologically orders [types] so a struct referencing another DUT is
/// emitted after it. A cycle (or an unresolved ref) is broken by emitting the
/// remaining types in input order.
List<ImportedType> _orderTypes(List<ImportedType> types) {
  final byName = {for (final t in types) t.name: t};
  final out = <ImportedType>[];
  final done = <String>{};
  void visit(ImportedType t, Set<String> stack) {
    if (done.contains(t.name) || stack.contains(t.name)) {
      return;
    }
    stack.add(t.name);
    for (final f in t.fields) {
      final dep = byName[f.baseType];
      if (dep != null) {
        visit(dep, stack);
      }
    }
    stack.remove(t.name);
    if (!done.contains(t.name)) {
      done.add(t.name);
      out.add(t);
    }
  }
  for (final t in types) {
    visit(t, {});
  }
  return out;
}
