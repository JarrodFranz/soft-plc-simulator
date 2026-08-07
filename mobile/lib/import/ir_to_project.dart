import '../models/project_model.dart';
import '../models/system_tags.dart';
import '../models/tag_resolver.dart';
import 'fb_import.dart';
import 'fbd_translate.dart';
import 'import_ir.dart';
import 'ld_translate.dart';
import 'rll_compile.dart';
import 'sfc_translate.dart';
import 'type_normalize.dart';

class ImportReport {
  final int tagCount;
  final int structCount;
  final int stProgramCount;
  final int graphicalStubCount;
  final List<ImportWarning> warnings;
  // LD-translation reporting (default-safe so existing call sites compile).
  final int translatedRungCount;
  final int stubbedRungCount;
  final Set<String> unsupportedLdBlockTypes;
  final Map<String, int> ldStubReasons;
  // Custom function-block import reporting (default-safe).
  final int importedFbCount;
  // FBD-translation reporting (default-safe so existing call sites compile).
  final int translatedFbdNetworkCount;
  final int stubbedFbdNetworkCount;
  final Set<String> unsupportedFbdBlockTypes;
  final Map<String, int> fbdStubReasons;
  // SFC-translation reporting (default-safe so existing call sites compile).
  final int translatedSfcCount;
  final int stubbedSfcCount;
  final Map<String, int> sfcStubReasons;
  // RLL (L5X ladder) reporting (default-safe).
  final int translatedRllRungCount;
  final int stubbedRllRungCount;
  final Set<String> unsupportedRllInstructions;
  final Map<String, int> rllStubReasons;
  ImportReport({
    required this.tagCount,
    required this.structCount,
    required this.stProgramCount,
    required this.graphicalStubCount,
    required this.warnings,
    this.translatedRungCount = 0,
    this.stubbedRungCount = 0,
    this.unsupportedLdBlockTypes = const {},
    this.ldStubReasons = const {},
    this.importedFbCount = 0,
    this.translatedFbdNetworkCount = 0,
    this.stubbedFbdNetworkCount = 0,
    this.unsupportedFbdBlockTypes = const {},
    this.fbdStubReasons = const {},
    this.translatedSfcCount = 0,
    this.stubbedSfcCount = 0,
    this.sfcStubReasons = const {},
    this.translatedRllRungCount = 0,
    this.stubbedRllRungCount = 0,
    this.unsupportedRllInstructions = const {},
    this.rllStubReasons = const {},
  });
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
  // Built incrementally: each type's field defaults are resolved against a
  // throwaway project whose structDefs is every struct built so far. Because
  // _orderTypes emits a DUT after its dependencies, a field typed as an
  // already-built DUT (struct-in-struct, or array-of-DUT) resolves to its
  // real nested Map/List default instead of silently falling back to a
  // scalar 0 that would short-circuit defaultValueFor's recursion.
  final structs = <PlcStructDef>[];
  for (final t in _orderTypes(ir.types)) {
    final scratch = PlcProject(id: 'scratch', name: 'scratch', controllerName: 'PLC',
        programs: [], tasks: [], hmis: [], structDefs: structs, tags: []);
    structs.add(PlcStructDef(
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
    ));
  }

  // functionBlock POUs -> FbDefinitions. Computed BEFORE the vars/tags loop
  // below so a global tag instantiating a custom FB/AOI (as Rockwell L5X
  // controller tags commonly do) can resolve to its (possibly renamed) FB
  // name instead of silently falling back to a scalar default. The registry
  // + rename map also feed the LD translator further down so custom-FB calls
  // route to the right definition.
  final fbRes = mapImportedFbs(ir.pous, structs: structs, dutNames: dutNames,
      warnings: warnings, dialect: ir.dialect);
  final fbTypeNames = fbRes.renameMap.values.toSet();

  // scratch2 knows every struct (including nested ones) and FB definition, so
  // composite-typed vars (including AOI-instance tags) resolve fully.
  final scratch2 = PlcProject(id: 'scratch', name: 'scratch', controllerName: 'PLC',
      programs: [], tasks: [], hmis: [], structDefs: structs, tags: [],
      fbDefinitions: fbRes.defs);

