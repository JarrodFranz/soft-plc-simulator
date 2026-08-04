import '../models/fb_name_validation.dart';
import '../models/project_model.dart';
import '../models/system_tags.dart';
import 'import_ir.dart';
import 'rll_compile.dart';
import 'type_normalize.dart';

/// Result of mapping the `functionBlock` POUs of an imported project into
/// native FB definitions. [registry] is keyed by FINAL FB name; [renameMap]
/// maps each imported FB POU's ORIGINAL name to its final name so the LD
/// translator can retarget call blocks that referenced the old name.
///
/// The `*Rll*` counters cover LADDER-bodied FB (Rockwell RLL-Logic AOI) bodies
/// compiled here. `mapImportedProject` folds them into the EXISTING RLL report
/// fields — AOI-body rungs are RLL rungs, so no new preview UI is needed.
class FbImportResult {
  final List<FbDefinition> defs;
  final Map<String, FbDefinition> registry;
  final Map<String, String> renameMap;
  final int translatedRllRungCount;
  final int stubbedRllRungCount;
  final Set<String> unsupportedRllInstructions;
  final Map<String, int> rllStubReasons;
  FbImportResult(
    this.defs,
    this.registry,
    this.renameMap, {
    this.translatedRllRungCount = 0,
    this.stubbedRllRungCount = 0,
    this.unsupportedRllInstructions = const {},
    this.rllStubReasons = const {},
  });
}

String _sanitize(String raw) {
  var s = raw.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
  if (s.isEmpty) s = 'Fb';
  if (RegExp(r'^[0-9]').hasMatch(s)) s = '_$s';
  return s;
}

FbVarDir _dir(VarScope scope) => switch (scope) {
      VarScope.input => FbVarDir.input,
      VarScope.output => FbVarDir.output,
      VarScope.inOut => FbVarDir.input,
      _ => FbVarDir.internal,
    };

