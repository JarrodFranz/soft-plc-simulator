import '../models/fb_name_validation.dart';
import '../models/project_model.dart';
import '../models/system_tags.dart';
import 'import_ir.dart';
import 'type_normalize.dart';

/// Result of mapping the `functionBlock` POUs of an imported project into
/// native FB definitions. [registry] is keyed by FINAL FB name; [renameMap]
/// maps each imported FB POU's ORIGINAL name to its final name so the LD
/// translator can retarget call blocks that referenced the old name.
class FbImportResult {
  final List<FbDefinition> defs;
  final Map<String, FbDefinition> registry;
  final Map<String, String> renameMap;
  FbImportResult(this.defs, this.registry, this.renameMap);
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

/// Maps the ST-bodied `functionBlock` POUs of [pous] to `FbDefinition`s.
/// Graphical-bodied FBs are skipped with a warning (ST-bodied FBs only).
/// Names are sanitized and collision-resolved against [structs] + the FBs
/// built so far (via `fbNameValidationError`), avoiding reserved block types,
/// builtin composites, struct names, and `kSystemTagName`. Pure; never throws.
FbImportResult mapImportedFbs(
  List<ImportedPou> pous, {
  required List<PlcStructDef> structs,
  required Set<String> dutNames,
  required List<ImportWarning> warnings,
}) {
  final defs = <FbDefinition>[];
  final registry = <String, FbDefinition>{};
  final renameMap = <String, String>{};
  // Growing scratch: structs known + FBs built so far, so name collisions
  // against earlier-imported FBs are caught. fbDefinitions is a mutable list.
  final scratch = PlcProject(
      id: 'scratch', name: 'scratch', controllerName: 'PLC',
      programs: [], tasks: [], hmis: [], tags: [],
      structDefs: structs, fbDefinitions: defs);

  for (final pou in pous) {
    if (pou.kind != PouKind.functionBlock) continue;
    final body = pou.body;
    if (body is! TextBody) {
      final n = body is GraphBody ? body.nodes.length : 0;
      warnings.add(ImportWarning(severity: WarningSeverity.warning,
          message: 'Function block "${pou.name}" has a graphical body '
              '(${pou.lang.name}) — not imported (ST-bodied FBs only). '
              '$n elements captured.'));
      continue;
    }

    // Vars.
    final vars = <FbVar>[];
    for (final v in pou.localVars) {
      if (v.scope == VarScope.inOut) {
        warnings.add(ImportWarning(severity: WarningSeverity.info,
            message: 'VAR_IN_OUT "${v.name}" on FB "${pou.name}" imported as an '
                'input (by-reference semantics unsupported).'));
      }
      final appType = normalizeType(v.baseType, knownDutNames: dutNames);
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

    final def = FbDefinition(name: name, vars: vars, stSource: body.source);
    defs.add(def); // scratch.fbDefinitions IS defs, so the next FB sees it
    registry[name] = def;
    renameMap[pou.name] = name;
  }
  return FbImportResult(defs, registry, renameMap);
}