  // Vars -> tags (with name sanitization + within-import dedup).
  final used = <String>{};
  final tags = <PlcTag>[];
  for (final v in ir.globalVars) {
    // A var whose baseType names an imported FB/AOI POU (by its ORIGINAL
    // name) resolves to that FB's final (possibly rename-collision-resolved)
    // name, so the tag ends up correctly composite-typed.
    final resolvedBaseType = fbRes.renameMap[v.baseType] ?? v.baseType;
    final appType = normalizeType(resolvedBaseType,
        knownDutNames: {...dutNames, ...fbTypeNames});
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
      defaultValue: (v.arrayLength <= 0 && !isComposite) ? def : null,
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
  var translatedRungCount = 0;
  var stubbedRungCount = 0;
  final unsupportedLdBlockTypes = <String>{};
  final ldStubReasons = <String, int>{};
  // AOI FBD bodies translated by `mapImportedFbs` are FBD networks too — seed
  // the FBD counters with them so the preview's EXISTING FBD fields cover both
  // program routines and AOI bodies (no new report fields, no new preview UI).
  var translatedFbdNetworkCount = fbRes.translatedFbdNetworkCount;
  var stubbedFbdNetworkCount = fbRes.stubbedFbdNetworkCount;
  final unsupportedFbdBlockTypes = <String>{...fbRes.unsupportedFbdBlockTypes};
  final fbdStubReasons = <String, int>{...fbRes.fbdStubReasons};
  var translatedSfcCount = 0;
  var stubbedSfcCount = 0;
  final sfcStubReasons = <String, int>{};
  // AOI ladder bodies compiled by `mapImportedFbs` are RLL rungs too — seed
  // the RLL counters with them so the preview's EXISTING RLL fields cover both
  // program routines and AOI bodies (no new report fields, no new preview UI).
  var translatedRllRungCount = fbRes.translatedRllRungCount;
  var stubbedRllRungCount = fbRes.stubbedRllRungCount;
  final unsupportedRllInstructions = <String>{...fbRes.unsupportedRllInstructions};
  final rllStubReasons = <String, int>{...fbRes.rllStubReasons};
  final programs = <PlcProgram>[];
  for (final pou in ir.pous) {
    if (pou.kind == PouKind.functionBlock) continue;
    final body = pou.body;
    if (body is TextBody) {
      if (pou.lang == PouLanguage.il) {
        warnings.add(ImportWarning(severity: WarningSeverity.info,
            message: 'POU "${pou.name}" imported from IL as Structured Text — '
                "verify against the app's ST subset."));
      }
      programs.add(PlcProgram(name: pou.name, language: 'StructuredText', stSource: body.source));
      stCount++;
    } else if (body is GraphBody && pou.lang == PouLanguage.ld) {
      // LD is translated per-rung (Task 5): rungs that translate become real
      // LdRungs; rungs that don't degrade to a commented placeholder rung
      // inside the SAME program (see translateLdBody). The whole POU is
      // stubbed only when NOTHING in it translated.
      final tr = translateLdBody(body, pouName: pou.name,
          fbRegistry: fbRes.registry, fbRenameMap: fbRes.renameMap);
      translatedRungCount += tr.translatedRungCount;
      stubbedRungCount += tr.stubbedRungCount;
      unsupportedLdBlockTypes.addAll(tr.unsupportedBlockTypes);
      tr.stubReasons.forEach((k, v) {
        ldStubReasons[k] = (ldStubReasons[k] ?? 0) + v;
      });
      warnings.addAll(tr.warnings);
      if (tr.translatedRungCount > 0) {
        // Merge instance tags with the same sanitize + dedup rule used for
        // global vars above. A rename (identifier rules, reserved name, or a
        // collision) must also be reflected onto the block node(s) in the
        // translated rungs that reference the tag by name — otherwise the
        // running ladder would look up a tag that no longer exists.
        for (final it in tr.instanceTags) {
          final original = it.name;
          var name = _sanitizeIdentifier(original);
          if (name != original) {
            warnings.add(ImportWarning(severity: WarningSeverity.info,
                message: 'Variable "$original" renamed to "$name" (identifier rules).'));
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
          if (name != original) {
            for (final rung in tr.rungs) {
              for (final node in rung.nodes) {
                // Restrict to instance-backed blocks (timers/counters/custom
                // FB calls): their `variable` is the instance name. MOVE/math
                // blocks also use `variable`, but for their DESTINATION tag —
                // a coincidental match there must NOT be retargeted (Finding 1).
                if (node.kind == LdKind.block &&
                    (isInstanceBackedLdBlock(node.blockType) ||
                        fbRes.registry.containsKey(node.blockType)) &&
                    node.variable == original) {
                  node.variable = name;
                }
              }
            }
          }
          used.add(name);
          it.name = name;
          it.path = name;
          tags.add(it);
        }
        programs.add(PlcProgram(name: pou.name, language: 'LadderLogic', rungs: tr.rungs));
      } else {
        // Nothing translated -> keep the whole-POU stub (unchanged from
        // before Task 5), still folding tr's per-rung warnings/counts above.
        warnings.add(ImportWarning(severity: WarningSeverity.warning,
            message: 'POU "${pou.name}" (LadderLogic): graphical body not yet translated '
                '(${body.nodes.length} elements captured) — re-import once graphical '
                'translation ships.'));
        programs.add(PlcProgram(name: pou.name, language: 'LadderLogic',
            description: 'Graphical body not yet translated (${body.nodes.length} elements captured).'));
        stubCount++;
      }
    } else if (body is GraphBody && pou.lang == PouLanguage.fbd) {
      // FBD is translated per-network (Task 5): a network that translates
      // becomes real FbdBlocks/FbdWires/FbdNetworks; a network that doesn't
      // degrades to an empty commented network inside the SAME program (see
      // translateFbdBody). The whole POU is stubbed only when NOTHING in it
      // translated.
      final tr = translateFbdBody(body, pouName: pou.name,
          fbRegistry: fbRes.registry, fbRenameMap: fbRes.renameMap);
      translatedFbdNetworkCount += tr.translatedNetworkCount;
      stubbedFbdNetworkCount += tr.stubbedNetworkCount;
      unsupportedFbdBlockTypes.addAll(tr.unsupportedBlockTypes);
      tr.stubReasons.forEach((k, v) {
        fbdStubReasons[k] = (fbdStubReasons[k] ?? 0) + v;
      });
      warnings.addAll(tr.warnings);
      if (tr.translatedNetworkCount > 0) {
        // Merge custom-FB instance tags with the SAME sanitize + dedup + node-
        // retarget loop the LD arm uses, but retargeting FbdBlock.tagBinding.
        //
        // ORIGINAL tagBinding -> the call block(s) that named it, indexed ONCE
        // BEFORE any retarget. Rescanning tr.blocks per instance tag would let
        // tag N — whose original name happens to equal the name tag N-1 was
        // just renamed to — drag N-1's block onto N's tag, leaving two blocks
        // sharing one FB instance and N-1's tag bound to nothing. Indexing up
        // front pins every block to the name it was BORN with. Only blocks
        // whose type is a registered FB are indexed (a TAG_INPUT/CONST binding
        // that coincidentally matches must NOT be retargeted).
        final byBinding = <String, List<FbdBlock>>{};
        for (final b in tr.blocks) {
          if (fbRes.registry.containsKey(b.type)) {
            (byBinding[b.tagBinding] ??= <FbdBlock>[]).add(b);
          }
        }
        for (final it in tr.instanceTags) {
          final original = it.name;
          var name = _sanitizeIdentifier(original);
          if (name != original) {
            warnings.add(ImportWarning(severity: WarningSeverity.info,
                message: 'Variable "$original" renamed to "$name" (identifier rules).'));
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
          if (name != original) {
            for (final b in byBinding[original] ?? const <FbdBlock>[]) {
              b.tagBinding = name;
            }
          }
          used.add(name);
          it.name = name;
          it.path = name;
          tags.add(it);
        }
        programs.add(PlcProgram(name: pou.name, language: 'FunctionBlockDiagram',
            fbdBlocks: tr.blocks, fbdWires: tr.wires, fbdNetworks: tr.networks));
      } else {
        warnings.add(ImportWarning(severity: WarningSeverity.warning,
            message: 'POU "${pou.name}" (FunctionBlockDiagram): graphical body not yet '
                'translated (${body.nodes.length} elements captured) — re-import once '
                'graphical translation ships.'));
        programs.add(PlcProgram(name: pou.name, language: 'FunctionBlockDiagram',
            description: 'Graphical body not yet translated (${body.nodes.length} elements captured).'));
        stubCount++;
      }
    } else if (body is NeutralLadderBody) {
      // RLL is compiled per-rung (Task 5): a rung that compiles becomes a
      // real LdRung; a rung that doesn't degrades to a commented placeholder
      // rung inside the SAME program (see compileRllRungs). RLL rungs
      // reference existing tags by name — no instance-tag merge (unlike the
      // PLCopen LD arm). The whole POU is stubbed only when NOTHING in it
      // translated.
      final tr = compileRllRungs(body, pouName: pou.name,
          fbRegistry: fbRes.registry, fbRenameMap: fbRes.renameMap);
      warnings.addAll(tr.warnings);
      translatedRllRungCount += tr.translatedRungCount;
      stubbedRllRungCount += tr.stubbedRungCount;
      unsupportedRllInstructions.addAll(tr.unsupportedInstructions);
      tr.stubReasons.forEach((k, v) => rllStubReasons[k] = (rllStubReasons[k] ?? 0) + v);
      if (tr.translatedRungCount > 0) {
        programs.add(PlcProgram(name: pou.name, language: 'LadderLogic', rungs: tr.rungs));
      } else {
        warnings.add(ImportWarning(severity: WarningSeverity.warning,
            message: 'POU "${pou.name}" (Ladder): ${body.rungs.length} rungs not compiled '
                '— neutral-text ladder not yet supported for these instructions.'));
        programs.add(PlcProgram(name: pou.name, language: 'LadderLogic',
            description: 'Neutral-text ladder not compiled (${body.rungs.length} rungs captured).'));
        stubCount++;
      }
    } else if (body is SfcBody) {
      // SFC is translated whole-POU (Task 4): a chart that resolves fully
      // becomes a real SequentialFunctionChart program; anything unsupported
      // keeps the whole-POU stub (unchanged behaviour).
      final tr = translateSfcBody(body, pouName: pou.name);
      warnings.addAll(tr.warnings);
      if (tr.translated) {
        programs.add(PlcProgram(name: pou.name, language: 'SequentialFunctionChart',
            sfcSteps: tr.steps, sfcTransitions: tr.transitions));
        translatedSfcCount++;
      } else {
        final reason = tr.stubReason ?? 'complex-topology';
        sfcStubReasons[reason] = (sfcStubReasons[reason] ?? 0) + 1;
        warnings.add(ImportWarning(severity: WarningSeverity.warning,
            message: 'POU "${pou.name}" (SequentialFunctionChart): graphical body not '
                'yet translated (${body.nodes.length} elements captured) — re-import '
                'once graphical translation ships.'));
        programs.add(PlcProgram(name: pou.name, language: 'SequentialFunctionChart',
            description: 'Graphical body not yet translated (${body.nodes.length} elements captured).'));
        stubbedSfcCount++;
        stubCount++; // also feeds graphicalStubCount
      }
    } else if (body is GraphBody) {
      // SFC (and any other graphical): unchanged whole-POU stub.
      final lang = switch (pou.lang) {
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
    fbDefinitions: fbRes.defs,
  );
  return ImportResult(
    project: project,
    report: ImportReport(tagCount: tags.length, structCount: structs.length,
        stProgramCount: stCount, graphicalStubCount: stubCount, warnings: warnings,
        translatedRungCount: translatedRungCount, stubbedRungCount: stubbedRungCount,
        unsupportedLdBlockTypes: unsupportedLdBlockTypes, ldStubReasons: ldStubReasons,
        importedFbCount: fbRes.defs.length,
        translatedFbdNetworkCount: translatedFbdNetworkCount,
        stubbedFbdNetworkCount: stubbedFbdNetworkCount,
        unsupportedFbdBlockTypes: unsupportedFbdBlockTypes,
        fbdStubReasons: fbdStubReasons,
        translatedSfcCount: translatedSfcCount,
        stubbedSfcCount: stubbedSfcCount,
        sfcStubReasons: sfcStubReasons,
        translatedRllRungCount: translatedRllRungCount,
        stubbedRllRungCount: stubbedRllRungCount,
        unsupportedRllInstructions: unsupportedRllInstructions,
        rllStubReasons: rllStubReasons),
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