/// Maps the ST-bodied and LADDER-bodied `functionBlock` POUs of [pous] to
/// `FbDefinition`s. A `TextBody` becomes the FB's `stSource`; a
/// `NeutralLadderBody` (a Rockwell RLL-Logic AOI) is compiled by
/// [compileRllRungs] into the FB's native `ladderRungs`. Other graphical
/// bodies are still skipped with a warning. Names are sanitized and
/// collision-resolved against [structs] + the FBs built so far (via
/// `fbNameValidationError`), avoiding reserved block types, builtin
/// composites, struct names, and `kSystemTagName`. Pure; never throws.
FbImportResult mapImportedFbs(
  List<ImportedPou> pous, {
  required List<PlcStructDef> structs,
  required Set<String> dutNames,
  required List<ImportWarning> warnings,
}) {
  final defs = <FbDefinition>[];
  final registry = <String, FbDefinition>{};
  final renameMap = <String, String>{};
  var translatedRllRungCount = 0;
  var stubbedRllRungCount = 0;
  final unsupportedRllInstructions = <String>{};
  final rllStubReasons = <String, int>{};
  // Growing scratch: structs known + FBs built so far, so name collisions
  // against earlier-imported FBs are caught. fbDefinitions is a mutable list.
  final scratch = PlcProject(
      id: 'scratch', name: 'scratch', controllerName: 'PLC',
      programs: [], tasks: [], hmis: [], tags: [],
      structDefs: structs, fbDefinitions: defs);

  for (final pou in pous) {
    if (pou.kind != PouKind.functionBlock) continue;
    final body = pou.body;
    if (body is! TextBody && body is! NeutralLadderBody) {
      final n = body is GraphBody ? body.nodes.length : 0;
      warnings.add(ImportWarning(severity: WarningSeverity.warning,
          message: 'Function block "${pou.name}" has a graphical body '
              '(${pou.lang.name}) — not imported (ST-bodied FBs only). '
              '$n elements captured.'));
      continue;
    }
    if (pou.lang == PouLanguage.il) {
      warnings.add(ImportWarning(severity: WarningSeverity.info,
          message: 'Function block "${pou.name}" imported from IL as Structured '
              "Text — verify against the app's ST subset."));
    }

    // Vars.
    final vars = <FbVar>[];
    for (final v in pou.localVars) {
      if (v.scope == VarScope.inOut) {
        warnings.add(ImportWarning(severity: WarningSeverity.info,
            message: 'VAR_IN_OUT "${v.name}" on FB "${pou.name}" imported as an '
                'input (by-reference semantics unsupported).'));
      }
      // A var whose baseType names an EARLIER-imported FB/AOI POU (by its
      // ORIGINAL name) resolves to that FB's final name, so an AOI LocalTag
      // typed as another AOI ends up composite instead of falling back to the
      // INT16 scalar (which would make every nested read/write a silent
      // no-op). `registry`/`renameMap` hold only FBs defined BEFORE this one —
      // the same documented forward-reference limit the body compiler has.
      // Mirrors the global-tag resolution in `ir_to_project.dart`.
      final resolvedBaseType = renameMap[v.baseType] ?? v.baseType;
      final appType = normalizeType(resolvedBaseType,
          knownDutNames: {...dutNames, ...registry.keys});
      vars.add(FbVar(
        name: v.name,
        dataType: appType,
        direction: _dir(v.scope),
        initialValue: coerceInitialValue(scratch, appType, v.arrayLength,
            v.initialValue == null ? null : '${v.initialValue}', warnings),
      ));
    }

    // Name sanitize + collision.
    var name = _sanitize(pou.name);
    if (name != pou.name) {
      warnings.add(ImportWarning(severity: WarningSeverity.info,
          message: 'Function block "${pou.name}" renamed to "$name" (identifier rules).'));
    }
    if (name == kSystemTagName || fbNameValidationError(scratch, name) != null) {
      final base = name;
      var i = 1;
      while (fbNameValidationError(scratch, '${base}_$i') != null ||
          '${base}_$i' == kSystemTagName) {
        i++;
      }
      final renamed = '${base}_$i';
      warnings.add(ImportWarning(severity: WarningSeverity.info,
          message: 'Function block "$name" renamed to "$renamed" (name collision/reserved).'));
      name = renamed;
    }

    final FbDefinition def;
    if (body is NeutralLadderBody) {
      // Compiled against the registry/renameMap built SO FAR: an AOI ladder
      // calling an AOI defined EARLIER in the file routes to a real FB-call
      // node; one defined later stubs as an unknown mnemonic (documented
      // ordering limitation — Rockwell exports list dependencies first).
      final tr = compileRllRungs(body, pouName: 'AOI $name',
          fbRegistry: registry, fbRenameMap: renameMap);
      warnings.addAll(tr.warnings);
      translatedRllRungCount += tr.translatedRungCount;
      stubbedRllRungCount += tr.stubbedRungCount;
      unsupportedRllInstructions.addAll(tr.unsupportedInstructions);
      tr.stubReasons.forEach((k, v) =>
          rllStubReasons[k] = (rllStubReasons[k] ?? 0) + v);
      if (tr.translatedRungCount > 0) {
        // >= 1 rung compiled: the AOI executes (stubbed rungs are inert
        // rail-to-rail placeholders, their reasons already warned above).
        def = FbDefinition(name: name, vars: vars, ladderRungs: tr.rungs);
      } else {
        // Nothing compiled -> today's interface-only no-op. An AOI whose
        // RLLContent is empty/absent has NOTHING to fail at, so it gets no
        // "none of its 0 rungs compiled" noise — only a real compile failure
        // warns.
        if (body.rungs.isNotEmpty) {
          warnings.add(ImportWarning(severity: WarningSeverity.warning,
              message: 'Function block "$name": none of its ${body.rungs.length} '
                  'ladder rungs compiled — interface imported, logic not '
                  'translated (the instance is a no-op).'));
        }
        def = FbDefinition(name: name, vars: vars);
      }
    } else {
      def = FbDefinition(name: name, vars: vars,
          stSource: body is TextBody ? body.source : '');
    }
    defs.add(def); // scratch.fbDefinitions IS defs, so the next FB sees it
    registry[name] = def;
    renameMap[pou.name] = name;
  }
  return FbImportResult(defs, registry, renameMap,
      translatedRllRungCount: translatedRllRungCount,
      stubbedRllRungCount: stubbedRllRungCount,
      unsupportedRllInstructions: unsupportedRllInstructions,
      rllStubReasons: rllStubReasons);
}
