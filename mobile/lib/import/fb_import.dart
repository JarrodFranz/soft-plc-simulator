import '../models/fb_name_validation.dart';
import '../models/project_model.dart';
import '../models/system_tags.dart';
import 'fbd_translate.dart';
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
///
/// The `*Fbd*` counters cover FBD-bodied FB (Rockwell FBD-Logic AOI) bodies
/// translated here. `mapImportedProject` folds them into the EXISTING FBD
/// report fields — AOI-body networks are FBD networks, so no new preview UI is
/// needed.
class FbImportResult {
  final List<FbDefinition> defs;
  final Map<String, FbDefinition> registry;
  final Map<String, String> renameMap;
  final int translatedRllRungCount;
  final int stubbedRllRungCount;
  final Set<String> unsupportedRllInstructions;
  final Map<String, int> rllStubReasons;
  final int translatedFbdNetworkCount;
  final int stubbedFbdNetworkCount;
  final Set<String> unsupportedFbdBlockTypes;
  final Map<String, int> fbdStubReasons;
  FbImportResult(
    this.defs,
    this.registry,
    this.renameMap, {
    this.translatedRllRungCount = 0,
    this.stubbedRllRungCount = 0,
    this.unsupportedRllInstructions = const {},
    this.rllStubReasons = const {},
    this.translatedFbdNetworkCount = 0,
    this.stubbedFbdNetworkCount = 0,
    this.unsupportedFbdBlockTypes = const {},
    this.fbdStubReasons = const {},
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

/// Maps the ST-bodied, LADDER-bodied and (L5X only) FBD-bodied `functionBlock`
/// POUs of [pous] to `FbDefinition`s. A `TextBody` becomes the FB's
/// `stSource`; a `NeutralLadderBody` (a Rockwell RLL-Logic AOI) is compiled by
/// [compileRllRungs] into the FB's native `ladderRungs`; a `GraphBody` on an
/// `fbd` POU is translated by [translateFbdBody] into the FB's native
/// `fbdBlocks`/`fbdWires`/`fbdNetworks` — but ONLY when [dialect] is
/// `ImportDialect.l5x`. A PLCopen FBD `functionBlock` keeps the existing
/// "graphical body — not imported" warning byte-for-byte, pending
/// PLCopen-specific validation (see docs/DEFERRED.md). Other graphical bodies
/// are still skipped with that warning. Names are sanitized and
/// collision-resolved against [structs] + the FBs built so far (via
/// `fbNameValidationError`), avoiding reserved block types, builtin
/// composites, struct names, and `kSystemTagName`. Pure; never throws.
FbImportResult mapImportedFbs(
  List<ImportedPou> pous, {
  required List<PlcStructDef> structs,
  required Set<String> dutNames,
  required List<ImportWarning> warnings,
  ImportDialect dialect = ImportDialect.plcOpen,
}) {
  final defs = <FbDefinition>[];
  final registry = <String, FbDefinition>{};
  final renameMap = <String, String>{};
  var translatedRllRungCount = 0;
  var stubbedRllRungCount = 0;
  final unsupportedRllInstructions = <String>{};
  final rllStubReasons = <String, int>{};
  var translatedFbdNetworkCount = 0;
  var stubbedFbdNetworkCount = 0;
  final unsupportedFbdBlockTypes = <String>{};
  final fbdStubReasons = <String, int>{};
  // Growing scratch: structs known + FBs built so far, so name collisions
  // against earlier-imported FBs are caught. fbDefinitions is a mutable list.
  final scratch = PlcProject(
      id: 'scratch', name: 'scratch', controllerName: 'PLC',
      programs: [], tasks: [], hmis: [], tags: [],
      structDefs: structs, fbDefinitions: defs);

  for (final pou in pous) {
    if (pou.kind != PouKind.functionBlock) continue;
    final body = pou.body;
    // Only an L5X-parser-produced FBD AOI enters the FBD arm below.
    final isFbdAoiBody = body is GraphBody &&
        pou.lang == PouLanguage.fbd &&
        dialect == ImportDialect.l5x;
    if (body is! TextBody && body is! NeutralLadderBody && !isFbdAoiBody) {
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
    } else if (body is GraphBody) {
      // Reachable only when `isFbdAoiBody` (the guard above rejects every
      // other GraphBody). Translated against the registry/renameMap built SO
      // FAR: an AOI sheet calling an AOI defined EARLIER routes to a real
      // FB-instance block; one defined later stubs (`unsupported-block`,
      // inventoried) — the same documented ordering limit the ladder arm has.
      final tr = translateFbdBody(body, pouName: 'AOI $name',
          fbRegistry: registry, fbRenameMap: renameMap);
      warnings.addAll(tr.warnings);
      translatedFbdNetworkCount += tr.translatedNetworkCount;
      stubbedFbdNetworkCount += tr.stubbedNetworkCount;
      unsupportedFbdBlockTypes.addAll(tr.unsupportedBlockTypes);
      tr.stubReasons.forEach((k, v) =>
          fbdStubReasons[k] = (fbdStubReasons[k] ?? 0) + v);
      if (tr.translatedNetworkCount > 0) {
        // Nested-FB instance tags (spec R3): `tr.instanceTags` are PROJECT
        // tags this mapper cannot add, and a shared global instance would make
        // every AOI instance share nested state. Consume them locally instead:
        // reuse a same-named FbVar when the AOI already declares one (its
        // LocalTag typed as the nested AOI), else synthesize an internal var.
        // Either way the nested instance lives INSIDE the AOI struct, so
        // LdScope rewrites the call block's tagBinding to
        // `<instance>.<localTag>` and each instance gets its own nested state.
        for (final it in tr.instanceTags) {
          final original = it.name;
          // The instance name came from the L5X `Operand` attribute, which is
          // NOT constrained to this app's identifier rules. Every other import
          // path sanitizes before creating a member (`_sanitize` here, and
          // `_sanitizeIdentifier` in ir_to_project for project tags), so this
          // one must too: an unsanitized member name would be unaddressable by
          // `readPath`/`writePath` and by the FB editor.
          var vname = _sanitize(original);
          if (vname != original) {
            warnings.add(ImportWarning(severity: WarningSeverity.info,
                message: 'Function block "$name": nested instance "$original" '
                    'renamed to "$vname" (identifier rules).'));
          }
          FbVar? existing;
          for (final v in vars) {
            if (v.name == vname) {
              existing = v;
              break;
            }
          }
          if (existing != null && existing.dataType != it.dataType) {
            // The name collides with an UNRELATED var of another type (often a
            // consequence of the sanitize above). Dedupe rather than reuse it:
            // reusing would point the call block at a member of the wrong type.
            final base = vname;
            var i = 2;
            while (vars.any((v) => v.name == '${base}_$i')) {
              i++;
            }
            vname = '${base}_$i';
            warnings.add(ImportWarning(severity: WarningSeverity.info,
                message: 'Function block "$name": local "$base" is typed '
                    '"${existing.dataType}" but backs a "${it.dataType}" call '
                    'block — the nested instance was given its own local '
                    '"$vname" (a reference to "$base" may not resolve).'));
            existing = null;
          }
          if (existing == null) {
            vars.add(FbVar(name: vname, dataType: it.dataType,
                direction: FbVarDir.internal, initialValue: it.value));
          }
          if (vname != original) {
            // Retarget the call block(s) that named the instance, mirroring
            // ir_to_project's instance-tag retarget loop. Only blocks whose
            // TYPE is a registered FB may be retargeted: a TAG_INPUT/CONST
            // binding that coincidentally matches must not be.
            for (final b in tr.blocks) {
              if (registry.containsKey(b.type) && b.tagBinding == original) {
                b.tagBinding = vname;
              }
            }
          }
        }
        def = FbDefinition(name: name, vars: vars, fbdBlocks: tr.blocks,
            fbdWires: tr.wires, fbdNetworks: tr.networks);
      } else {
        // Nothing translated -> today's interface-only no-op. An AOI whose
        // FBDContent is empty/absent has NOTHING to fail at, so it gets no
        // noise — only a real translation failure warns (mirrors the ladder
        // arm's `body.rungs.isNotEmpty` guard).
        if (body.nodes.isNotEmpty) {
          warnings.add(ImportWarning(severity: WarningSeverity.warning,
              message: 'Function block "$name": none of its FBD networks '
                  'translated — interface imported, logic not translated (the '
                  'instance is a no-op).'));
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
      rllStubReasons: rllStubReasons,
      translatedFbdNetworkCount: translatedFbdNetworkCount,
      stubbedFbdNetworkCount: stubbedFbdNetworkCount,
      unsupportedFbdBlockTypes: unsupportedFbdBlockTypes,
      fbdStubReasons: fbdStubReasons);
}
